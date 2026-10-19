import FormatterCore
import FormatterModels
import XCTest


final class WorkflowTemplateCatalogTests: XCTestCase {
    func testTheSixLocalTemplatesAreListedInPickerOrder() {
        XCTAssertEqual(
            LocalWorkflowTemplate.allCases.map(\.title),
            ["Cleaned Text", "Checklist", "Meeting Notes", "Summary", "Translation", "Email Reply"])
    }

    func testEveryTemplateHasAnIconAndOneSentenceAndNoLongerDetail() {
        for template in LocalWorkflowTemplate.allCases {
            XCTAssertFalse(template.symbol.isEmpty, template.title)
            XCTAssertTrue(template.summary.hasSuffix("."), template.title)
            XCTAssertEqual(template.summary.filter { $0 == "." }.count, 1, "\(template.title): one sentence")
            let option = template.pickerOption
            XCTAssertEqual(option.title, template.title)
            XCTAssertEqual(option.icon, template.symbol)
            XCTAssertFalse(option.isEmoji)
            XCTAssertNil(option.detail)
        }
    }

    func testIdsFollowTheOlderTemplatesAndNeverCollide() {
        XCTAssertEqual(
            LocalWorkflowTemplate.allCases.map { $0.templateId.uuidString },
            (6...11).map { String(format: "10000000-0000-0000-0000-0000000000%02X", $0) })
        XCTAssertEqual(
            LocalWorkflowTemplate.allCases.map { $0.promptId.uuidString },
            (6...11).map { String(format: "00000000-0000-0000-0000-0000000000%02X", $0) })
    }

    func testOnlyCleanedTextIsHeldToTheSpeakersWords() {
        XCTAssertEqual(LocalWorkflowTemplate.allCases.filter { !$0.rewritesText }, [.cleanedText])
        XCTAssertEqual(LocalWorkflowTemplate.rewritingPromptIds.count, 5)
        XCTAssertFalse(LocalWorkflowTemplate.rewritingPromptIds.contains(LocalWorkflowTemplate.cleanedText.promptId))
    }

    func testOnlyTranslationAsksForALanguageAndOnlyEmailReplyReadsTheEmail() {
        XCTAssertEqual(LocalWorkflowTemplate.allCases.filter(\.asksForTargetLanguage), [.translation])
        XCTAssertEqual(LocalWorkflowTemplate.allCases.filter(\.readsEmailContext), [.emailReply])
    }

    func testTranslationLanguagesAreListedOnce() {
        XCTAssertTrue(TranslationLanguages.names.contains(TranslationLanguages.defaultName))
        XCTAssertEqual(Set(TranslationLanguages.names).count, TranslationLanguages.names.count)
    }
}

final class WorkflowProviderPreselectionTests: XCTestCase {
    private func ollama(_ name: String, gigabytes: Double) -> FormatterModelEntry {
        FormatterModelEntry(
            id: "ollama:\(name)", displayName: name, kind: .ollama, sizeBytes: Int64(gigabytes * 1_000_000_000),
            source: .ollama, spec: RuntimeModelSpec(identifier: name))
    }

    func testRunningOllamaWithASuitableModelIsPreselected() async {
        let choice = await TemplateProviderPreselection.choose {
            [self.ollama("gemma3:12b", gigabytes: 8), self.ollama("qwen3:4b", gigabytes: 2.5)]
        }
        XCTAssertEqual(choice, PreselectedProvider(providerName: "Ollama", modelName: "qwen3:4b"))
    }

    func testNoInstalledModelLeavesTheProviderToTheUser() async {
        let none = await TemplateProviderPreselection.choose { [] }
        XCTAssertNil(none)
        let wrongFamily = await TemplateProviderPreselection.choose { [self.ollama("llama3.2:3b", gigabytes: 2)] }
        XCTAssertNil(wrongFamily)
    }

    func testAProviderTheUserChangedWhileTheLookupRanIsKept() {
        XCTAssertTrue(TemplateProviderPreselection.shouldApply(currentProvider: nil, startingProvider: nil))
        XCTAssertTrue(TemplateProviderPreselection.shouldApply(currentProvider: "Groq", startingProvider: "Groq"))
        XCTAssertFalse(TemplateProviderPreselection.shouldApply(currentProvider: "Anthropic", startingProvider: nil))
    }
}

final class CleanedTextGuardTests: XCTestCase {
    private let spec = RuntimeModelSpec(identifier: "test-model")
    private let take = "um please open src/app/main.swift and fix the login bug before the demo"

    private func clean(modelSays output: String, stop: StopReason = .eos) async -> GuardedCleanup.Result {
        let cleanup = GuardedCleanup(runtime: FakeRuntime(returning: output, stopReason: stop), spec: spec)
        return await cleanup.clean(take)
    }

    func testAGoodResultIsUsedAndTheProtectedPathComesBack() async {
        let result = await clean(modelSays: "Please open ⟦1⟧ and fix the login bug before the demo.")
        XCTAssertEqual(result.text, "Please open src/app/main.swift and fix the login bug before the demo.")
        XCTAssertNil(result.fallbackReason)
        XCTAssertTrue(result.systemPrompt.contains("dictation formatter"))
    }

    func testAResultThatDropsTheProtectedPathPastesTheRawText() async {
        let result = await clean(modelSays: "Please fix the login bug before the demo.")
        XCTAssertEqual(result.fallbackReason, FallbackReason.placeholderLost.rawValue)
        XCTAssertTrue(result.text.contains("src/app/main.swift"))
        XCTAssertFalse(result.text.contains("Please fix"))
        XCTAssertFalse(result.text.lowercased().contains("um "))
    }

    func testAResultThatRewritesTheSpeakersWordsPastesTheRawText() async {
        let result = await clean(modelSays: "⟦1⟧ needs a repair, so someone should deal with the sign-in problem.")
        XCTAssertNotNil(result.fallbackReason)
        XCTAssertTrue(result.text.contains("fix the login bug before the demo"))
    }

    func testACutOffResultPastesTheRawText() async {
        let result = await clean(modelSays: "Please open ⟦1⟧ and", stop: .cap)
        XCTAssertEqual(result.fallbackReason, FallbackReason.truncated.rawValue)
        XCTAssertTrue(result.text.contains("fix the login bug"))
    }

    func testARuntimeFailurePastesTheRawText() async {
        let cleanup = GuardedCleanup(runtime: FakeRuntime(throwing: .crashed), spec: spec)
        let result = await cleanup.clean(take)
        XCTAssertEqual(result.fallbackReason, FallbackReason.runtimeCrashed.rawValue)
        XCTAssertTrue(result.text.contains("src/app/main.swift"))
    }

    func testATakeWithSnippetPlaceholdersSkipsTheModel() {
        XCTAssertFalse(GuardedCleanup.canClean("send my ⟦snippet-0⟧ to Sam"))
        XCTAssertTrue(GuardedCleanup.canClean(take))
    }

    func testTheChatCompletionAdapterSendsTheSystemTurnFirstAndTheTranscriptLast() async throws {
        let seen = Box()
        let runtime = ChatCompletionRuntime { system, turns, _ in
            await seen.set(system: system, turns: turns)
            return "Please open ⟦1⟧ and fix the login bug before the demo."
        }
        let result = await GuardedCleanup(runtime: runtime, spec: spec).clean(take)
        XCTAssertEqual(result.text, "Please open src/app/main.swift and fix the login bug before the demo.")
        let (system, turns) = await seen.value
        XCTAssertTrue(system.contains("dictation formatter"))
        XCTAssertEqual(turns.last?.role, "user")
        XCTAssertTrue(turns.last?.content.contains("⟦1⟧") == true)
        XCTAssertEqual(turns.first?.role, "user", "the worked examples follow the system turn")
    }

    private actor Box {
        private(set) var value: (String, [(role: String, content: String)]) = ("", [])
        func set(system: String, turns: [(role: String, content: String)]) { value = (system, turns) }
    }
}

final class RewriteOutputSanitizerTests: XCTestCase {
    func testPreamblesAndFencesAreStripped() {
        XCTAssertEqual(
            RewriteOutputSanitizer.sanitize("Here is the checklist:\n- [ ] Call Sam\n- [ ] Send the file", input: "call sam and send the file"),
            "- [ ] Call Sam\n- [ ] Send the file")
        XCTAssertEqual(
            RewriteOutputSanitizer.sanitize("```\nBonjour à tous.\n```", input: "hello everyone"),
            "Bonjour à tous.")
    }

    func testAnUnchangedRewriteIsNotHeldToTheSpeakersWords() {
        let summary = "The team agreed to ship on Friday."
        XCTAssertEqual(RewriteOutputSanitizer.sanitize(summary, input: "so um we talked for a long time and basically everyone said let us ship friday"), summary)
    }
}
