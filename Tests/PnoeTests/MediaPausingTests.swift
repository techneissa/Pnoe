import XCTest
import os

/// Headless checks for media pausing: the decision to press Play/Pause, with fake audio processes, fake levels and a
/// counted key press. Nothing here reads CoreAudio, plays audio, presses a key or asks for a permission.
@MainActor
final class MediaPausingTests: XCTestCase {
    private final class FakeAudio: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: [AudioProcess]())
        var processes: [AudioProcess] {
            get { lock.withLock { $0 } }
            set { lock.withLock { $0 = newValue } }
        }
        func read() -> [AudioProcess] { processes }
    }

    private final class FakeMeter: AudioLevelMeasuring, @unchecked Sendable {
        struct State {
            var reading = AudioLevelReading.sound
                        var asked: [[AudioProcess]] = []
            var permissionRequests = 0
            var granted = true
            var tapWorks = true
        }
        private let lock = OSAllocatedUnfairLock(initialState: State())
        /// What the players' mix reads.
        var reading: AudioLevelReading {
            get { lock.withLock { $0.reading } }
            set { lock.withLock { $0.reading = newValue } }
        }
        var asked: [[AudioProcess]] { lock.withLock { $0.asked } }
        var permissionRequests: Int { lock.withLock { $0.permissionRequests } }
        /// What the permission reads: `hasPermission` (no prompt) and what `requestPermission` ends with.
        var granted: Bool {
            get { lock.withLock { $0.granted } }
            set { lock.withLock { $0.granted = newValue } }
        }
        func hasPermission() async -> Bool { lock.withLock { $0.granted } }
        func requestPermission() async -> Bool {
            lock.withLock { $0.permissionRequests += 1; return $0.granted }
        }
        func forgetAsked() { lock.withLock { $0.asked = [] } }

        func measure(processes: [AudioProcess], window: TimeInterval) async -> AudioLevelMeasurement {
            lock.withLock {
                $0.asked.append(processes)
                return AudioLevelMeasurement(players: $0.reading)
            }
        }
    }

    /// A meter stuck in a CoreAudio call, as when the permission prompt is up.
    private struct StuckMeter: AudioLevelMeasuring {
        func measure(processes: [AudioProcess], window: TimeInterval) async -> AudioLevelMeasurement {
            await withCheckedContinuation { (_: CheckedContinuation<AudioLevelMeasurement, Never>) in }
        }
        func hasPermission() async -> Bool { true }
        func requestPermission() async -> Bool { true }
    }

    private let music = AudioProcess(pid: 100, objectID: 7, bundleID: "com.apple.Music", isRunningOutput: true, isRunningInput: false)
    private let game = AudioProcess(pid: 200, objectID: 8, bundleID: "com.example.game", isRunningOutput: true, isRunningInput: false)
    private let zoom = AudioProcess(pid: 300, objectID: 9, bundleID: "us.zoom.xos", isRunningOutput: true, isRunningInput: false)

    private let suiteName = "PnoeMediaPausingTests-\(UUID().uuidString)"
    private var defaults = UserDefaults.standard
    private var audio = FakeAudio()
    private var meter = FakeMeter()
    private var presses = 0
    private var now: TimeInterval = 1_000

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        audio = FakeAudio()
        meter = FakeMeter()
        presses = 0
        now = 1_000
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeController(
        withMeter: Bool = true, meter: AudioLevelMeasuring? = nil
    ) async -> PlaybackController {
        defaults.set(true, forKey: PlaybackController.pauseMediaKey)
        let audio = self.audio
        let controller = PlaybackController(
            readAudioProcesses: { audio.read() },
            pressKey: { [unowned self] in presses += 1 },
            levelMeter: withMeter ? (meter ?? self.meter) : nil,
            defaults: defaults,
            levelDeadline: 0.2,
            clock: { [unowned self] in now }
        )
        return controller
    }

    /// One dictation: pause at the start, resume at the end.
    private func dictate(_ controller: PlaybackController, lasting seconds: Double = 0.1) async {
        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)
        try? await Task.sleep(for: .seconds(seconds))
        await controller.resumeMedia(sessionID: session)
    }

    // MARK: - The switch and the permission

    func testPausingIsOffByDefaultAndAsksForNoPermission() {
        let controller = PlaybackController(levelMeter: meter, defaults: defaults)
        XCTAssertFalse(controller.isPauseMediaEnabled)
        XCTAssertFalse(controller.needsPermission)
        XCTAssertEqual(meter.permissionRequests, 0)
    }

    func testGrantedPermissionKeepsTheSwitchOn() async {
        let controller = PlaybackController(levelMeter: meter, defaults: defaults)
        controller.isPauseMediaEnabled = true
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(meter.permissionRequests, 1)
        XCTAssertTrue(controller.isPauseMediaEnabled)
        XCTAssertFalse(controller.needsPermission)
        XCTAssertTrue(defaults.bool(forKey: PlaybackController.pauseMediaKey))
    }

    func testDeniedPermissionTurnsTheSwitchOffAndNeverPresses() async {
        meter.granted = false
        audio.processes = [music]
        let controller = PlaybackController(
            readAudioProcesses: { [audio] in audio.read() },
            pressKey: { [unowned self] in presses += 1 },
            levelMeter: meter, defaults: defaults)
        controller.isPauseMediaEnabled = true
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(controller.isPauseMediaEnabled)
        XCTAssertTrue(controller.needsPermission)
        XCTAssertFalse(defaults.bool(forKey: PlaybackController.pauseMediaKey))

        await dictate(controller)
        XCTAssertEqual(presses, 0)
        XCTAssertTrue(meter.asked.isEmpty)
    }

    func testTurningItOnAgainClearsTheNote() async {
        meter.granted = false
        let controller = PlaybackController(levelMeter: meter, defaults: defaults)
        controller.isPauseMediaEnabled = true
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(controller.needsPermission)

        meter.granted = true
        controller.isPauseMediaEnabled = true
        XCTAssertFalse(controller.needsPermission)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(controller.isPauseMediaEnabled)
    }

    func testNoMeterMeansTheSwitchTurnsOffAndNothingIsPressed() async {
        audio.processes = [music]
        let controller = await makeController(withMeter: false)

        await dictate(controller)

        XCTAssertFalse(controller.isPauseMediaEnabled)
        XCTAssertTrue(controller.needsPermission)
        XCTAssertEqual(presses, 0)
    }

    func testPermissionRevokedLaterTurnsTheSwitchOffAtTheNextRecording() async {
        audio.processes = [music]
        meter.reading = .sound
        let controller = await makeController()
        await dictate(controller)
        XCTAssertEqual(presses, 2, "Granted: the level check is used and music is paused and resumed")
        XCTAssertEqual(meter.asked.count, 1)
        presses = 0

        meter.granted = false  // revoked in System Settings
        await dictate(controller)

        XCTAssertFalse(controller.isPauseMediaEnabled)
        XCTAssertTrue(controller.needsPermission)
        XCTAssertEqual(presses, 0)
        XCTAssertEqual(meter.asked.count, 1, "No tap is made without the permission")
    }

    func testPermissionRevokedWhileTheAppWasClosedTurnsTheSwitchOffAtLaunch() async {
        meter.granted = false
        defaults.set(true, forKey: PlaybackController.pauseMediaKey)
        let controller = PlaybackController(levelMeter: meter, defaults: defaults)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(controller.isPauseMediaEnabled)
        XCTAssertTrue(controller.needsPermission)
        XCTAssertEqual(meter.permissionRequests, 0, "Launch never shows the prompt")
    }

    func testAStoredOnSettingWithPermissionStaysOnAtLaunch() async {
        defaults.set(true, forKey: PlaybackController.pauseMediaKey)
        let controller = PlaybackController(levelMeter: meter, defaults: defaults)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(controller.isPauseMediaEnabled)
        XCTAssertFalse(controller.needsPermission)
        XCTAssertEqual(meter.permissionRequests, 0)
    }

    func testAnOldStoredLevelCheckValueIsIgnored() async {
        defaults.set(false, forKey: "isMediaLevelCheckEnabled")
        audio.processes = [music]
        meter.reading = .silent
        let controller = await makeController()
        await dictate(controller)
        XCTAssertEqual(presses, 0)
        XCTAssertEqual(meter.asked.count, 1, "Pausing on always checks the level")
    }

    // MARK: - The level check

    func testPlayingMusicIsPausedAndResumed() async {
        audio.processes = [music]
        meter.reading = .sound
        let controller = await makeController()

        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)
        XCTAssertEqual(presses, 1)

        audio.processes = []
        await controller.resumeMedia(sessionID: session)
        XCTAssertEqual(presses, 2)
    }

    func testLingeringOutputIsNotStartedAgain() async {
        // The player was paused a moment ago: it still reports output, but its audio is silence.
        audio.processes = [music]
        meter.reading = .silent
        let controller = await makeController()

        await dictate(controller)

        XCTAssertEqual(meter.asked.count, 1)
        XCTAssertEqual(presses, 0, "Neither the pause press nor a resume press may start music the user paused")
        XCTAssertTrue(controller.isPauseMediaEnabled, "Silence is a real answer, not a permission problem")
    }

    func testPausingMusicAndDictatingWithinOneSecondStartsNothing() async {
        audio.processes = [music]
        meter.reading = .silent
        let controller = await makeController()

        let started = Date()
        await dictate(controller, lasting: 0.4)

        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertEqual(presses, 0)
    }

    func testATapThatCannotBeMadeTurnsTheSwitchOffAndPressesNothing() async {
        audio.processes = [music]
        meter.reading = .unavailable
        let controller = await makeController()

        await dictate(controller)

        XCTAssertEqual(presses, 0, "The output flag alone never decides")
        XCTAssertFalse(controller.isPauseMediaEnabled)
        XCTAssertTrue(controller.needsPermission)
    }

    func testASkippedMeasurementKeepsTheSwitchOnAndPressesNothing() async {
        // A busy meter, or one with no samples: permission is granted, so only this recording is skipped.
        audio.processes = [music]
        meter.reading = .skipped
        let controller = await makeController()

        await dictate(controller)

        XCTAssertEqual(presses, 0, "Never restart a player that may have been paused a moment ago")
        XCTAssertTrue(controller.isPauseMediaEnabled)
        XCTAssertFalse(controller.needsPermission)

        meter.reading = .sound
        await dictate(controller)
        XCTAssertEqual(presses, 2, "The next recording works")
    }

    func testAMeterThatNeverReturnsSkipsThisRecordingWithinTheDeadline() async {
        audio.processes = [music]
        let controller = await makeController(meter: StuckMeter())

        let started = Date()
        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)

        XCTAssertEqual(presses, 0)
        XCTAssertTrue(controller.isPauseMediaEnabled)
        XCTAssertFalse(controller.needsPermission)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    func testProbeWithRevokedPermissionMakesNoTapAndTurnsTheSwitchOff() async {
        // The start sound starts the probe before pauseMedia runs its own check.
        audio.processes = [music]
        meter.reading = .sound
        let controller = await makeController()
        meter.granted = false

        controller.beginLevelProbe()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(meter.asked.isEmpty, "No tap without the permission")
        XCTAssertFalse(controller.isPauseMediaEnabled)
        XCTAssertTrue(controller.needsPermission)

        await dictate(controller)
        XCTAssertEqual(presses, 0)
        XCTAssertTrue(meter.asked.isEmpty)
    }

    func testNothingPlayingPressesNothing() async {
        audio.processes = [game]
        let controller = await makeController()

        await dictate(controller)

        XCTAssertEqual(presses, 0)
        XCTAssertTrue(meter.asked.isEmpty)
        XCTAssertTrue(controller.isPauseMediaEnabled)
    }

    func testCallBlocksThePressAndTheMeter() async {
        audio.processes = [music, zoom]
        let controller = await makeController()

        await dictate(controller)

        XCTAssertEqual(presses, 0)
        XCTAssertTrue(meter.asked.isEmpty)
    }

    func testMeterIsAskedOnlyAboutThePlayersThatHaveOutput() async {
        audio.processes = [music, game]
        meter.reading = .sound
        let controller = await makeController()

        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)

        XCTAssertEqual(meter.asked, [[music]])
    }

    // MARK: - The probe started with the start sound

    func testProbeAnswersThePause() async {
        audio.processes = [music]
        meter.reading = .silent
        let controller = await makeController()

        controller.beginLevelProbe()
        await dictate(controller)

        XCTAssertEqual(presses, 0)
        XCTAssertEqual(meter.asked.count, 1, "One listening session, started with the start sound")
    }

    func testAProbeFromBeforeTheMusicStartedIsNotUsed() async {
        audio.processes = []
        meter.reading = .sound
        let controller = await makeController()
        controller.beginLevelProbe()
        let session = controller.beginRecordingSession()
        try? await Task.sleep(for: .milliseconds(50))
        audio.processes = [music]
        await controller.pauseMedia(sessionID: session)

        XCTAssertEqual(presses, 1)
        XCTAssertEqual(meter.asked.count, 1)
    }

    func testAPlayerTheProbeDidNotListenToGetsANewLook() async {
        let browser = AudioProcess(pid: 400, objectID: 10, bundleID: "com.google.Chrome", isRunningOutput: true, isRunningInput: false)
        audio.processes = [music]
        meter.reading = .silent
        let controller = await makeController()
        controller.beginLevelProbe()
        try? await Task.sleep(for: .milliseconds(50))
        audio.processes = [music, browser]

        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)

        XCTAssertEqual(meter.asked.count, 2)
        XCTAssertEqual(meter.asked.last, [music, browser], "A new look at both players")
    }

    func testPlayersTheProbeListenedToKeepItsAnswer() async {
        let browser = AudioProcess(pid: 400, objectID: 10, bundleID: "com.google.Chrome", isRunningOutput: true, isRunningInput: false)
        audio.processes = [music, browser]
        meter.reading = .silent
        let controller = await makeController()
        controller.beginLevelProbe()
        try? await Task.sleep(for: .milliseconds(50))
        audio.processes = [music]

        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)

        XCTAssertEqual(presses, 0)
        XCTAssertEqual(meter.asked.count, 1)
    }

    func testAStaleProbeIsIgnored() async {
        audio.processes = [music]
        meter.reading = .silent
        let controller = await makeController()
        controller.beginLevelProbe()
        now += 10

        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)

        XCTAssertEqual(meter.asked.count, 2, "A new look, not the old probe")
        XCTAssertEqual(presses, 0)
    }

    func testNoProbeTapDuringACall() async {
        audio.processes = [music, zoom]
        let controller = await makeController()

        controller.beginLevelProbe()
        await dictate(controller)

        XCTAssertTrue(meter.asked.isEmpty)
        XCTAssertEqual(presses, 0)
    }

    // MARK: - Listening plan

    func testListeningStopsAtOnceWhenAPlayerMakesSound() {
        XCTAssertTrue(ListeningPlan.isDone(elapsed: 0.01, window: 0.3, players: .sound))
    }

    func testListeningWaitsForTheMinimumWindow() {
        XCTAssertFalse(ListeningPlan.isDone(elapsed: 0.05, window: 0.3, players: .silent))
        XCTAssertTrue(ListeningPlan.isDone(elapsed: 0.15, window: 0.3, players: .silent))
    }

    // MARK: - Settings

    func testToggleIsSavedInTheGivenDefaults() {
        let controller = PlaybackController(defaults: defaults)
        controller.isPauseMediaEnabled = true

        XCTAssertTrue(defaults.bool(forKey: PlaybackController.pauseMediaKey))
        XCTAssertTrue(PlaybackController(defaults: defaults).isPauseMediaEnabled)
    }

    // MARK: - Peak meter

    func testZerosAreSilent() {
        var peak = PeakMeter()
        peak.add([Float](repeating: 0, count: 4096))
        XCTAssertEqual(peak.reading, .silent)
    }

    func testSamplesAboveTheThresholdAreSound() {
        var peak = PeakMeter()
        peak.add((0..<4096).map { 0.2 * sin(Float($0) * 0.1) })
        XCTAssertEqual(peak.reading, .sound)
    }

    func testNegativeSamplesCount() {
        var peak = PeakMeter()
        peak.add([0, -0.5, 0])
        XCTAssertEqual(peak.reading, .sound)
    }

    func testNoSamplesIsUnavailableNotSilent() {
        XCTAssertEqual(PeakMeter().reading, .unavailable)
    }

    func testSamplesAtTheThresholdAreSilent() {
        var peak = PeakMeter()
        peak.add([PeakMeter.silenceThreshold, -PeakMeter.silenceThreshold])
        XCTAssertEqual(peak.reading, .silent)
    }

    func testPeakIsKeptAcrossBuffers() {
        var peak = PeakMeter()
        peak.add([Float](repeating: 0, count: 512))
        peak.add([0, 0.3, 0])
        peak.add([Float](repeating: 0, count: 512))
        XCTAssertEqual(peak.reading, .sound)
    }
}
