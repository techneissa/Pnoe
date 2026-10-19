import AppKit
import SwiftUI
import XCTest

final class SnippetMatcherTests: XCTestCase {
    private let email = SnippetRule(trigger: "my email", expansion: "name@example.com")
    private let signature = SnippetRule(
        trigger: "sig block", expansion: "Best regards,\nSam Example\nExample Co.\n\n  (indented line)")

    private func expanded(_ text: String, _ rules: [SnippetRule]) -> String {
        SnippetMatcher.match(in: text, rules: rules).expandedText
    }

    // MARK: Matching

    func testMatchesIgnoringCase() {
        XCTAssertEqual(expanded("MY EMAIL", [email]), "name@example.com")
        XCTAssertEqual(expanded("My Email", [email]), "name@example.com")
        XCTAssertEqual(expanded("my email", [SnippetRule(trigger: "My Email", expansion: "x")]), "x")
    }

    func testTriggerAloneDropsPunctuationTheTranscriberAdded() {
        for spoken in ["My email.", "my email", "  My email!  ", "\"My email,\"", "My email?"] {
            let result = SnippetMatcher.match(in: spoken, rules: [email])
            XCTAssertEqual(result.expandedText, "name@example.com", spoken)
            XCTAssertTrue(result.isSnippetOnly, spoken)
        }
    }

    func testTriggerInsideASentenceKeepsTheSentencePunctuation() {
        XCTAssertEqual(
            expanded("Please send it to my email.", [email]), "Please send it to name@example.com.")
        XCTAssertEqual(
            expanded("My email, please, and thanks.", [email]), "name@example.com, please, and thanks.")
        let result = SnippetMatcher.match(in: "Send it to my email.", rules: [email])
        XCTAssertFalse(result.isSnippetOnly)
    }

    func testTolerantOfPunctuationBetweenWordsAndCurlyApostrophes() {
        XCTAssertEqual(expanded("Sig, block.", [signature]).hasPrefix("Best regards,"), true)
        let apostrophe = SnippetRule(trigger: "what's up", expansion: "hello")
        XCTAssertEqual(expanded("What’s up", [apostrophe]), "hello")
        XCTAssertEqual(expanded("what's up", [apostrophe]), "hello")
    }

    func testTriggerPunctuationIsIgnoredWhenSaving() {
        XCTAssertEqual(SnippetTrigger.normalized("  My   email. "), "My email")
        XCTAssertEqual(SnippetTrigger.key("MY  Email!"), "my email")
        XCTAssertEqual(expanded("my email", [SnippetRule(trigger: "My email.", expansion: "x")]), "x")
    }

    func testTriggersKeepTheirOwnSymbols() {
        for (trigger, spoken, near) in [
            ("c++", "I like C++ a lot", "I like c a lot"),
            ("C#", "I write C# daily", "I write C daily"),
            ("50%", "give me 50% off", "give me 50 off"),
            ("a.b", "see a.b now", "see a b now"),
            ("f(x)", "call f(x) now", "call f x now"),
            ("(x)", "the (x) case", "the x case"),
        ] {
            XCTAssertEqual(SnippetTrigger.normalized(trigger), trigger, trigger)
            let rule = SnippetRule(trigger: trigger, expansion: "EXP")
            XCTAssertTrue(SnippetMatcher.match(in: spoken, rules: [rule]).hasMatches, trigger)
            XCTAssertFalse(SnippetMatcher.match(in: near, rules: [rule]).hasMatches, trigger)
        }
        // "C#" must not fire on a bare "C", and "50%" not on a bare "50".
        XCTAssertEqual(expanded("grade C is fine", [SnippetRule(trigger: "C#", expansion: "EXP")]), "grade C is fine")
        XCTAssertEqual(expanded("I scored 50.", [SnippetRule(trigger: "50%", expansion: "EXP")]), "I scored 50.")
        XCTAssertEqual(expanded("f(x) is odd", [SnippetRule(trigger: "(x)", expansion: "EXP")]), "f(x) is odd")
        // Sentence punctuation after a symbol trigger is still tolerated.
        XCTAssertEqual(expanded("I write C#.", [SnippetRule(trigger: "C#", expansion: "EXP")]), "I write EXP.")
        // Quotes and sentence punctuation are trimmed from a typed trigger; symbols are not.
        XCTAssertEqual(SnippetTrigger.normalized("“c++”."), "c++")
        XCTAssertEqual(SnippetTrigger.key("C#"), "c#")
        XCTAssertNotEqual(SnippetTrigger.key("C#"), SnippetTrigger.key("C"))
    }

    func testSymbolTriggersDoNotCountAsDuplicatesOfTheirLetters() {
        XCTAssertNil(SnippetValidation.validate(trigger: "C#", expansion: "x", existingTriggers: ["C"]))
        XCTAssertEqual(
            SnippetValidation.validate(trigger: "c#", expansion: "x", existingTriggers: ["C#"]), .duplicateTrigger)
    }

    func testOnlyWholeWordsMatch() {
        XCTAssertEqual(expanded("my emailer is broken", [email]), "my emailer is broken")
        XCTAssertEqual(expanded("symy email", [email]), "symy email")
        XCTAssertEqual(expanded("my email2", [email]), "my email2")
        XCTAssertEqual(expanded("my-email", [email]), "my-email")
    }

    func testLongestTriggerWinsOnOverlap() {
        let short = SnippetRule(trigger: "my email", expansion: "SHORT")
        let long = SnippetRule(trigger: "my email address", expansion: "LONG")
        XCTAssertEqual(expanded("my email address", [short, long]), "LONG")
        XCTAssertEqual(expanded("my email address", [long, short]), "LONG")
        XCTAssertEqual(expanded("my email only", [short, long]), "SHORT only")
        // A longer trigger that starts later still beats the shorter one it overlaps.
        let tail = SnippetRule(trigger: "email address book", expansion: "TAIL")
        XCTAssertEqual(expanded("my email address book", [short, tail]), "my TAIL")
    }

    func testSeveralTriggersInOneTranscript() {
        XCTAssertEqual(
            expanded("write to my email and add the sig block.", [email, signature]),
            "write to name@example.com and add the \(signature.expansion).")
    }

    func testMultiLineExpansionIsInsertedVerbatim() {
        let result = SnippetMatcher.match(in: "Sig block.", rules: [signature])
        XCTAssertEqual(result.expandedText, signature.expansion)
        XCTAssertTrue(result.expandedText.contains("\n\n  (indented line)"))
    }

    func testExpansionIsNotScannedForTriggersOrPlaceholders() {
        let tricky = SnippetRule(trigger: "tricky", expansion: "my email ⟦snippet-0⟧ $1 \\1 (x)")
        let result = SnippetMatcher.match(in: "tricky then my email", rules: [tricky, email])
        XCTAssertEqual(result.expandedText, "my email ⟦snippet-0⟧ $1 \\1 (x) then name@example.com")
    }

    func testNoMatchLeavesTextUntouched() {
        let result = SnippetMatcher.match(in: "Hello there, how are you?", rules: [email, signature])
        XCTAssertFalse(result.hasMatches)
        XCTAssertEqual(result.protectedText, "Hello there, how are you?")
        XCTAssertFalse(result.isSnippetOnly)
        XCTAssertEqual(SnippetMatcher.match(in: "", rules: [email]).protectedText, "")
        XCTAssertEqual(SnippetMatcher.match(in: "my email", rules: []).protectedText, "my email")
    }

    func testUnusableRulesAreIgnored() {
        let rules = [
            SnippetRule(trigger: "", expansion: "x"), SnippetRule(trigger: "...", expansion: "x"),
            SnippetRule(trigger: "empty", expansion: ""),
        ]
        XCTAssertEqual(expanded("... empty", rules), "... empty")
    }

    func testTwoTriggersAloneAreJoinedBySpace() {
        let result = SnippetMatcher.match(in: "My email. Sig block.", rules: [email, signature])
        XCTAssertTrue(result.isSnippetOnly)
        XCTAssertEqual(result.expandedText, "name@example.com \(signature.expansion)")
    }

    func testNonSpacedScriptTriggerMatchesInsideText() {
        let rule = SnippetRule(trigger: "我的邮箱", expansion: "name@example.com")
        XCTAssertEqual(expanded("请发到我的邮箱。", [rule]), "请发到name@example.com。")
    }

    // MARK: Pipeline order

    func testReplacementsRunBeforeMatchingAndNeverTouchTheExpansion() {
        let rule = SnippetRule(trigger: "my email", expansion: "write to Mail at mail.example.com")
        let prepared = SnippetProcessor.prepare("e-mail me at my email", rules: [rule]) {
            $0.replacingOccurrences(of: "e-mail", with: "Mail").replacingOccurrences(of: "mail", with: "MAIL")
        }
        // The replacement saw the spoken text only; the expansion keeps its lower-case "mail".
        XCTAssertEqual(prepared.expandedText, "Mail me at write to Mail at mail.example.com")
    }

    func testReplacementCanProduceATrigger() {
        let prepared = SnippetProcessor.prepare("my e-mail", rules: [email]) {
            $0.replacingOccurrences(of: "e-mail", with: "email")
        }
        XCTAssertEqual(prepared.expandedText, "name@example.com")
    }

    func testEnhancementSeesPlaceholdersNotExpansions() {
        let prepared = SnippetProcessor.prepare("tell them my email please", rules: [email]) { $0 }
        XCTAssertFalse(prepared.textForEnhancement.contains("name@example.com"))
        XCTAssertTrue(prepared.textForEnhancement.contains("⟦snippet-0⟧"))
        XCTAssertFalse(prepared.skipsEnhancement)
    }

    func testModelRewriteCannotChangeTheExpansion() {
        let prepared = SnippetProcessor.prepare("tell them my email please", rules: [email]) { $0 }
        // A model that upper-cases and rephrases everything but keeps the placeholder.
        let enhanced = prepared.textForEnhancement.uppercased().replacingOccurrences(of: "⟦SNIPPET-0⟧", with: "⟦snippet-0⟧")
        XCTAssertEqual(prepared.finish(enhanced: enhanced), "TELL THEM name@example.com PLEASE")
    }

    func testModelThatDropsOrDuplicatesAPlaceholderFallsBackToTheUnenhancedText() {
        let prepared = SnippetProcessor.prepare("tell them my email please", rules: [email]) { $0 }
        XCTAssertEqual(prepared.finish(enhanced: "Tell them please."), "tell them name@example.com please")
        XCTAssertEqual(
            prepared.finish(enhanced: "⟦snippet-0⟧ and ⟦snippet-0⟧"), "tell them name@example.com please")
    }

    func testSnippetOnlyTranscriptSkipsEnhancement() {
        let prepared = SnippetProcessor.prepare("My email.", rules: [email]) { $0 }
        XCTAssertTrue(prepared.skipsEnhancement)
        XCTAssertEqual(prepared.expandedText, "name@example.com")
    }

    func testFinishWithoutMatchesReturnsEnhancedTextAsIs() {
        let prepared = SnippetProcessor.prepare("hello", rules: [email]) { $0 }
        XCTAssertEqual(prepared.finish(enhanced: "Hello."), "Hello.")
    }

    // MARK: Validation

    func testValidation() {
        XCTAssertEqual(SnippetValidation.validate(trigger: " ", expansion: "x", existingTriggers: []), .emptyTrigger)
        XCTAssertEqual(SnippetValidation.validate(trigger: "...", expansion: "x", existingTriggers: []), .emptyTrigger)
        XCTAssertEqual(SnippetValidation.validate(trigger: "+ +", expansion: "x", existingTriggers: []), .unusableTrigger)
        XCTAssertEqual(SnippetValidation.validate(trigger: "a", expansion: " \n", existingTriggers: []), .emptyExpansion)
        XCTAssertEqual(
            SnippetValidation.validate(trigger: "My  Email.", expansion: "x", existingTriggers: ["my email"]),
            .duplicateTrigger)
        XCTAssertNil(SnippetValidation.validate(trigger: "my phone", expansion: "x", existingTriggers: ["my email"]))
    }
}

final class SnippetBackupTests: XCTestCase {
    /// Mirrors how `BackupFile` reads and writes: its own keys plus the snippet payload on the same object.
    private struct SampleBackup: Codable, Equatable {
        var version: String
        var payload: SnippetBackupPayload

        private enum CodingKeys: String, CodingKey { case version }

        init(version: String, payload: SnippetBackupPayload) {
            self.version = version
            self.payload = payload
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
            payload = try SnippetBackupPayload(from: decoder)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try payload.encode(to: encoder)
        }
    }

    private let snippets = [
        SnippetBackup(trigger: "my email", expansion: "name@example.com"),
        SnippetBackup(trigger: "sig block", expansion: "Best regards,\nSam Example\n\nExample Co."),
    ]

    func testRoundTripKeepsSnippetsAndFormatVersion() throws {
        let original = SampleBackup(version: "1.2.3", payload: .forExport(snippets: snippets))
        let data = try JSONEncoder().encode(original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? String, "1.2.3")
        XCTAssertEqual(object["formatVersion"] as? Int, SnippetBackupPayload.currentFormatVersion)
        XCTAssertEqual((object["snippets"] as? [[String: Any]])?.count, 2)

        let decoded = try JSONDecoder().decode(SampleBackup.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.payload.snippets, snippets)
    }

    func testFormatVersionIsBumpedPastTheOldFormat() {
        XCTAssertGreaterThan(SnippetBackupPayload.currentFormatVersion, 1)
    }

    func testBackupWithoutSnippetsStillImports() throws {
        let old = #"{"version":"1.0.0","wordReplacements":{"voice ink":"Pnoe"}}"#
        let decoded = try JSONDecoder().decode(SampleBackup.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.version, "1.0.0")
        XCTAssertNil(decoded.payload.formatVersion)
        XCTAssertNil(decoded.payload.snippets)
        XCTAssertEqual(SnippetBackupPayload.snippetsToImport(decoded.payload.snippets, existingTriggers: []), [])
    }

    func testExportWithoutSnippetsOmitsTheList() throws {
        let data = try JSONEncoder().encode(SampleBackup(version: "1", payload: .forExport(snippets: [])))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["snippets"])
        XCTAssertNotNil(object["formatVersion"])
    }

    func testImportSkipsDuplicatesAndUnusableRows() {
        let imported = snippets + [
            SnippetBackup(trigger: "MY EMAIL.", expansion: "other@example.com"),
            SnippetBackup(trigger: "empty", expansion: "  "),
            SnippetBackup(trigger: "--", expansion: "x"),
            SnippetBackup(trigger: "my phone", expansion: "555-0100"),
        ]
        let toAdd = SnippetBackupPayload.snippetsToImport(imported, existingTriggers: ["Sig block"])
        XCTAssertEqual(
            toAdd,
            [
                SnippetBackup(trigger: "my email", expansion: "name@example.com"),
                SnippetBackup(trigger: "my phone", expansion: "555-0100"),
            ])
    }
}

/// Renders the Snippets list offscreen in a hosting view that has no window. Nothing is shown on screen. The folder comes
/// from `PNOE_SNIPPETS_PNG_DIR` (pass it to xcodebuild as `TEST_RUNNER_PNOE_SNIPPETS_PNG_DIR`) and defaults
/// to a temporary folder.
@MainActor
final class SnippetsPreviewTests: XCTestCase {
    private var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["PNOE_SNIPPETS_PNG_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnoe-snippets-png")
    }

    private let sampleRows = [
        SnippetRowModel(id: UUID(), trigger: "my email", expansion: "name@example.com"),
        SnippetRowModel(
            id: UUID(), trigger: "sig block",
            expansion: "Best regards,\nSam Example\nExample Co. · name@example.com"),
    ]

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(width: 640, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.10)))
            .padding(24)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
    }

    /// Draws the view with real AppKit controls: a hosting view that is never put in a window or on screen.
    private func writePNG<V: View>(_ view: V, name: String) throws -> URL {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .aqua)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), name)
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), name)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory.appendingPathComponent("\(name).png")
        try png.write(to: url)
        return url
    }

    func testRenderSnippetsList() throws {
        let list = card { SnippetsSectionView(rows: sampleRows, onAdd: {}, onEdit: { _ in }, onDelete: { _ in }) }
        let url = try writePNG(list, name: "snippets-list")
        print("SNIPPETS_PNG \(url.path)")
        let empty = card { SnippetsSectionView(rows: [], onAdd: {}, onEdit: { _ in }, onDelete: { _ in }) }
        _ = try writePNG(empty, name: "snippets-empty")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
