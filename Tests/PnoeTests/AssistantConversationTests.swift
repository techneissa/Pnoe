import XCTest

@MainActor
final class AssistantConversationTests: XCTestCase {
    private struct Rig {
        let conversation: AssistantConversation
        let ollama: FakeOllamaSpeech
        let output: FakePCMOutput
        let apple: FakeAppleSpeech
    }

    private func makeRig() throws -> Rig {
        let suite = "PnoeAssistantConversation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ReplySpeechSettings.enabledKey)
        let ollama = FakeOllamaSpeech(models: [])
        let output = FakePCMOutput()
        let apple = FakeAppleSpeech()
        let speaker = ReplySpeaker(defaults: defaults, ollama: { ollama }, makeOutput: { output }, apple: apple)
        return Rig(conversation: AssistantConversation(speaker: speaker), ollama: ollama, output: output, apple: apple)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(60))
    }

    func testAnswerSpeaksWhenItArrives() async throws {
        let rig = try makeRig()
        rig.conversation.beginConversation(transcript: "Hi")
        rig.conversation.finishInitialResponse("**Hello** there.", systemPrompt: nil)
        XCTAssertEqual(rig.conversation.phase, .ready)
        try await settle()
        XCTAssertEqual(rig.apple.spoken.map(\.text), ["Hello there."])
    }

    func testLateAnswerAfterThePanelClosedIsNotSpokenAndStaysClosed() async throws {
        let rig = try makeRig()
        rig.conversation.beginConversation(transcript: "Hi")
        rig.conversation.reset()  // the panel closes while the answer is being made

        rig.conversation.finishInitialResponse("Too late.", systemPrompt: "prompt")

        XCTAssertEqual(rig.conversation.phase, .inactive)
        XCTAssertTrue(rig.conversation.messages.isEmpty)
        XCTAssertFalse(rig.conversation.speaker.isSpeaking)
        try await settle()
        XCTAssertTrue(rig.apple.spoken.isEmpty)
    }

    func testLateFollowUpAnswerAfterThePanelClosedIsNotSpoken() async throws {
        let rig = try makeRig()
        rig.conversation.beginConversation(transcript: "Hi")
        rig.conversation.finishInitialResponse("First.", systemPrompt: nil)
        try await settle()
        rig.conversation.beginFollowUp("More?")
        rig.conversation.reset()

        rig.conversation.finishFollowUp("Too late.")

        XCTAssertEqual(rig.conversation.phase, .inactive)
        XCTAssertTrue(rig.conversation.messages.isEmpty)
        try await settle()
        XCTAssertEqual(rig.apple.spoken.map(\.text), ["First."])
    }

    func testLateFailureAfterThePanelClosedDoesNotReopenIt() throws {
        let rig = try makeRig()
        rig.conversation.beginConversation(transcript: "Hi")
        rig.conversation.reset()
        rig.conversation.fail("timed out")
        XCTAssertEqual(rig.conversation.phase, .inactive)
    }

    func testFailureWhileWaitingStillShows() throws {
        let rig = try makeRig()
        rig.conversation.beginConversation(transcript: "Hi")
        rig.conversation.fail("timed out")
        XCTAssertEqual(rig.conversation.phase, .failed("timed out"))
    }

    func testClosingThePanelStopsSpeech() throws {
        let rig = try makeRig()
        rig.conversation.beginConversation(transcript: "Hi")
        rig.conversation.finishInitialResponse("A long answer.", systemPrompt: nil)
        XCTAssertTrue(rig.conversation.speaker.isSpeaking)
        rig.conversation.reset()
        XCTAssertFalse(rig.conversation.speaker.isSpeaking)
    }
}
