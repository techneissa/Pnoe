import XCTest

/// A shortcut press while the recorder shows the take's paste, check mark or error symbol starts the
/// next take at once, in every mode, and a release stops it. The recorder is modelled by closures that
/// follow `RecorderUIManager.toggleRecorderPanel`.
@MainActor
final class RecorderOutcomeShortcutTests: XCTestCase {
    @MainActor private final class Recorder {
        var state: RecordingState
        var visible: Bool
        var toggles = 0
        var cancels = 0
        var handler: RecordingShortcutModeHandler<String>!

        init(state: RecordingState, visible: Bool = true) {
            self.state = state
            self.visible = visible
            handler = RecordingShortcutModeHandler<String>(
                isModeAction: { $0.hasPrefix("mode") },
                canHandleShortcutAction: { [unowned self] in self.state.acceptsShortcutAction },
                isRecorderVisible: { [unowned self] in self.visible },
                recordingState: { [unowned self] in self.state },
                toggleRecorderPanel: { [unowned self] _ in self.toggle() },
                cancelRecording: { [unowned self] in self.cancels += 1 })
        }

        /// What `RecorderUIManager.toggleRecorderPanel` does for each state.
        private func toggle() {
            toggles += 1
            guard visible else {
                visible = true
                state = .recording
                return
            }
            switch state {
            case .recording: state = .transcribing
            case .starting, .transcribing, .enhancing: state = .idle
            case .pasting, .done, .failed: state = .recording
            case .idle, .busy: visible = false
            }
        }
    }

    private func press(_ recorder: Recorder, mode: RecordingShortcutMode, holding seconds: TimeInterval = 1) async {
        await recorder.handler.handleShortcutDown(action: "primary", eventTime: 100, mode: mode)
        await recorder.handler.handleShortcutUp(action: "primary", eventTime: 100 + seconds, mode: mode)
    }

    func testPushToTalkDuringAnOutcomeStartsOnPressAndStopsOnRelease() async {
        for state in [RecordingState.done, .failed, .pasting] {
            let recorder = Recorder(state: state)
            await recorder.handler.handleShortcutDown(action: "primary", eventTime: 100, mode: .pushToTalk)
            XCTAssertEqual(recorder.state, .recording, "press during \(state) starts at once")
            XCTAssertEqual(recorder.toggles, 1, "\(state)")
            await recorder.handler.handleShortcutUp(action: "primary", eventTime: 101, mode: .pushToTalk)
            XCTAssertEqual(recorder.state, .transcribing, "release stops that take (\(state))")
            XCTAssertEqual(recorder.toggles, 2, "\(state)")
        }
    }

    func testToggleDuringAnOutcomeStartsTheNextTake() async {
        for state in [RecordingState.done, .failed, .pasting] {
            let recorder = Recorder(state: state)
            await press(recorder, mode: .toggle, holding: 0.1)
            XCTAssertEqual(recorder.state, .recording, "\(state)")
            XCTAssertEqual(recorder.toggles, 1, "\(state)")
        }
    }

    func testHybridAndDoubleTapDuringAnOutcomeStartTheNextTake() async {
        let hybrid = Recorder(state: .done)
        await hybrid.handler.handleShortcutDown(action: "primary", eventTime: 100, mode: .hybrid)
        XCTAssertEqual(hybrid.state, .recording)

        let doubleTap = Recorder(state: .failed)
        await press(doubleTap, mode: .doubleTap, holding: 0.1)
        await doubleTap.handler.handleShortcutDown(action: "primary", eventTime: 100.3, mode: .doubleTap)
        await doubleTap.handler.handleShortcutUp(action: "primary", eventTime: 100.4, mode: .doubleTap)
        XCTAssertEqual(doubleTap.state, .recording)
    }

    func testThePlainCaseStillWorks() async {
        // Dictate: press starts, release stops; the take is processed and the panel closes later.
        let recorder = Recorder(state: .idle, visible: false)
        await recorder.handler.handleShortcutDown(action: "primary", eventTime: 100, mode: .pushToTalk)
        XCTAssertEqual(recorder.state, .recording)
        await recorder.handler.handleShortcutUp(action: "primary", eventTime: 102, mode: .pushToTalk)
        XCTAssertEqual(recorder.state, .transcribing)
        XCTAssertEqual(recorder.toggles, 2)
    }

    func testAPressWhileTheTakeIsBeingTranscribedIsStillIgnored() async {
        let recorder = Recorder(state: .transcribing)
        await recorder.handler.handleShortcutDown(action: "primary", eventTime: 100, mode: .pushToTalk)
        XCTAssertEqual(recorder.toggles, 0)
        XCTAssertFalse(RecordingState.transcribing.acceptsShortcutAction)
        XCTAssertFalse(RecordingState.enhancing.acceptsShortcutAction)
        XCTAssertFalse(RecordingState.busy.acceptsShortcutAction)
        for state in [RecordingState.idle, .recording, .starting, .pasting, .done, .failed] {
            XCTAssertTrue(state.acceptsShortcutAction, "\(state)")
        }
    }

    func testTheStatesThatStartTheNextTakeAtOnce() {
        for state in [RecordingState.pasting, .done, .failed] {
            XCTAssertTrue(state.startsNextTakeAtOnce, "\(state)")
        }
        for state in [RecordingState.idle, .starting, .recording, .transcribing, .enhancing, .busy] {
            XCTAssertFalse(state.startsNextTakeAtOnce, "\(state)")
        }
    }
}
