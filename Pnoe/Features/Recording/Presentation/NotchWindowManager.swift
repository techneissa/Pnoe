import AppKit
import Combine
import SwiftUI
import os

@MainActor
class NotchWindowManager {
    private var windowController: NSWindowController?
    private var panel: NotchRecorderPanel?

    private let assistantSession: AssistantSession
    private var assistantCancellable: AnyCancellable?
    private let makeView: () -> AnyView
    private let logger = Logger(subsystem: "com.techneissa.pnoe", category: "NotchWindowManager")

    init(
        engine: PnoeEngine,
        recorder: Recorder,
        assistantSession: AssistantSession,
        onRecordButtonTapped: @escaping () -> Void,
        onCloseTapped: @escaping () -> Void,
        onAssistantFollowUp: @escaping (String) -> Void
    ) {
        self.assistantSession = assistantSession
        self.makeView = {
            AnyView(
                NotchRecorderView(
                    stateProvider: engine,
                    recorder: recorder,
                    assistantSession: assistantSession,
                    onRecordButtonTapped: onRecordButtonTapped,
                    onCloseTapped: onCloseTapped,
                    onAssistantFollowUp: onAssistantFollowUp
                )
                .autocorrectionDisabled()
            )
        }
    }

    /// Builds a fresh panel whenever one is not already on screen.
    ///
    /// The panel and its hosting view used to be created once and then reused for the whole
    /// lifetime of the app, so a window that stopped rendering — after a sleep/wake cycle, a
    /// display reconfiguration, or any other WindowServer hiccup — kept swallowing every later
    /// `orderFrontRegardless()`, and only relaunching Pnoe brought the recorder back.
    /// A window in that state still reports `isVisible == true` with a sane frame, so there is
    /// nothing reliable to test for from inside the process. Rebuilding unconditionally removes
    /// the question: a stale window can never survive into a second dictation. The cost is one
    /// NSPanel plus one hosting controller per dictation, which is noise next to starting audio
    /// capture and a transcription session in the same code path.
    @discardableResult
    func show(compact: Bool = false) -> Bool {
        if panel == nil { initializeWindow(compact: compact) }
        guard let panel else { return false }
        return panel.show(compact: compact)
    }

    /// Tears the window down rather than just ordering it out, so `isVisible` is never used as a
    /// liveness test and no panel is carried across dictations.
    func hide() {
        deinitializeWindow()
    }

    func destroyWindow() {
        deinitializeWindow()
    }

    // Rebuilding gives the SwiftUI content a new identity, so view-local state inside it is
    // reset — currently the assistant follow-up draft and its focus. The conversation itself
    // lives in `AssistantSession`, which is owned by the engine and survives.
    private func initializeWindow(compact: Bool) {
        deinitializeWindow()
        guard let metrics = NotchRecorderPanel.calculateWindowMetrics(compact: compact) else {
            logger.error("Notch panel not created: no screen available")
            return
        }
        let newPanel = NotchRecorderPanel(contentRect: metrics.frame)
        let view = makeView()
        let hostingController = NotchRecorderHostingController(rootView: view)
        newPanel.contentView = hostingController.view
        panel = newPanel
        // The panel takes the keyboard only while the assistant's text field is on screen.
        assistantCancellable = assistantSession.$phase
            .map { $0 != .inactive }
            .removeDuplicates()
            .sink { [weak newPanel] visible in
                newPanel?.acceptsKeyboardInput = RecorderKeyWindowPolicy.canBecomeKey(assistantVisible: visible)
            }
        windowController = NSWindowController(window: newPanel)
    }

    private func deinitializeWindow() {
        assistantCancellable = nil
        panel?.orderOut(nil)
        windowController?.close()
        windowController = nil
        panel = nil
    }

}
