import XCTest

/// How a take ends in the recorder: processing → done (check mark) or failed (error symbol) →
/// hidden, never delaying the paste or the next recording, never for a recorder that is gone.
/// The flow takes its state and its hide as closures, so no engine, window or sound is involved.
@MainActor
final class RecorderOutcomeTests: XCTestCase {
    /// A recorder stand-in: a state, a visible flag and a log of every state it went through.
    @MainActor private final class Stage {
        var state: RecordingState
        var visible = true
        var states: [RecordingState] = []
        var hides = 0
        var flow: RecorderOutcomeFlow!

        init(_ state: RecordingState, hold: TimeInterval = 0.05) {
            self.state = state
            states = [state]
            flow = RecorderOutcomeFlow(
                hold: hold,
                currentState: { [unowned self] in self.state },
                setState: { [unowned self] in
                    self.state = $0
                    self.states.append($0)
                },
                isRecorderVisible: { [unowned self] in self.visible },
                hide: { [unowned self] in
                    self.hides += 1
                    self.visible = false
                })
        }
    }

    private func settle(_ seconds: TimeInterval = 0.3) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - States

    func testProcessingGoesToDoneAndThenHides() async throws {
        let stage = Stage(.transcribing)
        XCTAssertTrue(stage.flow.show(.done))
        XCTAssertEqual(stage.state, .done)
        XCTAssertEqual(stage.hides, 0, "the check mark shows before the recorder hides")
        try await settle()
        XCTAssertEqual(stage.states, [.transcribing, .done, .idle])
        XCTAssertEqual(stage.hides, 1)
    }

    func testProcessingGoesToFailedAndThenHides() async throws {
        let stage = Stage(.enhancing)
        XCTAssertTrue(stage.flow.show(.failed))
        XCTAssertEqual(stage.state, .failed)
        try await settle()
        XCTAssertEqual(stage.states, [.enhancing, .failed, .idle])
        XCTAssertEqual(stage.hides, 1)
    }

    func testACancelledTakeShowsTheErrorSymbol() async throws {
        // The engine has already gone back to idle when the recorder shows the cancel.
        let stage = Stage(.idle)
        XCTAssertTrue(stage.flow.show(.failed))
        try await settle()
        XCTAssertEqual(stage.states, [.idle, .failed, .idle])
        XCTAssertEqual(stage.hides, 1)
    }

    func testTheOutcomeStatesAreRecordedAsOutcomes() {
        XCTAssertEqual(RecorderOutcome.done.state, .done)
        XCTAssertEqual(RecorderOutcome.failed.state, .failed)
        XCTAssertEqual(RecordingState.done.outcome, .done)
        XCTAssertEqual(RecordingState.failed.outcome, .failed)
        XCTAssertNil(RecordingState.recording.outcome)
        XCTAssertTrue(RecordingState.done.isOutcome)
        XCTAssertTrue(RecordingState.failed.isOutcome)
        XCTAssertFalse(RecordingState.idle.isOutcome)
    }

    // MARK: - Never delaying, never stale

    func testANewRecordingReplacesTheOutcomeAtOnceAndNothingHidesIt() async throws {
        let stage = Stage(.transcribing, hold: 0.1)
        stage.flow.show(.done)
        // The next take starts while the check mark shows: the engine drops the outcome first.
        stage.flow.interrupt()
        XCTAssertEqual(stage.state, .idle, "the check mark goes at once")
        stage.state = .starting
        stage.state = .recording
        try await settle(0.4)
        XCTAssertEqual(stage.state, .recording, "the old hold must not touch the new take")
        XCTAssertEqual(stage.hides, 0)
    }

    func testAnOutcomeNeverReplacesARecordingOrAnotherOutcome() {
        let stage = Stage(.recording)
        XCTAssertFalse(stage.flow.show(.done))
        XCTAssertFalse(stage.flow.show(.failed))
        stage.state = .starting
        XCTAssertFalse(stage.flow.show(.failed))
        XCTAssertEqual(stage.states, [.recording])

        stage.state = .transcribing
        XCTAssertTrue(stage.flow.show(.done))
        XCTAssertFalse(stage.flow.show(.failed), "an outcome that already shows stays")
        XCTAssertEqual(stage.state, .done)
    }

    func testNoOutcomeForARecorderThatIsAlreadyHidden() async throws {
        let stage = Stage(.transcribing)
        stage.visible = false
        XCTAssertFalse(stage.flow.show(.done))
        XCTAssertEqual(stage.states, [.transcribing])
        try await settle()
        XCTAssertEqual(stage.hides, 0)
    }

    func testClosingTheRecorderDuringTheOutcomeCancelsTheHide() async throws {
        let stage = Stage(.transcribing, hold: 0.1)
        stage.flow.show(.failed)
        stage.flow.interrupt()
        try await settle(0.4)
        XCTAssertEqual(stage.hides, 0, "the recorder was closed by someone else; the timer must not hide it again")
        XCTAssertEqual(stage.states, [.transcribing, .failed, .idle])
    }

    func testAnOutcomeShowsOverAPasteThatIsStillLanding() async throws {
        let stage = Stage(.pasting)
        XCTAssertTrue(stage.flow.show(.done))
        try await settle()
        XCTAssertEqual(stage.states, [.pasting, .done, .idle])
        XCTAssertTrue(RecordingState.pasting.isProcessing)
    }

    func testARecorderThatMustStayUpIsNotHiddenAfterTheError() async throws {
        let stage = Stage(.enhancing)
        XCTAssertTrue(stage.flow.show(.failed, hidesRecorder: false))
        XCTAssertEqual(stage.state, .failed)
        try await settle()
        XCTAssertEqual(stage.states, [.enhancing, .failed, .idle])
        XCTAssertEqual(stage.hides, 0, "the answer panel stays up")
    }

    func testTheHoldIsShortAndBelongsToMotion() {
        XCTAssertEqual(Motion.outcomeHold, 0.6)
        XCTAssertLessThanOrEqual(Motion.outcomeHold, 1.0)
    }

    // MARK: - Paste first

    func testThePasteStartsBeforeTheDoneState() async {
        var log: [String] = []
        let result = await RecorderOutcomeFlow.report(
            afterPaste: {
                log.append("paste")
                return Task { true }
            },
            landed: { $0 },
            into: { log.append("outcome \($0)") })
        XCTAssertEqual(result, true)
        XCTAssertEqual(log, ["paste", "outcome done"])
    }

    func testAPasteThatNeverReturnsShowsTheErrorAfterTheTimeout() async {
        var outcomes: [RecorderOutcome] = []
        let stuck = Task<Bool, Never> {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 100_000_000) }
            return true
        }
        let started = Date()
        let result = await RecorderOutcomeFlow.report(
            afterPaste: { stuck }, landed: { $0 }, timeout: 0.1, into: { outcomes.append($0) })
        stuck.cancel()
        XCTAssertNil(result)
        XCTAssertEqual(outcomes, [.failed])
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(RecorderOutcomeFlow.pasteTimeout, 3)
    }

    func testAPasteResultThatArrivesAfterTheTimeoutIsIgnored() async throws {
        var outcomes: [RecorderOutcome] = []
        let late = Task<Bool, Never> {
            try? await Task.sleep(nanoseconds: 250_000_000)
            return true
        }
        let result = await RecorderOutcomeFlow.report(
            afterPaste: { late }, landed: { $0 }, timeout: 0.05, into: { outcomes.append($0) })
        XCTAssertNil(result)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(outcomes, [.failed], "the late result must not show a check mark")
    }

    func testAPasteThatReturnsInTimeIsNotCutShort() async {
        var outcomes: [RecorderOutcome] = []
        let result = await RecorderOutcomeFlow.report(
            afterPaste: { Task { true } }, landed: { $0 }, timeout: 0.5, into: { outcomes.append($0) })
        XCTAssertEqual(result, true)
        XCTAssertEqual(outcomes, [.done])
    }

    func testAPasteThatDidNotLandIsAFailure() async {
        var outcomes: [RecorderOutcome] = []
        _ = await RecorderOutcomeFlow.report(
            afterPaste: { Task { false } }, landed: { $0 }, into: { outcomes.append($0) })
        XCTAssertEqual(outcomes, [.failed])
    }

    func testATakeThatHadAnAIErrorIsAFailureEvenWhenThePasteLanded() async {
        var outcomes: [RecorderOutcome] = []
        _ = await RecorderOutcomeFlow.report(
            afterPaste: { Task { true } }, landed: { $0 }, takeHadError: true, into: { outcomes.append($0) })
        XCTAssertEqual(outcomes, [.failed])
    }

    // MARK: - Controls

    func testTheRecordControlStartsANewTakeDuringAnOutcome() {
        XCTAssertTrue(RecordingState.done.allowsRecordButton)
        XCTAssertTrue(RecordingState.failed.allowsRecordButton)
        XCTAssertEqual(RecordingState.done.recordButtonLabel, RecordingState.idle.recordButtonLabel)
        XCTAssertEqual(RecordingState.failed.recordButtonLabel, RecordingState.idle.recordButtonLabel)
    }

    func testTheDotKeepsItsTimerDuringAnOutcome() {
        XCTAssertTrue(RecorderDotView.showsTimer(for: .done))
        XCTAssertTrue(RecorderDotView.showsTimer(for: .failed))
    }

    // MARK: - Reduce Motion

    func testReduceMotionShowsTheSameIconsAndStatesWithoutMovement() async throws {
        for outcome in [RecorderOutcome.done, .failed] {
            XCTAssertEqual(
                Motion.symbol(for: outcome.phase, idle: ""),
                outcome == .done ? "checkmark" : "exclamationmark.triangle")
            XCTAssertEqual(
                Motion.symbolEffect(for: outcome.phase, reduceMotion: false), outcome == .done ? .bounce : .wiggle)
            XCTAssertEqual(Motion.symbolEffect(for: outcome.phase, reduceMotion: true), .none)
        }
        // The hold does not shrink under Reduce Motion: the icon is the message, only the movement goes.
        XCTAssertEqual(Motion.outcomeHold, 0.6)
        var reachedWithMotion = false
        var reachedWithout = false
        Motion.animate(.finish, reduceMotion: false) { reachedWithMotion = true }
        Motion.animate(.finish, reduceMotion: true) { reachedWithout = true }
        XCTAssertTrue(reachedWithMotion && reachedWithout)
        XCTAssertNil(Motion.finish.animation(reduceMotion: true))
        XCTAssertNil(Motion.failure.animation(reduceMotion: true))

        let stage = Stage(.transcribing)
        stage.flow.show(.done)
        try await settle()
        XCTAssertEqual(stage.states, [.transcribing, .done, .idle])
    }
}
