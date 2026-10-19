import AVFoundation
import Combine
import CoreAudio
import Foundation
import os

@MainActor
class Recorder: NSObject, ObservableObject {
    var recorder: CoreAudioRecorder?
    let logger = Logger(subsystem: "com.techneissa.pnoe", category: "Recorder")
    let deviceManager = AudioDeviceManager.shared
    private var lifecycleCancellable: AnyCancellable?
    var recordingDeviceChangeObserver: NSObjectProtocol?
    private let mediaController = MediaController.shared
    private let playbackController = PlaybackController.shared
    /// Dedicated serial queue for hardware setup.
    let audioSetupQueue = DispatchQueue(label: "com.techneissa.pnoe.audioSetup", qos: .userInitiated)
    private let recordingAudioActionDelayNanoseconds: UInt64 = 220_000_000
    private var audioMuteTask: Task<Void, Never>?
    private var mediaPauseTask: Task<Void, Never>?
    private var audioRestorationTask: Task<Void, Never>?
    private var playbackSessionID: UUID?
    private var levelHistory = LevelHistory()
    private var smoothedLevel: Float = 0
    private var recordingClock = RecordingClock()
    private var levelSamplingTimer: Timer?

    /// Audio chunk callback for streaming. Can be updated while recording;
    /// changes are forwarded to the live CoreAudioRecorder.
    var onAudioChunk: ((_ data: Data) -> Void)? {
        didSet { recorder?.onAudioChunk = onAudioChunk }
    }

    enum RecorderError: Error {
        case couldNotStartRecording
        case noUsableMicrophone(internalMicrophoneBlockedByClosedLid: Bool)
        case audioSystemNotRunning
    }

    override init() {
        super.init()
        lifecycleCancellable = LifecycleObserver.shared.publisher(
            for: [.audioDeviceChanged, .systemWillSleep, .systemDidWake]
        ).sink { [weak self] _ in
            Task { @MainActor in
                self?.invalidatePreparedAudioUnit()
            }
        }
        setupRecordingDeviceChangeObserver()
        schedulePrepareForCurrentDevice(reason: "init")
    }

    func startRecording(toOutputFile url: URL) async throws {
        var resolution = deviceManager.resolveCurrentRecordingDevice()
        guard var deviceID = resolution.deviceID else {
            onAudioChunk = nil
            throw RecorderError.noUsableMicrophone(
                internalMicrophoneBlockedByClosedLid: resolution.internalMicrophoneBlockedByClosedLid
            )
        }

        deviceManager.beginRecordingSetup(deviceID: deviceID)

        let playbackSessionID = playbackController.beginRecordingSession()
        self.playbackSessionID = playbackSessionID
        mediaController.beginRecordingSession(sessionID: playbackSessionID)
        audioRestorationTask?.cancel()
        audioRestorationTask = nil
        pauseMedia(sessionID: playbackSessionID)
        muteSystemAudio(sessionID: playbackSessionID)

        let coreAudioRecorder = recorder ?? CoreAudioRecorder()
        coreAudioRecorder.onAudioChunk = onAudioChunk
        recorder = coreAudioRecorder

        do {
            do {
                try await startHardwareRecording(coreAudioRecorder, to: url, deviceID: deviceID)
            } catch {
                let retryResolution = deviceManager.resolveCurrentRecordingDevice(excluding: deviceID)
                guard deviceManager.isClamshellClosed,
                    deviceManager.isInternalMicrophone(deviceID),
                    let fallbackDeviceID = retryResolution.deviceID
                else {
                    throw error
                }

                deviceID = fallbackDeviceID
                resolution = retryResolution
                deviceManager.beginRecordingSetup(deviceID: fallbackDeviceID)
                try await startHardwareRecording(coreAudioRecorder, to: url, deviceID: fallbackDeviceID)
            }

            deviceManager.recordingDidStart(deviceID: deviceID)
            showRecordingDeviceNotification(for: deviceID, resolution: resolution)
            UserDefaults.standard.set(String(deviceID), forKey: "lastUsedMicrophoneDeviceID")
            startLevelSampling()
            recordingClock.start(at: RecordingClock.now)
        } catch {
            logger.error(
                "Failed to start recording deviceID=\(deviceID, privacy: .public) file=\(url.lastPathComponent, privacy: .public) error=\(error, privacy: .public)"
            )
            await stopRecording()
            if (error as? CoreAudioRecorderError)?.status == kAudioHardwareNotRunningError {
                throw RecorderError.audioSystemNotRunning
            }
            throw RecorderError.couldNotStartRecording
        }
    }

    func stopRecording() async {
        let playbackSessionID = self.playbackSessionID
        audioMuteTask?.cancel()
        audioMuteTask = nil
        mediaPauseTask?.cancel()
        mediaPauseTask = nil
        // Capture current recorder to stop it on the serial hardware queue.
        let currentRecorder = self.recorder

        await withCheckedContinuation { continuation in
            audioSetupQueue.async {
                currentRecorder?.stopRecording()
                continuation.resume()
            }
        }
        guard self.playbackSessionID == playbackSessionID else { return }
        onAudioChunk = nil

        resetLevelSampling()
        recordingClock.stop(at: RecordingClock.now)

        audioRestorationTask?.cancel()
        audioRestorationTask = Task {
            if let playbackSessionID {
                await mediaController.unmuteSystemAudio(sessionID: playbackSessionID)
                await playbackController.resumeMedia(sessionID: playbackSessionID)
            }
        }
        deviceManager.recordingDidStop()
    }

    private func muteSystemAudio(sessionID: UUID) {
        audioMuteTask?.cancel()
        audioMuteTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.recordingAudioActionDelayNanoseconds)
            guard !Task.isCancelled else { return }
            _ = self.mediaController.muteSystemAudio(sessionID: sessionID)
        }
    }

    private func pauseMedia(sessionID: UUID) {
        mediaPauseTask?.cancel()
        mediaPauseTask = Task { [weak self] in
            guard let self else { return }
            await self.playbackController.pauseMedia(sessionID: sessionID)
        }
    }

    private func schedulePrepareForCurrentDevice(reason: String) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return
        }

        let deviceID = deviceManager.getCurrentDevice()
        guard deviceID != 0 else {
            recorder?.teardown()
            return
        }

        let coreAudioRecorder = recorder ?? CoreAudioRecorder()
        coreAudioRecorder.onAudioChunk = onAudioChunk
        recorder = coreAudioRecorder

        let selectedChannels = deviceManager.selectedInputChannels(for: deviceID)
        audioSetupQueue.async { [logger] in
            do {
                try coreAudioRecorder.prepare(deviceID: deviceID, selectedInputChannels: selectedChannels)
            } catch {
                logger.warning(
                    "Recorder prepare failed reason=\(reason, privacy: .public) deviceID=\(deviceID, privacy: .public) error=\(error, privacy: .public)"
                )
            }
        }
    }

    private func invalidatePreparedAudioUnit() {
        guard let coreAudioRecorder = recorder else { return }
        audioSetupQueue.async {
            coreAudioRecorder.invalidatePreparation()
        }
    }

    /// The recent input levels, oldest first, for the recorder's level display.
    func levelHistorySnapshot() -> LevelHistory {
        levelHistory
    }

    /// The recording time for the indicator's timer: counting while recording, frozen at the
    /// length of the take once recording has stopped.
    func recordingClockSnapshot() -> RecordingClock {
        recordingClock
    }

    /// Takes a level every 1/30 s while recording. The audio thread already stores its decibel
    /// reading in an atomic; this only reads it, so the real-time path does nothing new.
    private func startLevelSampling() {
        resetLevelSampling()
        let timer = Timer(timeInterval: 1 / RecorderLevelMetrics.samplesPerSecond, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                if let self { self.sampleLevel() } else { timer.invalidate() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelSamplingTimer = timer
    }

    private func sampleLevel() {
        guard let recorder else { return }
        let level = LevelMapping.level(fromDecibels: recorder.averagePower)
        smoothedLevel = LevelMapping.smoothed(previous: smoothedLevel, next: level)
        levelHistory.append(smoothedLevel)
    }

    private func resetLevelSampling() {
        levelSamplingTimer?.invalidate()
        levelSamplingTimer = nil
        smoothedLevel = 0
        levelHistory.removeAll()
    }

    // MARK: - Cleanup

    deinit {
        levelSamplingTimer?.invalidate()
        audioMuteTask?.cancel()
        mediaPauseTask?.cancel()
        audioRestorationTask?.cancel()
        if let observer = recordingDeviceChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        recorder?.teardown()
    }
}
