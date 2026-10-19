import AppKit
import Combine
import Foundation
import SwiftUI
import os

@MainActor
protocol RecorderPanelPresenting: AnyObject {
    var isRecorderPanelVisible: Bool { get }
    func dismissRecorderPanel() async
}

@MainActor
class RecorderUIManager: ObservableObject, RecorderPanelPresenting {
    @Published var recorderPanelStyle: RecorderPanelStyle = .stored {
        didSet {
            guard oldValue != recorderPanelStyle else { return }
            UserDefaults.standard.set(recorderPanelStyle.rawValue, forKey: "RecorderType")
            rebuildPanels()
        }
    }

    var recorderType: String {
        get { recorderPanelStyle.rawValue }
        set { recorderPanelStyle = RecorderPanelStyle(rawValue: newValue) ?? .mini }
    }

    @Published var isRecorderPanelVisible = false {
        didSet {
            guard oldValue != isRecorderPanelVisible else { return }

            if isRecorderPanelVisible {
                showRecorderPanel()
            } else {
                hideRecorderPanel()
                syncIdleIndicator()
            }
        }
    }

    private var notchWindowManager: NotchWindowManager?
    private var miniWindowManager: MiniWindowManager?
    private var panelInvalidationTask: Task<Void, Never>?
    private var didSetupNotifications = false
    private var lifecycleCancellable: AnyCancellable?
    private var settingsCancellable: AnyCancellable?
    private var lastIndicatorSettings = RecorderIndicatorSettings.current

    private weak var engine: PnoeEngine?
    private var recorder: Recorder?

    private let logger = Logger(subsystem: "com.techneissa.pnoe", category: "RecorderUIManager")

    init() {}

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Call after PnoeEngine is created to break the circular init dependency.
    func configure(engine: PnoeEngine, recorder: Recorder) {
        self.engine = engine
        self.recorder = recorder
        setupNotifications()
        syncIdleIndicator()
    }

    // MARK: - Recorder Panel Management

    /// The style actually on screen: the chosen one, except that a built-in display without a
    /// notch gets Mini.
    private var effectiveStyle: RecorderPanelStyle {
        RecorderScreenResolver.effectiveStyle(requested: recorderPanelStyle)
    }

    /// Shows the recorder. `idle` is the compact indicator that stays up between dictations
    /// when the visibility setting is "Always".
    private func showRecorderPanel(idle: Bool = false) {
        guard let engine = engine, let recorder = recorder else { return }

        let style = effectiveStyle
        let shown: Bool

        // Only one panel ever exists, so a fallback from Notch to Mini (or back) leaves no
        // stale window of the other style behind.
        switch style {
        case .notch:
            miniWindowManager?.destroyWindow()
            miniWindowManager = nil
            if notchWindowManager == nil {
                notchWindowManager = NotchWindowManager(
                    engine: engine,
                    recorder: recorder,
                    assistantSession: engine.assistantSession,
                    onRecordButtonTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.toggleRecorderPanel()
                        }
                    },
                    onCloseTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.dismissRecorderPanel()
                        }
                    },
                    onAssistantFollowUp: { [weak engine] text in
                        Task { @MainActor in
                            await engine?.sendAssistantFollowUp(text)
                        }
                    }
                )
            }
            shown = notchWindowManager?.show(compact: idle) ?? false
        case .mini:
            notchWindowManager?.destroyWindow()
            notchWindowManager = nil
            if miniWindowManager == nil {
                miniWindowManager = MiniWindowManager(
                    engine: engine,
                    recorder: recorder,
                    assistantSession: engine.assistantSession,
                    onRecordButtonTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.toggleRecorderPanel()
                        }
                    },
                    onCloseTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.dismissRecorderPanel()
                        }
                    },
                    onAssistantFollowUp: { [weak engine] text in
                        Task { @MainActor in
                            await engine?.sendAssistantFollowUp(text)
                        }
                    }
                )
            }
            shown = miniWindowManager?.show(compact: idle) ?? false
        }

        if shown {
            logger.notice(
                "Showed recorder panel style=\(style.rawValue, privacy: .public) idle=\(idle, privacy: .public)")
        } else {
            // Only reachable with no screens at all. Recording still works, so the session is
            // left running rather than cancelled, but it runs without any UI — say so loudly,
            // because this is exactly the symptom users report.
            logger.error("Recorder panel could not be shown style=\(style.rawValue, privacy: .public) screens=\(NSScreen.screens.count, privacy: .public)")
        }
    }

    private func hideRecorderPanel() {
        // `dismissRecorderPanel()` calls this directly and then clears the flag, which calls it
        // again, so this deliberately stays at debug level.
        logger.debug("Hiding recorder panel style=\(self.recorderPanelStyle.rawValue, privacy: .public)")
        notchWindowManager?.hide()
        miniWindowManager?.hide()
    }

    /// Between dictations the indicator is either gone or, with the visibility setting
    /// "Always", a compact bar. Call after anything that ends a session or changes a setting.
    private func syncIdleIndicator() {
        guard engine != nil, !isRecorderPanelVisible else { return }

        if RecorderIndicatorSettings.current.visibility == .always {
            showRecorderPanel(idle: true)
        } else {
            notchWindowManager?.destroyWindow()
            notchWindowManager = nil
            miniWindowManager?.destroyWindow()
            miniWindowManager = nil
        }
    }

    // MARK: - Panel Invalidation

    /// Recorder panels must not outlive a sleep/wake cycle or a display reconfiguration.
    ///
    /// `NotchWindowManager.show()` already rebuilds a panel that is not on screen, so the work
    /// here is only about the panel that is currently *hidden but retained*: dropping it frees
    /// the window early and keeps `destroyWindow()` on a path that actually runs. When a
    /// dictation is in progress the panel stays put and is only repositioned, so an active
    /// session never loses its UI.
    ///
    /// `didChangeScreenParameters` fires several times per reconfiguration and displays need a
    /// moment to settle afterwards, so the work is debounced and re-armed on every event
    /// instead of guessing a single settle delay.
    private func invalidatePanels(reason: String) {
        panelInvalidationTask?.cancel()
        panelInvalidationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.applyPanelInvalidation(reason: reason)
        }
    }

    private func applyPanelInvalidation(reason: String) {
        guard isRecorderPanelVisible else {
            logger.notice("Discarding idle recorder panels (\(reason, privacy: .public))")
            notchWindowManager?.destroyWindow()
            notchWindowManager = nil
            miniWindowManager?.destroyWindow()
            miniWindowManager = nil
            syncIdleIndicator()
            return
        }

        logger.notice("Repositioning visible recorder panel (\(reason, privacy: .public))")
        showRecorderPanel()
    }

    /// Drops the current panel and shows a fresh one, for a changed style or placement setting.
    private func rebuildPanels() {
        notchWindowManager?.destroyWindow()
        notchWindowManager = nil
        miniWindowManager?.destroyWindow()
        miniWindowManager = nil

        guard isRecorderPanelVisible else {
            syncIdleIndicator()
            return
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard self.isRecorderPanelVisible else { return }
            self.showRecorderPanel()
        }
    }

    // MARK: - Recorder Panel Management

    func toggleRecorderPanel(modeId: UUID? = nil) async {
        guard let engine = engine else { return }

        if isRecorderPanelVisible {
            switch engine.recordingState {
            case .recording:
                await engine.toggleRecord(modeId: modeId)
            case .starting, .transcribing, .enhancing:
                await cancelRecording()
            case .idle:
                if engine.assistantSession.canSendFollowUp {
                    playStartSound()
                    await engine.toggleRecord(
                        modeId: modeId,
                        isAssistantFollowUp: true
                    )
                } else {
                    await dismissRecorderPanel()
                }
            case .busy:
                await dismissRecorderPanel()
            }
        } else {
            playStartSound()
            isRecorderPanelVisible = true
            await engine.toggleRecord(modeId: modeId)
        }
    }

    /// The level check listens from the moment the start sound is played, so the sound is in its window.
    private func playStartSound() {
        PlaybackController.shared.beginLevelProbe()
        SoundManager.shared.play(.start)
    }

    func finishRecordingAndSend() async {
        guard isRecorderPanelVisible, let engine, engine.recordingState == .recording else { return }
        await engine.toggleRecord(sendAfterPaste: true)
    }

    var isActivelyRecording: Bool {
        isRecorderPanelVisible && engine?.recordingState == .recording
    }

    var recordingStatePublisher: AnyPublisher<RecordingState, Never>? {
        engine?.$recordingState.eraseToAnyPublisher()
    }

    func dismissRecorderPanel() async {
        guard let engine = engine else { return }

        hideRecorderPanel()
        isRecorderPanelVisible = false
        engine.assistantSession.reset()
        syncIdleIndicator()
    }

    func resetOnLaunch() async {
        guard let engine = engine else { return }
        logger.notice("Resetting recording state on launch")
        await engine.resetRecordingSession()
        hideRecorderPanel()
        isRecorderPanelVisible = false
        engine.assistantSession.reset()
        syncIdleIndicator()
    }

    func cancelRecording() async {
        guard let engine = engine else { return }
        switch engine.recordingState {
        case .starting, .recording, .transcribing, .enhancing:
            SoundManager.shared.play(.cancel)
        case .idle, .busy:
            break
        }
        await engine.cancelRecording()
        await dismissRecorderPanel()
    }

    // MARK: - Notification Handling

    private func setupNotifications() {
        guard !didSetupNotifications else { return }
        didSetupNotifications = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleRecorderPanelNotification),
            name: .toggleRecorderPanel,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDismissRecorderPanelNotification),
            name: .dismissRecorderPanel,
            object: nil
        )
        // Display, placement and visibility are read when a panel is built, so a change rebuilds it.
        settingsCancellable = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let settings = RecorderIndicatorSettings.current
                    guard settings != self.lastIndicatorSettings else { return }
                    self.lastIndicatorSettings = settings
                    self.rebuildPanels()
                }
            }
        lifecycleCancellable = LifecycleObserver.shared.publisher(
            for: [.systemDidWake, .displaysDidWake, .screenConfigurationChanged]
        ).sink { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .systemDidWake:
                    self.invalidatePanels(reason: "system wake")
                case .displaysDidWake:
                    self.invalidatePanels(reason: "displays wake")
                case .screenConfigurationChanged:
                    self.invalidatePanels(reason: "screen parameters changed")
                default:
                    break
                }
            }
        }
    }

    @objc public func handleToggleRecorderPanelNotification() {
        Task {
            await toggleRecorderPanel()
        }
    }

    @objc public func handleDismissRecorderPanelNotification() {
        Task {
            switch engine?.recordingState {
            case .starting, .recording, .transcribing, .enhancing:
                await cancelRecording()
            case .idle, .busy, nil:
                await dismissRecorderPanel()
            }
        }
    }
}
