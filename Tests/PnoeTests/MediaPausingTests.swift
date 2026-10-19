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
            var own = AudioLevelReading.silent
            var asked: [[AudioProcess]] = []
            var askedForOwn: [Bool] = []
        }
        private let lock = OSAllocatedUnfairLock(initialState: State())
        /// What the players' mix reads.
        var reading: AudioLevelReading {
            get { lock.withLock { $0.reading } }
            set { lock.withLock { $0.reading = newValue } }
        }
        /// What Pnoe's own start sound reads, when it is asked for.
        var own: AudioLevelReading {
            get { lock.withLock { $0.own } }
            set { lock.withLock { $0.own = newValue } }
        }
        var asked: [[AudioProcess]] { lock.withLock { $0.asked } }
        var askedForOwn: [Bool] { lock.withLock { $0.askedForOwn } }
        func forgetAsked() { lock.withLock { $0.asked = []; $0.askedForOwn = [] } }

        func measure(processes: [AudioProcess], includingOwnProcess: Bool, window: TimeInterval) async
            -> AudioLevelMeasurement
        {
            lock.withLock {
                $0.asked.append(processes)
                $0.askedForOwn.append(includingOwnProcess)
                return AudioLevelMeasurement(players: $0.reading, own: includingOwnProcess ? $0.own : nil)
            }
        }
    }

    /// A meter stuck in a CoreAudio call, as when the permission prompt is up.
    private struct StuckMeter: AudioLevelMeasuring {
        func measure(processes: [AudioProcess], includingOwnProcess: Bool, window: TimeInterval) async
            -> AudioLevelMeasurement
        {
            await withCheckedContinuation { (_: CheckedContinuation<AudioLevelMeasurement, Never>) in }
        }
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
    private var startSoundOn = false

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        audio = FakeAudio()
        meter = FakeMeter()
        presses = 0
        now = 1_000
        startSoundOn = false
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// `heardSound` first runs one dictation over playing music, so the check has proof that the tap works.
    private func makeController(
        levelCheck: Bool, heardSound: Bool = false, startSound: Bool = false, meter: AudioLevelMeasuring? = nil
    ) async -> PlaybackController {
        startSoundOn = startSound
        defaults.set(true, forKey: PlaybackController.pauseMediaKey)
        defaults.set(levelCheck, forKey: PlaybackController.levelCheckKey)
        let audio = self.audio
        let controller = PlaybackController(
            readAudioProcesses: { audio.read() },
            pressKey: { [unowned self] in presses += 1 },
            levelMeter: meter ?? self.meter,
            defaults: defaults,
            levelDeadline: 0.2,
            clock: { [unowned self] in now },
            isStartSoundOn: { [unowned self] in startSoundOn }
        )
        if heardSound {
            let before = (audio.processes, self.meter.reading)
            audio.processes = [music]
            self.meter.reading = .sound
            let session = controller.beginRecordingSession()
            await controller.pauseMedia(sessionID: session)
            audio.processes = []
            await controller.resumeMedia(sessionID: session)
            audio.processes = before.0
            self.meter.reading = before.1
            self.meter.forgetAsked()
            presses = 0
        }
        return controller
    }

    /// One dictation: pause at the start, resume at the end.
    private func dictate(_ controller: PlaybackController, lasting seconds: Double = 0.1) async {
        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)
        try? await Task.sleep(for: .seconds(seconds))
        await controller.resumeMedia(sessionID: session)
    }

    // MARK: - Without the level check (the default, no permission)

    func testPlayingPlayerIsPausedAndResumed() async {
        audio.processes = [music]
        let controller = await makeController(levelCheck: false)

        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)
        XCTAssertEqual(presses, 1)

        audio.processes = []  // the press paused it and its output stopped
        await controller.resumeMedia(sessionID: session)
        XCTAssertEqual(presses, 2)
    }

    func testLevelCheckIsOffByDefault() {
        let controller = PlaybackController(defaults: defaults)
        XCTAssertFalse(controller.isLevelCheckEnabled)
        XCTAssertFalse(controller.isPauseMediaEnabled)
    }

    func testMeterIsNeverAskedWhileTheCheckIsOff() async {
        audio.processes = [music]
        meter.reading = .silent
        let controller = await makeController(levelCheck: false, heardSound: true)

        await dictate(controller)

        XCTAssertTrue(meter.asked.isEmpty, "The default path must not touch the tap, which would ask for a permission")
        XCTAssertEqual(presses, 2)
    }

    func testNothingPlayingPressesNothing() async {
        audio.processes = [game]
        let controller = await makeController(levelCheck: true, heardSound: true)

        await dictate(controller)

        XCTAssertEqual(presses, 0)
        XCTAssertTrue(meter.asked.isEmpty)
    }

    func testCallBlocksThePressAndTheMeter() async {
        audio.processes = [music, zoom]
        let controller = await makeController(levelCheck: true, heardSound: true)

        await dictate(controller)

        XCTAssertEqual(presses, 0)
        XCTAssertTrue(meter.asked.isEmpty)
    }

    // MARK: - With the level check

    func testLingeringOutputIsNotStartedAgain() async {
        // The player was paused a moment ago: it still reports output, but its audio is silence.
        audio.processes = [music]
        meter.reading = .silent
        let controller = await makeController(levelCheck: true, heardSound: true)

        await dictate(controller)

        XCTAssertEqual(meter.asked.count, 1)
        XCTAssertEqual(presses, 0, "Neither the pause press nor a resume press may start music the user paused")
    }

    func testPausingMusicAndDictatingWithinOneSecondStartsNothing() async {
        audio.processes = [music]
        let controller = await makeController(levelCheck: true, heardSound: true)

        // The user pauses by hand: the output flag stays on, the samples turn to silence.
        meter.reading = .silent
        let started = Date()
        await dictate(controller, lasting: 0.4)

        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertEqual(presses, 0)
    }

    func testPlayingMusicIsPausedAndResumed() async {
        audio.processes = [music]
        meter.reading = .sound
        let controller = await makeController(levelCheck: true)

        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)
        XCTAssertEqual(presses, 1)

        audio.processes = []
        await controller.resumeMedia(sessionID: session)
        XCTAssertEqual(presses, 2)
    }

    func testSilenceIsBelievedWhileSoundWasHeardLately() async {
        audio.processes = [music]
        let controller = await makeController(levelCheck: true, heardSound: true)
        meter.reading = .silent
        now += 60

        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)

        XCTAssertEqual(presses, 0)
    }

    func testSoundsOffProofDoesNotExpire() async {
        // With the start sound off nothing can refresh the proof, so it stays until a tap error or a toggle.
        audio.processes = [music]
        let controller = await makeController(levelCheck: true, heardSound: true)
        meter.reading = .silent
        now += 24 * 3600

        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)

        XCTAssertEqual(presses, 0)
    }

    func testATapErrorClearsTheProof() async {
        audio.processes = [music]
        let controller = await makeController(levelCheck: true, heardSound: true)

        meter.reading = .unavailable
        var session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)
        XCTAssertEqual(presses, 1)
        audio.processes = []
        await controller.resumeMedia(sessionID: session)
        presses = 0

        // Silence right after the error is not believed.
        audio.processes = [music]
        meter.reading = .silent
        session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)
        XCTAssertEqual(presses, 1)
    }

    func testTurningTheCheckOffAndOnClearsTheProof() async {
        audio.processes = [music]
        let controller = await makeController(levelCheck: true, heardSound: true)
        controller.isLevelCheckEnabled = false
        controller.isLevelCheckEnabled = true
        meter.reading = .silent

        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)

        XCTAssertEqual(presses, 1)
    }

    func testAMeterThatNeverReturnsFallsBackToTheOutputFlag() async {
        audio.processes = [music]
        let controller = await makeController(levelCheck: true, meter: StuckMeter())

        let started = Date()
        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)

        XCTAssertEqual(presses, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)

        // The next recording is not stuck behind the first.
        audio.processes = []
        await controller.resumeMedia(sessionID: session)
        presses = 0
        audio.processes = [music]
        let second = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: second)
        XCTAssertEqual(presses, 1)
    }

    func testSilenceIsNotBelievedBeforeSoundWasHeard() async {
        // Without the System Audio Recording permission a tap can deliver silence for loud music. Until the check
        // has heard sound lately, the output flag decides, so the pause still works.
        audio.processes = [music]
        meter.reading = .silent
        let controller = await makeController(levelCheck: true, heardSound: false)

        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)

        XCTAssertEqual(presses, 1)
    }

    func testUnavailableReadingFallsBackToTheOutputFlag() async {
        audio.processes = [music]
        meter.reading = .unavailable
        let controller = await makeController(levelCheck: true, heardSound: true)

        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)

        XCTAssertEqual(presses, 1)
    }

    func testMeterIsAskedOnlyAboutThePlayersThatHaveOutput() async {
        audio.processes = [music, game]
        meter.reading = .sound
        let controller = await makeController(levelCheck: true, heardSound: true)

        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)

        XCTAssertEqual(meter.asked, [[music]])
    }

    // MARK: - Pnoe's own start sound as proof

    func testOwnSoundHeardAndPlayersSilentPressesNothing() async {
        // The main case: music paused a moment ago, no earlier proof at all. The start sound comes through the
        // tap, so the tap works now and the players' silence is real.
        audio.processes = [music]
        meter.reading = .silent
        meter.own = .sound
        let controller = await makeController(levelCheck: true, startSound: true)

        controller.beginLevelProbe()
        await dictate(controller)

        XCTAssertEqual(presses, 0)
        XCTAssertEqual(meter.askedForOwn, [true], "One listening session, started with the start sound")
    }

    func testOwnSoundSilentFallsBackToTheOutputFlag() async {
        // The start sound played but the tap did not deliver it (permission revoked): silence proves nothing.
        audio.processes = [music]
        meter.reading = .silent
        meter.own = .silent
        let controller = await makeController(levelCheck: true, heardSound: true, startSound: true)

        controller.beginLevelProbe()
        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)

        XCTAssertEqual(presses, 1)
    }

    func testOwnSoundSilentClearsTheEarlierProof() async {
        audio.processes = [music]
        let controller = await makeController(levelCheck: true, heardSound: true, startSound: true)
        meter.reading = .silent
        meter.own = .silent
        controller.beginLevelProbe()
        var session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)
        audio.processes = []
        await controller.resumeMedia(sessionID: session)
        presses = 0

        // A later recording with the start sound off cannot lean on the cleared proof.
        startSoundOn = false
        audio.processes = [music]
        controller.beginLevelProbe()
        session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)
        XCTAssertEqual(presses, 1)
    }

    func testOwnSoundUnavailableFallsBackToTheOutputFlag() async {
        audio.processes = [music]
        meter.reading = .silent
        meter.own = .unavailable
        let controller = await makeController(levelCheck: true, startSound: true)

        controller.beginLevelProbe()
        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)

        XCTAssertEqual(presses, 1)
    }

    func testPlayersMakingSoundArePausedWhateverTheOwnSoundReads() async {
        audio.processes = [music]
        meter.reading = .sound
        meter.own = .silent
        let controller = await makeController(levelCheck: true, startSound: true)

        controller.beginLevelProbe()
        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)

        XCTAssertEqual(presses, 1)
    }

    func testSoundsOffWithEarlierProofBelievesSilence() async {
        audio.processes = [music]
        let controller = await makeController(levelCheck: true, heardSound: true, startSound: false)
        meter.reading = .silent

        controller.beginLevelProbe()
        await dictate(controller)

        XCTAssertEqual(presses, 0)
        XCTAssertEqual(meter.askedForOwn, [false], "Without a start sound the tap listens to the players alone")
    }

    func testSoundsOffWithoutProofFallsBackToTheOutputFlag() async {
        audio.processes = [music]
        meter.reading = .silent
        let controller = await makeController(levelCheck: true, startSound: false)

        controller.beginLevelProbe()
        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)

        XCTAssertEqual(presses, 1)
    }

    func testAProbeFromBeforeTheMusicStartedDoesNotCountAsProof() async {
        // Nothing was playing when the start sound played, so no tap was made. Music that is playing by the time of
        // the pause is measured fresh, without the start sound, and silence without proof is not believed.
        audio.processes = []
        meter.reading = .silent
        meter.own = .sound
        let controller = await makeController(levelCheck: true, startSound: true)
        controller.beginLevelProbe()
        let session = controller.beginRecordingSession()
        try? await Task.sleep(for: .milliseconds(50))  // the probe has read the processes by now
        audio.processes = [music]
        await controller.pauseMedia(sessionID: session)

        XCTAssertEqual(presses, 1)
        XCTAssertEqual(meter.askedForOwn, [false])
    }

    func testAStaleProbeIsIgnored() async {
        audio.processes = [music]
        meter.reading = .silent
        meter.own = .sound
        let controller = await makeController(levelCheck: true, startSound: true)
        controller.beginLevelProbe()
        now += 10

        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)

        XCTAssertEqual(presses, 1, "The old sound proves nothing about now")
    }

    func testNoProbeIsStartedWhileTheCheckIsOff() async {
        audio.processes = [music]
        let controller = await makeController(levelCheck: false, startSound: true)

        controller.beginLevelProbe()
        await dictate(controller)

        XCTAssertTrue(meter.asked.isEmpty)
        XCTAssertEqual(presses, 2)
    }

    func testNoProbeTapDuringACall() async {
        audio.processes = [music, zoom]
        let controller = await makeController(levelCheck: true, startSound: true)

        controller.beginLevelProbe()
        await dictate(controller)

        XCTAssertTrue(meter.asked.isEmpty)
        XCTAssertEqual(presses, 0)
    }

    func testAMeterThatNeverReturnsDoesNotHoldBackTheProbe() async {
        audio.processes = [music]
        let controller = await makeController(levelCheck: true, startSound: true, meter: StuckMeter())

        controller.beginLevelProbe()
        let started = Date()
        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)

        XCTAssertEqual(presses, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    // MARK: - Listening plan

    func testListeningStopsAtOnceWhenAPlayerMakesSound() {
        XCTAssertTrue(ListeningPlan.isDone(elapsed: 0.01, window: 0.3, players: .sound, own: .unavailable))
    }

    func testListeningWaitsForTheMinimumWindow() {
        XCTAssertFalse(ListeningPlan.isDone(elapsed: 0.05, window: 0.15, players: .silent, own: nil))
        XCTAssertTrue(ListeningPlan.isDone(elapsed: 0.15, window: 0.15, players: .silent, own: nil))
    }

    func testListeningWaitsForOwnSoundUntilTheWindowEnds() {
        XCTAssertFalse(ListeningPlan.isDone(elapsed: 0.2, window: 0.3, players: .silent, own: .silent))
        XCTAssertTrue(ListeningPlan.isDone(elapsed: 0.2, window: 0.3, players: .silent, own: .sound))
        XCTAssertTrue(ListeningPlan.isDone(elapsed: 0.3, window: 0.3, players: .silent, own: .silent))
    }

    // MARK: - Settings

    func testTogglesAreSavedInTheGivenDefaults() {
        let controller = PlaybackController(defaults: defaults)
        controller.isLevelCheckEnabled = true
        controller.isPauseMediaEnabled = true

        XCTAssertTrue(defaults.bool(forKey: PlaybackController.levelCheckKey))
        XCTAssertTrue(defaults.bool(forKey: PlaybackController.pauseMediaKey))
        XCTAssertTrue(PlaybackController(defaults: defaults).isLevelCheckEnabled)
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
