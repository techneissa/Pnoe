import XCTest

/// An Ollama daemon that answers from memory. `hangsAfterFirstChunk` keeps the audio stream open, the way a long reply
/// is still being made.
final class FakeOllamaSpeech: OllamaSpeechProviding, @unchecked Sendable {
    struct Request: Equatable {
        let model: String
        let input: String
        let voice: String
    }

    private let lock = NSLock()
    private var _models: [OllamaSpeechModel]
    private var _requests: [Request] = []
    private var _terminatedStreams = 0
    var audioError: Error?
    var hangsAfterFirstChunk = false
    /// Two samples, so every chunk is a whole number of samples.
    var chunk = Data([0x00, 0x40, 0x00, 0xC0])

    init(models: [OllamaSpeechModel]) {
        _models = models
    }

    var requests: [Request] { lock.withLock { _requests } }
    var terminatedStreams: Int { lock.withLock { _terminatedStreams } }

    func speechModels() async -> [OllamaSpeechModel] { lock.withLock { _models } }

    func audio(model: String, input: String, voice: String) -> AsyncThrowingStream<Data, Error> {
        lock.withLock { _requests.append(Request(model: model, input: input, voice: voice)) }
        return AsyncThrowingStream { continuation in
            if let audioError {
                continuation.finish(throwing: audioError)
                return
            }
            continuation.yield(chunk)
            if !hangsAfterFirstChunk { continuation.finish() }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self._terminatedStreams += 1 }
            }
        }
    }
}

@MainActor
final class FakePCMOutput: PCMStreamOutput {
    private(set) var samples: [Float] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() throws { startCount += 1 }
    func enqueue(_ samples: [Float]) { self.samples += samples }
    func waitUntilDrained() async {}
    func stop() { stopCount += 1 }
}

@MainActor
final class FakeAppleSpeech: AppleSpeechOutput {
    struct Spoken: Equatable {
        let text: String
        let voice: String?
    }
    private(set) var spoken: [Spoken] = []
    private(set) var stopCount = 0

    func speak(_ text: String, voiceIdentifier: String?) async {
        spoken.append(Spoken(text: text, voice: voiceIdentifier))
    }

    func stop() { stopCount += 1 }
}

@MainActor
final class ReplySpeakerTests: XCTestCase {
    private let phonon = OllamaSpeechModel(name: "phonon", voices: ["default", "emma"])

    private struct Rig {
        let speaker: ReplySpeaker
        let ollama: FakeOllamaSpeech
        let output: FakePCMOutput
        let apple: FakeAppleSpeech
        let defaults: UserDefaults
    }

    private func makeRig(models: [OllamaSpeechModel], enabled: Bool = true) throws -> Rig {
        let suite = "PnoeReplySpeaker-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.register(defaults: ReplySpeechSettings.registeredDefaults)
        defaults.set(enabled, forKey: ReplySpeechSettings.enabledKey)
        let ollama = FakeOllamaSpeech(models: models)
        let output = FakePCMOutput()
        let apple = FakeAppleSpeech()
        let speaker = ReplySpeaker(defaults: defaults, ollama: { ollama }, makeOutput: { output }, apple: apple)
        return Rig(speaker: speaker, ollama: ollama, output: output, apple: apple, defaults: defaults)
    }

    private func waitUntil(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    // MARK: Ollama or Apple

    func testChoosesOllamaWhenAModelCanSpeakAndAppleOtherwise() {
        XCTAssertEqual(ReplySpeechEngine.choose(from: []), .apple)
        XCTAssertEqual(ReplySpeechEngine.choose(from: [phonon]), .ollama(phonon))
        let other = OllamaSpeechModel(name: "phonon-de", voices: ["default"])
        XCTAssertEqual(ReplySpeechEngine.choose(from: OllamaSpeechService.ordered([other, phonon])), .ollama(phonon))
    }

    func testSettingsSourcesFollowTheInstalledModels() async {
        let sources = ReplySpeechSources()
        await sources.refresh(ollama: FakeOllamaSpeech(models: [phonon]), appleVoices: { [] })
        XCTAssertEqual(sources.engine, .ollama(phonon))
        await sources.refresh(ollama: FakeOllamaSpeech(models: []), appleVoices: { [] })
        XCTAssertEqual(sources.engine, .apple)
    }

    func testSpeaksThroughOllamaWhenAModelIsInstalled() async throws {
        let rig = try makeRig(models: [phonon])
        rig.speaker.speakIfEnabled("Hello **there**.")
        XCTAssertTrue(rig.speaker.isSpeaking)
        await waitUntil("finished") { !rig.speaker.isSpeaking }

        XCTAssertEqual(rig.ollama.requests, [.init(model: "phonon", input: "Hello there.", voice: "default")])
        XCTAssertEqual(rig.output.samples, [0.5, -0.5])
        XCTAssertEqual(rig.output.startCount, 1)
        XCTAssertTrue(rig.apple.spoken.isEmpty)
    }

    func testUsesTheSavedOllamaVoiceAndReplacesAStaleOne() async throws {
        let rig = try makeRig(models: [phonon])
        rig.defaults.set("emma", forKey: ReplySpeechSettings.ollamaVoiceKey)
        rig.speaker.speakIfEnabled("One.")
        await waitUntil("finished") { !rig.speaker.isSpeaking }
        rig.defaults.set("removed", forKey: ReplySpeechSettings.ollamaVoiceKey)
        rig.speaker.speakIfEnabled("Two.")
        await waitUntil("finished again") { !rig.speaker.isSpeaking }
        XCTAssertEqual(rig.ollama.requests.map(\.voice), ["emma", "default"])
    }

    func testLongReplyGoesOutAsSeveralRequestsInOrder() async throws {
        let rig = try makeRig(models: [phonon])
        let sentence = "This sentence is exactly sixty characters long, no more, no less. "
        rig.speaker.speakIfEnabled(String(repeating: sentence, count: 200))
        await waitUntil("finished") { !rig.speaker.isSpeaking }
        XCTAssertGreaterThan(rig.ollama.requests.count, 2)
        for request in rig.ollama.requests {
            XCTAssertLessThanOrEqual(request.input.unicodeScalars.count, SpeechText.ollamaInputLimit)
        }
        // One output for the whole reply: playback continues from piece to piece.
        XCTAssertEqual(rig.output.startCount, 1)
        XCTAssertEqual(rig.output.samples.count, 2 * rig.ollama.requests.count)
    }

    func testSpeaksWithAppleVoicesWithoutASpeechModel() async throws {
        let rig = try makeRig(models: [])
        rig.speaker.speakIfEnabled("# Hi\n\nHello.")
        await waitUntil("finished") { !rig.speaker.isSpeaking }
        XCTAssertEqual(rig.apple.spoken, [.init(text: "Hi.\n\nHello.", voice: nil)])
        XCTAssertTrue(rig.ollama.requests.isEmpty)
        XCTAssertEqual(rig.output.startCount, 0)
    }

    func testAppleVoiceUsesTheSavedIdentifier() async throws {
        let rig = try makeRig(models: [])
        rig.defaults.set("com.apple.voice.compact.en-US.Samantha", forKey: ReplySpeechSettings.appleVoiceKey)
        rig.speaker.speakIfEnabled("Hello.")
        await waitUntil("finished") { !rig.speaker.isSpeaking }
        XCTAssertEqual(rig.apple.spoken.first?.voice, "com.apple.voice.compact.en-US.Samantha")
    }

    func testOllamaFailingBeforeAnyAudioFallsBackToAppleVoices() async throws {
        let rig = try makeRig(models: [phonon])
        rig.ollama.audioError = OllamaSpeechError.http(status: 400, message: "unknown voice")
        rig.speaker.speakIfEnabled("Hello.")
        await waitUntil("finished") { !rig.speaker.isSpeaking }
        XCTAssertEqual(rig.apple.spoken.map(\.text), ["Hello."])
        XCTAssertGreaterThanOrEqual(rig.output.stopCount, 1)
    }

    // MARK: Off, empty, recording

    func testSettingOffSpeaksNothing() async throws {
        let rig = try makeRig(models: [phonon], enabled: false)
        rig.speaker.speakIfEnabled("Hello.")
        XCTAssertFalse(rig.speaker.isSpeaking)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(rig.ollama.requests.isEmpty)
        XCTAssertTrue(rig.apple.spoken.isEmpty)
    }

    func testReplyWithNothingToSayStaysSilent() async throws {
        let rig = try makeRig(models: [])
        rig.speaker.speakIfEnabled("```\ncode only\n```")
        XCTAssertFalse(rig.speaker.isSpeaking)
        XCTAssertTrue(rig.apple.spoken.isEmpty)
    }

    func testDoesNotStartWhileARecordingIsStartingOrRunning() async throws {
        let rig = try makeRig(models: [phonon])
        rig.speaker.canStart = { false }
        rig.speaker.speakIfEnabled("Hello.")
        XCTAssertFalse(rig.speaker.isSpeaking)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(rig.ollama.requests.isEmpty)
    }

    func testRecordingStartStopsSpeechAtOnce() async throws {
        let rig = try makeRig(models: [phonon])
        rig.ollama.hangsAfterFirstChunk = true
        rig.speaker.speakIfEnabled("A long answer. It goes on. And on.")
        await waitUntil("first audio plays") { !rig.output.samples.isEmpty }
        XCTAssertTrue(rig.speaker.isSpeaking)

        rig.speaker.stop(.recordingStarted)

        XCTAssertFalse(rig.speaker.isSpeaking)
        XCTAssertEqual(rig.output.stopCount, 1)
        await waitUntil("the audio request is cancelled") { rig.ollama.terminatedStreams >= 1 }
        let heard = rig.output.samples.count
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(rig.output.samples.count, heard, "no audio after the stop")
        XCTAssertTrue(rig.apple.spoken.isEmpty, "a stop must not hand over to the Apple voices")
        XCTAssertFalse(rig.speaker.isSpeaking)
    }

    func testStopCancelsAppleSpeechToo() async throws {
        let rig = try makeRig(models: [])
        rig.speaker.speakIfEnabled("Hello.")
        rig.speaker.stop(.panelClosed)
        XCTAssertFalse(rig.speaker.isSpeaking)
        XCTAssertGreaterThanOrEqual(rig.apple.stopCount, 1)
    }

    func testANewReplyReplacesTheOneBeingRead() async throws {
        let rig = try makeRig(models: [phonon])
        rig.ollama.hangsAfterFirstChunk = true
        rig.speaker.speakIfEnabled("First answer.")
        await waitUntil("first audio") { !rig.output.samples.isEmpty }
        rig.ollama.hangsAfterFirstChunk = false
        rig.speaker.speakIfEnabled("Second answer.")
        await waitUntil("finished") { !rig.speaker.isSpeaking }
        XCTAssertEqual(rig.ollama.requests.map(\.input), ["First answer.", "Second answer."])
        XCTAssertGreaterThanOrEqual(rig.output.stopCount, 1)
    }
}
