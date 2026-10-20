import SwiftUI
import XCTest

/// The moment table as plain values: how long each moment takes, which symbol effect each job phase
/// plays, which symbol each state shows, and that Reduce Motion removes the animation and leaves the
/// same end state. No window is created.
final class MotionTests: XCTestCase {
    // MARK: - Timing

    func testNoMomentTakesLongerThanTheLimit() {
        for moment in Motion.allCases {
            XCTAssertGreaterThan(moment.baseDuration, 0, "\(moment)")
            XCTAssertLessThanOrEqual(moment.baseDuration, Motion.longestDuration, "\(moment)")
        }
    }

    func testTheDocumentedStartingPoints() {
        XCTAssertEqual(Motion.hover.baseDuration, 0.12)
        XCTAssertEqual(Motion.disclosure.baseDuration, 0.15)
        XCTAssertEqual(Motion.copy.baseDuration, 0.15)
        XCTAssertEqual(Motion.symbolReplace.baseDuration, 0.18)
        XCTAssertEqual(Motion.panel.baseDuration, 0.2)
        XCTAssertEqual(Motion.finish.baseDuration, 0.2)
        XCTAssertEqual(Motion.failure.baseDuration, 0.2)
        XCTAssertEqual(Motion.copiedHold, 1.0)
    }

    func testReduceMotionGivesNoAnimationAndNoDuration() {
        for moment in Motion.allCases {
            XCTAssertNil(moment.animation(reduceMotion: true), "\(moment)")
            XCTAssertEqual(moment.duration(reduceMotion: true), 0, "\(moment)")
            XCTAssertNotNil(moment.animation(reduceMotion: false), "\(moment)")
            XCTAssertEqual(moment.duration(reduceMotion: false), moment.baseDuration, "\(moment)")
        }
    }

    func testReduceMotionReachesTheSameEndState() {
        for reduceMotion in [false, true] {
            var copied = false
            let result = Motion.animate(.copy, reduceMotion: reduceMotion) { () -> Int in
                copied = true
                return 7
            }
            XCTAssertTrue(copied, "reduceMotion \(reduceMotion)")
            XCTAssertEqual(result, 7)
        }
    }

    // MARK: - Loops

    func testALoopRunsOnlyWhileItsJobRunsAndNeverUnderReduceMotion() {
        XCTAssertTrue(Motion.loopRuns(isActive: true, reduceMotion: false))
        XCTAssertFalse(Motion.loopRuns(isActive: false, reduceMotion: false))
        XCTAssertFalse(Motion.loopRuns(isActive: true, reduceMotion: true))
        XCTAssertFalse(Motion.loopRuns(isActive: false, reduceMotion: true))

        XCTAssertNotNil(Motion.loop(period: 1, isActive: true, reduceMotion: false))
        XCTAssertNil(Motion.loop(period: 1, isActive: false, reduceMotion: false))
        XCTAssertNil(Motion.loop(period: 1, isActive: true, reduceMotion: true))
    }

    // MARK: - State → effect

    func testEachPhasePlaysItsOwnEffectAndIdleNone() {
        XCTAssertEqual(Motion.symbolEffect(for: .idle, reduceMotion: false), .none)
        XCTAssertEqual(Motion.symbolEffect(for: .running, reduceMotion: false), .pulse)
        XCTAssertEqual(Motion.symbolEffect(for: .finished, reduceMotion: false), .bounce)
        XCTAssertEqual(Motion.symbolEffect(for: .failed, reduceMotion: false), .wiggle)
    }

    func testNoPhasePlaysAnEffectUnderReduceMotion() {
        for phase in [MotionPhase.idle, .running, .finished, .failed] {
            XCTAssertEqual(Motion.symbolEffect(for: phase, reduceMotion: true), .none, "\(phase)")
        }
    }

    func testOnlyARunningJobLoops() {
        let looping = [MotionPhase.idle, .running, .finished, .failed].filter {
            Motion.symbolEffect(for: $0, reduceMotion: false) == .pulse
        }
        XCTAssertEqual(looping, [.running])
    }

    // MARK: - Symbols after each change

    func testAJobShowsItsOwnSymbolThenACheckMarkOrTheErrorSymbol() {
        XCTAssertEqual(Motion.symbol(for: .idle, idle: "play.fill", running: "hourglass"), "play.fill")
        XCTAssertEqual(Motion.symbol(for: .running, idle: "play.fill", running: "hourglass"), "hourglass")
        XCTAssertEqual(Motion.symbol(for: .running, idle: "arrow.down.circle"), "arrow.down.circle")
        XCTAssertEqual(Motion.symbol(for: .finished, idle: "play.fill", running: "hourglass"), "checkmark")
        XCTAssertEqual(Motion.symbol(for: .failed, idle: "play.fill", running: "hourglass"), "exclamationmark.triangle")
    }

    func testACopyShowsACheckMarkAndGoesBack() {
        XCTAssertEqual(Motion.copySymbol(copied: false), "doc.on.doc")
        XCTAssertEqual(Motion.copySymbol(copied: true), "checkmark")
        XCTAssertEqual(Motion.copySymbol(copied: false, idle: "square.and.arrow.down"), "square.and.arrow.down")
        XCTAssertEqual(Motion.copySymbol(copied: true, idle: "square.and.arrow.down"), "checkmark")
    }

    func testAnOnOffControlSwapsBetweenTwoSymbols() {
        XCTAssertEqual(Motion.toggleSymbol(isOn: true, on: "eye.slash", off: "eye"), "eye.slash")
        XCTAssertEqual(Motion.toggleSymbol(isOn: false, on: "eye.slash", off: "eye"), "eye")
    }

    // MARK: - Hold

    @MainActor
    func testASecondCopyKeepsItsCheckForAFullHold() async throws {
        let hold = MotionHold()
        hold.hold(for: 0.3, reduceMotion: true)
        XCTAssertTrue(hold.isHeld)
        try await Task.sleep(nanoseconds: 200_000_000)
        hold.hold(for: 0.3, reduceMotion: true)
        // 0.4 s after the first copy: the first hold would have ended at 0.3 s.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(hold.isHeld, "the first copy's timer must not clear the second copy's check")
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(hold.isHeld)
    }

    @MainActor
    func testLeavingTheViewCancelsThePendingReset() async throws {
        let hold = MotionHold()
        hold.hold(for: 0.1, reduceMotion: true)
        hold.cancel()
        XCTAssertFalse(hold.isHeld)
        hold.hold(for: 0.1, reduceMotion: true)
        hold.cancel()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(hold.isHeld)
    }

    // MARK: - Hover

    func testHoverLightsOnlyAnEnabledUnselectedControlUnderThePointer() {
        XCTAssertTrue(Motion.hoverIsLit(pointerInside: true, isEnabled: true, suppressed: false))
        XCTAssertFalse(Motion.hoverIsLit(pointerInside: false, isEnabled: true, suppressed: false))
        XCTAssertFalse(Motion.hoverIsLit(pointerInside: true, isEnabled: false, suppressed: false))
        XCTAssertFalse(Motion.hoverIsLit(pointerInside: true, isEnabled: true, suppressed: true))
    }

    // MARK: - Turning

    func testAnElementTurnsOnlyWhileThePointerIsOverIt() {
        XCTAssertTrue(Motion.hoverTurns(pointerInside: true, reduceMotion: false))
        XCTAssertFalse(Motion.hoverTurns(pointerInside: false, reduceMotion: false))
    }

    func testReduceMotionNeverTurns() {
        XCTAssertFalse(Motion.hoverTurns(pointerInside: true, reduceMotion: true))
        XCTAssertFalse(Motion.hoverTurns(pointerInside: false, reduceMotion: true))
    }

    func testTheAngleRestsUntilItTurns() {
        let turn = MotionTurn(rest: 200, period: 2.6)
        XCTAssertEqual(turn.angle(at: 0), 200)
        XCTAssertEqual(turn.angle(at: 50), 200)
        XCTAssertFalse(turn.isMoving(at: 50))
    }

    func testATurningAngleDoesOneTurnPerPeriodAtSteadySpeed() {
        var turn = MotionTurn(rest: 200, period: 2.6)
        turn.setTurning(true, at: 10)
        // Past the short ramp up, the speed is 360 / 2.6 degrees per second.
        let later = turn.angle(at: 20) - turn.angle(at: 10 + 2.6)
        XCTAssertEqual(later, 360 / 2.6 * (20 - 12.6), accuracy: 1e-6)
        XCTAssertEqual(turn.currentSpeed(at: 20), 360 / 2.6, accuracy: 1e-9)
        XCTAssertTrue(turn.isMoving(at: 20))
        // One full period at full speed adds a whole turn.
        XCTAssertEqual(turn.angle(at: 15 + 2.6) - turn.angle(at: 15), 360, accuracy: 1e-6)
    }

    func testTheAngleEasesToAStopWithoutAJumpAndStaysStill() {
        var turn = MotionTurn(rest: 0, period: 2.6)
        turn.setTurning(true, at: 0)
        let leaving = 5.0
        let before = turn.angle(at: leaving)
        turn.setTurning(false, at: leaving)
        // No jump at the moment the pointer leaves, and the speed falls steadily to zero.
        XCTAssertEqual(turn.angle(at: leaving), before, accuracy: 1e-9)
        XCTAssertEqual(turn.currentSpeed(at: leaving), 360 / 2.6, accuracy: 1e-9)
        let half = leaving + turn.rampDuration / 2
        XCTAssertEqual(turn.currentSpeed(at: half), 360 / 2.6 / 2, accuracy: 1e-9)
        // It only ever moves forward, and comes to rest after `rampDuration`.
        var last = before
        for step in 1...20 {
            let angle = turn.angle(at: leaving + Double(step) * turn.rampDuration / 10)
            XCTAssertGreaterThanOrEqual(angle, last)
            last = angle
        }
        let stopped = turn.angle(at: leaving + turn.rampDuration)
        XCTAssertEqual(stopped - before, 360 / 2.6 * turn.rampDuration / 2, accuracy: 1e-9)
        XCTAssertEqual(turn.angle(at: leaving + 100), stopped, accuracy: 1e-9)
        XCTAssertFalse(turn.isMoving(at: leaving + 100))
    }

    func testAStopCanBeInterruptedByTurningAgain() {
        var turn = MotionTurn(rest: 0, period: 2.6)
        turn.setTurning(true, at: 0)
        turn.setTurning(false, at: 5)
        let midStop = 5 + turn.rampDuration / 2
        let angle = turn.angle(at: midStop)
        turn.setTurning(true, at: midStop)
        XCTAssertEqual(turn.angle(at: midStop), angle, accuracy: 1e-9)
        XCTAssertEqual(turn.currentSpeed(at: midStop), 360 / 2.6 / 2, accuracy: 1e-9)
        XCTAssertEqual(turn.currentSpeed(at: midStop + 1), 360 / 2.6, accuracy: 1e-9)
    }

    func testStoppingAtOnceKeepsTheAngleAndRests() {
        var turn = MotionTurn(rest: 0, period: 2.6)
        turn.setTurning(true, at: 0)
        let angle = turn.angle(at: 3)
        turn.stop(at: 3)
        XCTAssertEqual(turn.angle(at: 3), angle, accuracy: 1e-9)
        XCTAssertEqual(turn.angle(at: 30), angle, accuracy: 1e-9)
        XCTAssertFalse(turn.isMoving(at: 3))
    }

    // MARK: - Where the app uses them

    func testTheDownloadRowFollowsTheDownloadThroughItsPhases() {
        // Idle shows the download symbol, a running download the cancel symbol (it pulses), a failed one the error symbol.
        XCTAssertEqual(
            Motion.symbol(for: .idle, idle: "arrow.down.circle", running: "xmark.circle"), "arrow.down.circle")
        XCTAssertEqual(
            Motion.symbol(for: .running, idle: "arrow.down.circle", running: "xmark.circle"), "xmark.circle")
        XCTAssertEqual(
            Motion.symbol(for: .failed, idle: "arrow.down.circle", running: "xmark.circle"), "exclamationmark.triangle")
    }
}
