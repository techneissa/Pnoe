import AVFoundation
import AppKit
import Foundation
import SwiftData
import SwiftUI
import os

private final class RealtimeAudioChunkGate: @unchecked Sendable {
    private struct State {
        var bufferedChunks: [Data] = []
        var callback: ((Data) -> Void)?
        var isActive = false
        var droppedChunks = 0
    }

    private let maxBufferedChunks = 2_048
    private let state = OSAllocatedUnfairLock(initialState: State())

    func receive(_ data: Data) {
        let callback = state.withLock { state -> ((Data) -> Void)? in
            guard state.isActive else {
                if state.bufferedChunks.count < maxBufferedChunks {
                    state.bufferedChunks.append(data)
                } else {
                    state.droppedChunks += 1
                }
                return nil
            }
            return state.callback
        }
        callback?(data)
    }

    func activate(_ callback: @escaping (Data) -> Void) -> Int {
        let initialState = state.withLock { state -> (chunks: [Data], droppedChunks: Int) in
            state.callback = callback
            state.isActive = false
            let chunks = state.bufferedChunks
            let droppedChunks = state.droppedChunks
            state.bufferedChunks.removeAll()
            state.droppedChunks = 0
            return (chunks, droppedChunks)
        }
        var chunksToSend = initialState.chunks
        var droppedChunks = initialState.droppedChunks

        while true {
            for chunk in chunksToSend {
                callback(chunk)
            }

            let nextState = state.withLock { state -> (chunks: [Data], droppedChunks: Int, finished: Bool) in
                let droppedChunks = state.droppedChunks
                state.droppedChunks = 0
                guard !state.bufferedChunks.isEmpty else {
                    state.isActive = true
                    return ([], droppedChunks, true)
                }
                let chunks = state.bufferedChunks
                state.bufferedChunks.removeAll()
                return (chunks, droppedChunks, false)
            }
            droppedChunks += nextState.droppedChunks

            if nextState.finished {
                return droppedChunks
            }
            chunksToSend = nextState.chunks
        }
    }

    func reset() -> Int {
        state.withLock { state -> Int in
            let droppedChunks = state.droppedChunks
            state.bufferedChunks.removeAll()
            state.callback = nil
            state.isActive = false
            state.droppedChunks = 0
            return droppedChunks
        }
    }
}

@MainActor
class PnoeEngine: NSObject, ObservableObject {
    private enum RecordingUseCase {
        case newSession
        case assistantFollowUp

        var isAssistantFollowUp: Bool {
            self == .assistantFollowUp
        }
    }

    @Published var recordingState: RecordingState = .idle {
        didSet {
            if recordingState != .starting && recordingState != .recording { expectsPartialTranscript = false }
        }
    }
    @Published var shouldCancelRecording = false
    @Published var partialTranscript: String = ""
    @Published private(set) var expectsPartialTranscript = false
    var currentSession: TranscriptionSession?
    private var currentSessionTranscriptionConfiguration: TranscriptionRuntimeConfiguration?
    private var activeRecordingStartID: UUID?
    private var activePipelineTranscriptionID: UUID?
    /// The take whose outcome the recorder may still show: set when its pipeline starts, cleared when a
    /// new recording starts or the recorder closes, so a late paste result never lands on another take.
    private var outcomeTakeID: UUID?
    private var canceledPipelineTranscriptionIDs = Set<UUID>()
    private var activeRecordingUseCase: RecordingUseCase = .newSession
    private var activePipelineUseCase: RecordingUseCase = .newSession
    private var activeRecordingContextStore: RecordingContextSnapshotStore?
    private var activeRecordingContextTasks: [Task<Void, Never>] = []

    let recorder = Recorder()
    var recordedFile: URL? = nil
    let recordingsDirectory: URL

    // Injected managers
    let whisperModelManager: WhisperModelManager
    let transcriptionModelManager: TranscriptionModelManager
    weak var recorderUIManager: RecorderPanelPresenting?

    let modelContext: ModelContext
    internal let serviceRegistry: TranscriptionServiceRegistry
    let enhancementService: AIEnhancementService?
    let assistantSession = AssistantSession()
    let assistantChat: AssistantChatService?
    private let pipeline: TranscriptionPipeline

    /// How a take ends in the recorder: a check mark when it was pasted, the error symbol when it
    /// was cancelled or failed, for a moment, then the recorder hides.
    private lazy var outcomeFlow = RecorderOutcomeFlow(
        currentState: { [weak self] in self?.recordingState ?? .idle },
        setState: { [weak self] in self?.recordingState = $0 },
        isRecorderVisible: { [weak self] in self?.recorderUIManager?.isRecorderPanelVisible ?? false },
        hide: { [weak self] in await self?.recorderUIManager?.dismissRecorderPanel() }
    )

    let logger = Logger(subsystem: "com.techneissa.pnoe", category: "PnoeEngine")

    init(
        modelContext: ModelContext,
        whisperModelManager: WhisperModelManager,
        transcriptionModelManager: TranscriptionModelManager,
        enhancementService: AIEnhancementService? = nil
    ) {
        self.modelContext = modelContext
        self.whisperModelManager = whisperModelManager
        self.transcriptionModelManager = transcriptionModelManager
        self.enhancementService = enhancementService
        if let aiService = enhancementService?.getAIService() {
            self.assistantChat = AssistantChatService(
                modelContext: modelContext,
                aiService: aiService
            )
        } else {
            self.assistantChat = nil
        }

        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.techneissa.Pnoe")
        self.recordingsDirectory = appSupportDirectory.appendingPathComponent("Recordings")

        self.serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: whisperModelManager,
            modelsDirectory: whisperModelManager.modelsDirectory,
            modelContext: modelContext
        )
        self.pipeline = TranscriptionPipeline(
            modelContext: modelContext,
            serviceRegistry: serviceRegistry,
            enhancementService: enhancementService
        )

        super.init()

        assistantSession.speaker.canStart = { [weak self] in
            guard let state = self?.recordingState else { return true }
            return state != .starting && state != .recording
        }

        setupNotifications()
        createRecordingsDirectoryIfNeeded()
    }

    private func createRecordingsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(
                at: recordingsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.error("❌ Error creating recordings directory: \(error, privacy: .public)")
        }
    }

    // MARK: - Toggle Record

    func toggleRecord(modeId: UUID? = nil, isAssistantFollowUp: Bool = false, sendAfterPaste: Bool = false) async {
        if recordingState == .starting {
            await cancelRecording()
            return
        }

        if recordingState == .recording {
            activePipelineUseCase = activeRecordingUseCase
            activeRecordingUseCase = .newSession
            activeRecordingStartID = nil
            partialTranscript = ""
            recordingState = .transcribing
            await recorder.stopRecording()

            if let recordedFile {
                if !shouldCancelRecording {
                    let transcription = makeRecordingTranscription(
                        for: recordedFile,
                        text: "",
                        duration: 0,
                        transcriptionStatus: .pending
                    )
                    modelContext.insert(transcription)
                    try? modelContext.save()
                    NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)

                    await runPipeline(
                        on: transcription,
                        audioURL: recordedFile,
                        contextStore: activeRecordingContextStore,
                        sendAfterPaste: sendAfterPaste
                    )
                } else {
                    await finishActiveRecorderCancellation()
                }
            } else {
                cancelCurrentSession()
                let wasCancelled = shouldCancelRecording
                if !wasCancelled {
                    logger.error("❌ No recorded file found after stopping recording")
                }
                recordingState = .idle
                await cleanupResources()
                if !wasCancelled { await endTakeWithFailure() }
            }
        } else {
            // The microphone must not record Pnoe reading a reply.
            assistantSession.speaker.stop(.recordingStarted)

            let canContinueAssistantSession = isAssistantFollowUp && assistantSession.canSendFollowUp
            let recordingUseCase: RecordingUseCase = canContinueAssistantSession ? .assistantFollowUp : .newSession

            // A check mark or error symbol still showing from the last take goes at once.
            outcomeFlow.interrupt()
            outcomeTakeID = nil
            activePipelineTranscriptionID = nil
            shouldCancelRecording = false
            partialTranscript = ""
            activeRecordingUseCase = recordingUseCase
            clearActiveRecordingContext()

            if !recordingUseCase.isAssistantFollowUp {
                assistantSession.reset()
            }

            requestRecordPermission { [self] granted in
                if granted {
                    Task { @MainActor [self] in
                        guard await self.passesRecordingPreflight() else {
                            return
                        }

                        let startID = UUID()
                        self.activeRecordingStartID = startID
                        let activeModeTask = ActiveWindowService.shared.beginApplyingConfiguration(modeId: modeId) {
                            [weak self] in
                            guard let self else { return false }
                            return self.activeRecordingStartID == startID && !self.shouldCancelRecording
                        }

                        do {
                            let fileName = "\(UUID().uuidString).wav"
                            let permanentURL = self.recordingsDirectory.appendingPathComponent(fileName)
                            self.recordedFile = permanentURL

                            let realtimeAudioGate = RealtimeAudioChunkGate()
                            self.recorder.onAudioChunk = realtimeAudioGate.receive

                            // A reply that landed during the permission and preflight waits above was not blocked
                            // (the state was still idle). Stop it before the microphone opens.
                            self.assistantSession.speaker.stop(.recordingStarted)
                            self.recordingState = .starting

                            try await self.recorder.startRecording(toOutputFile: permanentURL)

                            guard self.activeRecordingStartID == startID,
                                self.recorderUIManager?.isRecorderPanelVisible ?? false,
                                !self.shouldCancelRecording
                            else {
                                activeModeTask.cancel()
                                let shouldKeepRecordingFile = self.shouldCancelRecording
                                if self.activeRecordingStartID == startID {
                                    await self.recorder.stopRecording()
                                    if !shouldKeepRecordingFile {
                                        self.recordedFile = nil
                                    }
                                    self.recordingState = .idle
                                    self.activeRecordingStartID = nil
                                }
                                return
                            }

                            self.recordingState = .recording

                            // Only retire the previous paste session once recording
                            // has actually started. Preflight/permission failures
                            // must leave it available for Auto Learn capture.
                            if AutoLearnSettings.isEnabled {
                                await AutoLearnService.shared.recordingDidStart()
                            }

                            await activeModeTask.value

                            guard self.recordingState == .recording,
                                self.activeRecordingStartID == startID,
                                !self.shouldCancelRecording
                            else {
                                return
                            }

                            self.startRecordingContextCapture()
                            self.preloadBuiltInModelIfNeeded()

                            let modelResolution = ModeRuntimeResolver.transcriptionModelResolution(
                                transcriptionModelManager: self.transcriptionModelManager
                            )
                            guard
                                let transcriptionConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
                                    from: modelResolution
                                )
                            else {
                                let failure = self.recordingModelFailure(for: modelResolution)
                                NotificationManager.shared.showNotification(
                                    title: failure.title,
                                    type: .error,
                                    duration: 7.0,
                                    actionButton: (failure.actionLabel, failure.action)
                                )
                                await self.recorder.stopRecording()
                                try? FileManager.default.removeItem(at: permanentURL)
                                self.recordedFile = nil
                                self.recordingState = .idle
                                self.activeRecordingStartID = nil
                                self.clearActiveRecordingContext()
                                await self.cleanupResources()
                                await self.endTakeWithFailure()
                                return
                            }

                            if self.serviceRegistry.shouldUseRealtimeTranscription(for: transcriptionConfiguration) {
                                // The preview is the only consumer of partials, so it is throttled
                                // here and the transcription path only hands over a string.
                                let relay = PartialTranscriptRelay { [weak self] partial in
                                    guard let self,
                                        self.activeRecordingStartID == startID,
                                        self.recordingState == .recording
                                    else {
                                        return
                                    }
                                    self.partialTranscript = partial
                                }
                                self.expectsPartialTranscript = true
                                let session = self.serviceRegistry.createSession(
                                    for: transcriptionConfiguration,
                                    onPartialTranscript: { partial in
                                        Task { @MainActor in
                                            relay.submit(partial)
                                        }
                                    }
                                )
                                self.currentSession = session
                                self.currentSessionTranscriptionConfiguration = transcriptionConfiguration
                                let realCallback = try await session.prepare(
                                    configuration: transcriptionConfiguration
                                )

                                if let realCallback {
                                    let droppedStartupChunks = realtimeAudioGate.activate(realCallback)
                                    if droppedStartupChunks > 0 {
                                        self.logger.warning(
                                            "Realtime startup audio gate dropped \(droppedStartupChunks, privacy: .public) chunks before streaming became active"
                                        )
                                    }
                                } else {
                                    _ = realtimeAudioGate.reset()
                                    self.recorder.onAudioChunk = nil
                                }
                            } else {
                                self.expectsPartialTranscript = false
                                self.currentSession = nil
                                self.currentSessionTranscriptionConfiguration = nil
                                self.recorder.onAudioChunk = nil
                                _ = realtimeAudioGate.reset()
                            }

                            Task { @MainActor [weak self] in
                                guard let self else { return }

                                let currentModel = ModeRuntimeResolver.transcriptionConfiguration(
                                    transcriptionModelManager: self.transcriptionModelManager
                                )?.model

                                if let model = currentModel,
                                    model.provider == .whisper
                                {
                                    if let localWhisperModel = self.whisperModelManager.availableModels.first(where: {
                                        $0.name == model.name
                                    }),
                                        self.whisperModelManager.whisperContext == nil
                                    {
                                        do {
                                            try await self.whisperModelManager.loadModel(localWhisperModel)
                                        } catch {
                                            self.logger.error("❌ Model loading failed: \(error, privacy: .public)")
                                        }
                                    }
                                } else if let fluidAudioModel = currentModel as? FluidAudioModel {
                                    // Unified streaming does not need the offline encoder.
                                    if transcriptionConfiguration.isRealtimeEnabled,
                                        FluidAudioModelManager.isParakeetUnifiedModel(named: fluidAudioModel.name)
                                    {
                                        return
                                    }
                                    try? await self.serviceRegistry.fluidAudioTranscriptionService.loadModel(
                                        for: fluidAudioModel)
                                } else if let transcribeCppModel = currentModel as? TranscribeCppModel {
                                    try? await self.serviceRegistry.transcribeCppTranscriptionService.loadModel(
                                        for: transcribeCppModel)
                                } else if let whisperKitModel = currentModel as? WhisperKitModel {
                                    try? await self.serviceRegistry.whisperKitTranscriptionService.loadModel(
                                        for: whisperKitModel)
                                }

                            }

                        } catch {
                            activeModeTask.cancel()
                            self.logger.error("Recording failed to start: \(error, privacy: .public)")
                            let audioFailure = self.recordingAudioFailure(for: error)
                            if audioFailure == nil {
                                await self.recorder.stopRecording()
                            }
                            self.cancelCurrentSession()
                            if let recordedFile = self.recordedFile {
                                try? FileManager.default.removeItem(at: recordedFile)
                            }
                            self.recordingState = .idle
                            self.recordedFile = nil
                            self.activeRecordingStartID = nil
                            self.clearActiveRecordingContext()
                            await self.cleanupResources()
                            if let failure = audioFailure {
                                NotificationManager.shared.showNotification(
                                    title: failure.title,
                                    type: .error,
                                    duration: 7.0,
                                    actionButton: (failure.actionLabel, failure.action)
                                )
                            } else {
                                NotificationManager.shared.showNotification(
                                    title: String(localized: "Recording failed to start"), type: .error)
                            }
                            await self.endTakeWithFailure()
                        }
                    }
                } else {
                    logger.error("Recording permission denied")
                }
            }
        }
    }

    private func requestRecordPermission(response: @escaping (Bool) -> Void) {
        response(true)
    }

    @MainActor
    private func recordingModelFailure(
        for resolution: ModeTranscriptionModelResolution
    ) -> (title: String, actionLabel: String, action: () -> Void) {
        switch resolution {
        case .noMode:
            return (
                String(localized: "No workflow configured"),
                String(localized: "Manage Workflows"),
                ModeSetupNavigator.openModesSettings
            )
        case .noSelection(let mode):
            return (
                String(
                    format: String(localized: "No transcription model is selected for the '%@' workflow"),
                    mode.name
                ),
                String(localized: "Manage Workflows"),
                ModeSetupNavigator.openModesSettings
            )
        case .modelNotFound(let mode):
            return (
                String(
                    format: String(localized: "The transcription model selected for the '%@' workflow is unavailable"),
                    mode.name
                ),
                String(localized: "Manage Workflows"),
                ModeSetupNavigator.openModesSettings
            )
        case .unavailable(let mode, let model), .available(let mode, let model):
            return (
                String(
                    format: String(localized: "'%@' is not available for the %@ workflow"),
                    model.displayName,
                    mode.name
                ),
                String(localized: "Manage AI Models"),
                ModeSetupNavigator.openModelsSettings
            )
        }
    }

    /// Checks requirements that do not depend on asynchronous app and URL mode resolution.
    @MainActor
    private func passesRecordingPreflight() async -> Bool {
        if !ModeManager.shared.hasEnabledConfiguration {
            await failRecordingPreflight(
                title: String(localized: "No workflow configured"),
                actionLabel: String(localized: "Manage Workflows"),
                action: ModeSetupNavigator.openModesSettings
            )
            return false
        }

        return true
    }

    @MainActor
    private func failRecordingPreflight(
        title: String,
        actionLabel: String,
        action: @escaping () -> Void
    ) async {
        logger.error("❌ Recording preflight failed: \(title, privacy: .public)")
        recordingState = .idle
        NotificationManager.shared.showNotification(
            title: title,
            type: .error,
            duration: 7.0,
            actionButton: (actionLabel, action)
        )
        await endTakeWithFailure()
    }

    /// Shows the error symbol for a moment, then hides the recorder; hides it at once when this
    /// take's recorder is already gone.
    private func endTakeWithFailure() async {
        if !outcomeFlow.show(.failed) {
            await recorderUIManager?.dismissRecorderPanel()
        }
    }

    /// Shows the error symbol for a take that was cancelled. Returns false when the recorder is
    /// already hidden or a new take replaced it.
    @discardableResult
    func showCancelledOutcome() -> Bool {
        outcomeFlow.show(.failed)
    }

    /// Drops a check mark or error symbol that is still showing (the recorder closes, or a new
    /// recording starts).
    func dismissOutcome() {
        outcomeFlow.interrupt()
        outcomeTakeID = nil
    }

    // MARK: - Recording Context

    /// When the workflow that is recording uses Built-in, start loading its model now, so the take that follows
    /// finds it ready. Recording does not wait for it; a load that fails leaves the take to fall back.
    private func preloadBuiltInModelIfNeeded() {
        guard let enhancementService, let aiService = enhancementService.getAIService() else { return }
        let configuration = ModeRuntimeResolver.currentEnhancementConfiguration(
            enhancementService: enhancementService, aiService: aiService)
        BuiltInEngine.shared.preloadIfUsed(
            isEnabled: configuration.isEnabled, providerName: configuration.provider?.rawValue,
            modelID: configuration.modelName)
    }

    private func startRecordingContextCapture() {
        clearActiveRecordingContext()

        let store = RecordingContextSnapshotStore()
        activeRecordingContextStore = store
        activeRecordingContextTasks = RecordingContextCaptureService.startCapture(into: store)
    }

    private func clearActiveRecordingContext() {
        activeRecordingContextTasks.forEach { $0.cancel() }
        activeRecordingContextTasks.removeAll()
        activeRecordingContextStore = nil
    }

    // MARK: - Pipeline Dispatch

    private func runPipeline(
        on transcription: Transcription,
        audioURL: URL,
        contextStore: RecordingContextSnapshotStore?,
        sendAfterPaste: Bool
    ) async {
        guard
            let transcriptionConfiguration = currentSessionTranscriptionConfiguration
                ?? ModeRuntimeResolver.transcriptionConfiguration(transcriptionModelManager: transcriptionModelManager)
        else {
            transcription.text = String(localized: "Transcription Failed: No model selected")
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
            try? modelContext.save()
            if !outcomeFlow.show(.failed) { recordingState = .idle }
            activePipelineUseCase = .newSession
            return
        }

        let session = currentSession
        let transcriptionID = transcription.id
        activePipelineTranscriptionID = transcriptionID
        outcomeTakeID = transcriptionID

        await pipeline.run(
            transcription: transcription,
            audioURL: audioURL,
            transcriptionConfiguration: transcriptionConfiguration,
            formattingConfiguration: {
                ModeRuntimeResolver.transcriptionFormattingConfiguration()
            },
            session: session,
            triggerWordModeSelection: { [weak self] text in
                self?.selectTriggerWordModeIfNeeded(for: text)
            },
            enhancementConfiguration: { [weak self] in
                guard let self,
                    let enhancementService = self.enhancementService,
                    let aiService = enhancementService.getAIService()
                else {
                    return nil
                }
                return ModeRuntimeResolver.currentEnhancementConfiguration(
                    enhancementService: enhancementService,
                    aiService: aiService
                )
            },
            recordingContextSnapshot: {
                await MainActor.run {
                    contextStore?.snapshot
                }
            },
            outputConfiguration: {
                ModeRuntimeResolver.outputConfiguration()
            },
            sendAfterPaste: sendAfterPaste,
            onStateChange: { [weak self] state in
                guard let self else { return }
                if let outcome = state.outcome {
                    // The paste result can arrive after the pipeline has returned; only a newer
                    // recording or a closed recorder drops it.
                    guard self.outcomeTakeID == transcriptionID else { return }
                    if !self.outcomeFlow.show(outcome), self.recordingState.isProcessing {
                        self.recordingState = .idle
                    }
                    return
                }
                guard self.activePipelineTranscriptionID == transcriptionID else { return }
                self.recordingState = state
            },
            shouldCancel: { [weak self] in
                guard let self else { return false }
                return self.canceledPipelineTranscriptionIDs.contains(transcriptionID)
                    || (self.activePipelineTranscriptionID == transcriptionID && self.shouldCancelRecording)
            },
            onCancel: { [weak self, session] in
                guard let self else { return }
                self.cancelPipelineSession(transcriptionID: transcriptionID, session: session)
            },
            assistant: TranscriptionPipeline.AssistantHooks(
                isFollowUp: activePipelineUseCase.isAssistantFollowUp,
                sendFollowUp: { [weak self] text, transcription in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    await self.sendAssistantFollowUp(text, transcription: transcription)
                },
                startResponse: { [weak self] transcript, configuration in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    self.assistantSession.beginInitialResponse(
                        transcript: transcript,
                        provider: configuration.provider,
                        modelName: configuration.modelName ?? configuration.provider?.defaultModel,
                        modeName: configuration.mode?.name,
                        modeEmoji: configuration.mode?.icon.value,
                        promptName: configuration.prompt?.title
                    )
                },
                showResponse: { [weak self] response, systemPrompt in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    await self.completeAssistantResponse(response, systemPrompt: systemPrompt)
                },
                failResponse: { [weak self] message in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    self.assistantSession.fail(message)
                    // The answer panel stays up; only the circle shows the red error for a moment.
                    self.outcomeFlow.show(.failed, hidesRecorder: false)
                }
            )
        )

        defer {
            canceledPipelineTranscriptionIDs.remove(transcriptionID)
        }

        guard activePipelineTranscriptionID == transcriptionID else { return }
        await cleanupResources()
        guard activePipelineTranscriptionID == transcriptionID else { return }

        activePipelineTranscriptionID = nil
        currentSession = nil
        currentSessionTranscriptionConfiguration = nil
        recordedFile = nil
        shouldCancelRecording = false
        activePipelineUseCase = .newSession
        clearActiveRecordingContext()

        if recordingState == .transcribing || recordingState == .enhancing || recordingState == .busy {
            recordingState = .idle
        }
    }

    private func selectTriggerWordModeIfNeeded(for text: String) -> String? {
        guard let (triggeredMode, processedText) = ModeManager.shared.getConfigurationForTriggerWord(text) else {
            return nil
        }

        ModeManager.shared.setActiveConfiguration(triggeredMode)
        return processedText
    }

    // MARK: - Cancellation

    func cancelRecording() async {
        outcomeFlow.interrupt()
        let shouldFinishSessionImmediately: Bool
        switch recordingState {
        case .starting, .recording:
            requestRecordingCancellation()
            await finishActiveRecorderCancellation()
            shouldFinishSessionImmediately = false
        case .transcribing, .enhancing:
            requestRecordingCancellation()
            partialTranscript = ""
            recordingState = .idle
            shouldFinishSessionImmediately = false
        case .idle, .busy, .pasting, .done, .failed:
            partialTranscript = ""
            shouldCancelRecording = false
            recordingState = .idle
            shouldFinishSessionImmediately = true
        }

        if shouldFinishSessionImmediately {
            await finishRecorderSession()
        }
    }

    func resetRecordingSession() async {
        outcomeFlow.interrupt()
        outcomeTakeID = nil
        cancelCurrentSession()
        activeRecordingStartID = nil
        activePipelineTranscriptionID = nil
        canceledPipelineTranscriptionIDs.removeAll()
        shouldCancelRecording = false
        partialTranscript = ""
        assistantSession.reset()
        activeRecordingUseCase = .newSession
        activePipelineUseCase = .newSession
        clearActiveRecordingContext()
        await recorder.stopRecording()
        recordedFile = nil
        recordingState = .idle
        await cleanupResources()
    }

    private func requestRecordingCancellation() {
        shouldCancelRecording = true

        if (recordingState == .transcribing || recordingState == .enhancing),
            let activePipelineTranscriptionID
        {
            canceledPipelineTranscriptionIDs.insert(activePipelineTranscriptionID)
        }

        cancelCurrentSession()
    }

    private func finishActiveRecorderCancellation() async {
        activeRecordingStartID = nil
        clearActiveRecordingContext()
        await recorder.stopRecording()
        await saveCanceledRecording()
        recordedFile = nil
        partialTranscript = ""
        recordingState = .idle
        await cleanupResources()
    }

    private func saveCanceledRecording() async {
        guard let recordedFile,
            FileManager.default.fileExists(atPath: recordedFile.path)
        else { return }

        let duration = await AudioFileMetadata.duration(for: recordedFile)
        let transcription = makeRecordingTranscription(
            for: recordedFile,
            text: Transcription.canceledTranscriptionText,
            duration: duration,
            transcriptionStatus: .canceled
        )

        modelContext.insert(transcription)

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
        } catch {
            logger.error("Failed to save canceled recording: \(error, privacy: .public)")
        }
    }

    private func makeRecordingTranscription(
        for audioURL: URL,
        text: String,
        duration: TimeInterval,
        transcriptionStatus: TranscriptionStatus
    ) -> Transcription {
        let modeMetadata = currentModeMetadata()

        return Transcription(
            text: text,
            duration: duration,
            audioFileURL: audioURL.absoluteString,
            transcriptionModelName: ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: transcriptionModelManager
            )?.model.displayName,
            modeName: modeMetadata.name,
            modeEmoji: modeMetadata.emoji,
            transcriptionStatus: transcriptionStatus
        )
    }

    private func currentModeMetadata() -> (name: String?, emoji: String?) {
        guard let mode = ModeManager.shared.currentEffectiveConfiguration,
            mode.isEnabled
        else {
            return (nil, nil)
        }

        return (mode.name, mode.icon.value)
    }

    // MARK: - Resource Cleanup

    private func cancelPipelineSession(transcriptionID: UUID, session: TranscriptionSession?) {
        session?.cancel()

        guard activePipelineTranscriptionID == transcriptionID else {
            logger.notice("Skipping stale pipeline cleanup")
            return
        }

        currentSession = nil
        currentSessionTranscriptionConfiguration = nil
    }

    private func cancelCurrentSession() {
        currentSession?.cancel()
        currentSession = nil
        currentSessionTranscriptionConfiguration = nil
    }

    private func finishRecorderSession() async {
        enhancementService?.clearCapturedContexts()
    }

    func cleanupResources() async {
        logger.notice("cleanupResources: releasing model resources")
        activeRecordingStartID = nil
        activeRecordingUseCase = .newSession
        await finishRecorderSession()
        await whisperModelManager.cleanupResources()
        await serviceRegistry.cleanup()
        logger.notice("cleanupResources: completed")
    }

    // MARK: - Notification Handling

    func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePromptChange),
            name: .promptDidChange,
            object: nil
        )
    }

    @objc func handlePromptChange() {
        Task {
            let currentPrompt =
                UserDefaults.standard.string(forKey: "TranscriptionPrompt")
                ?? whisperModelManager.whisperPrompt.transcriptionPrompt
            if let context = whisperModelManager.whisperContext {
                await context.setPrompt(currentPrompt)
            }
        }
    }
}

enum AudioFileMetadata {
    static func duration(for url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : 0
    }
}
