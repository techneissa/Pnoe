import XCTest

final class ReplySpeechTextTests: XCTestCase {
    // MARK: Markdown

    func testStripsHeadingsListsEmphasisAndLinks() {
        let markdown = """
            # Plan for today

            Here is **bold**, *italic*, _also italic_, ~~gone~~ and `code`.

            - first item
            - second item.
            1. numbered step

            > quoted advice

            See [the docs](https://example.com/docs) and ![a diagram](https://example.com/d.png).
            """
        let plain = SpeechText.plainText(fromMarkdown: markdown)
        XCTAssertEqual(
            plain,
            """
            Plan for today.

            Here is bold, italic, also italic, gone and code.

            first item.

            second item.

            numbered step.

            quoted advice

            See the docs and a diagram.
            """)
        for marker in ["#", "**", "`", "](", "~~", "- "] {
            XCTAssertFalse(plain.contains(marker), "left \(marker)")
        }
    }

    func testDropsFencedCodeRulesAndTableSeparators() {
        let markdown = """
            Before.

            ```swift
            let secret = 1
            ```

            ---

            | Name | Size |
            | --- | --- |
            | Phonon | 148 MB |

            After.
            """
        let plain = SpeechText.plainText(fromMarkdown: markdown)
        XCTAssertFalse(plain.contains("secret"))
        XCTAssertFalse(plain.contains("---"))
        XCTAssertFalse(plain.contains("|"))
        XCTAssertEqual(plain, "Before.\n\nName, Size.\n\nPhonon, 148 MB.\n\nAfter.")
    }

    func testKeepsUnderscoresInsideWordsAndPlainStars() {
        XCTAssertEqual(SpeechText.plainText(fromMarkdown: "Set snake_case_name to 2 * 3."), "Set snake_case_name to 2 * 3.")
    }

    func testEmptyAndMarkupOnlyReplyIsEmpty() {
        XCTAssertEqual(SpeechText.plainText(fromMarkdown: "  \n\n"), "")
        XCTAssertEqual(SpeechText.plainText(fromMarkdown: "```\ncode only\n```"), "")
    }

    // MARK: Splitting

    func testShortReplyIsOneChunk() {
        XCTAssertEqual(SpeechText.chunks(from: "One. Two. Three."), ["One. Two. Three."])
    }

    func testLongReplySplitsAtSentenceEndsUnderTheLimit() {
        let sentence = "This sentence is exactly sixty characters long, no more, no less. "
        let text = String(repeating: sentence, count: 200)  // about 13,000 characters
        let chunks = SpeechText.chunks(from: text)
        XCTAssertGreaterThan(chunks.count, 2)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.unicodeScalars.count, SpeechText.ollamaInputLimit)
            XCTAssertTrue(chunk.hasSuffix("less."), "chunk ends mid-sentence: \(chunk.suffix(20))")
            XCTAssertFalse(chunk.isEmpty)
        }
        // Nothing lost or added.
        let joined = chunks.joined(separator: " ")
        XCTAssertEqual(joined.split(separator: " ").count, text.split(separator: " ").count)
    }

    func testSmallLimitPacksWholeSentences() {
        let chunks = SpeechText.chunks(from: "Aaaa bbbb. Cccc dddd. Eeee ffff.", limit: 24)
        XCTAssertEqual(chunks, ["Aaaa bbbb. Cccc dddd.", "Eeee ffff."])
    }

    func testSentenceLongerThanTheLimitSplitsAtSpaces() {
        let sentence = Array(repeating: "word", count: 50).joined(separator: " ") + "."
        let chunks = SpeechText.chunks(from: sentence, limit: 40)
        XCTAssertGreaterThan(chunks.count, 4)
        for chunk in chunks { XCTAssertLessThanOrEqual(chunk.unicodeScalars.count, 40) }
        XCTAssertEqual(chunks.joined(separator: " "), sentence)
    }

    func testWordLongerThanTheLimitIsCutAnywhere() {
        let chunks = SpeechText.chunks(from: String(repeating: "x", count: 25), limit: 10)
        XCTAssertEqual(chunks, [String(repeating: "x", count: 10), String(repeating: "x", count: 10), "xxxxx"])
    }

    func testLimitCountsScalarsNotCharacters() {
        // Each flag is one Character but two scalars.
        let text = String(repeating: "🇩🇪", count: 30)
        for chunk in SpeechText.chunks(from: text, limit: 20) {
            XCTAssertLessThanOrEqual(chunk.unicodeScalars.count, 20)
        }
    }

    func testEmptyTextHasNoChunks() {
        XCTAssertEqual(SpeechText.chunks(from: "  \n "), [])
    }
}

final class PCMSampleDecoderTests: XCTestCase {
    func testDecodesLittleEndianSixteenBitSamples() {
        var decoder = PCMSampleDecoder()
        // 0, 16384, -16384, 32767, -32768 as little-endian Int16.
        let bytes = Data([0x00, 0x00, 0x00, 0x40, 0x00, 0xC0, 0xFF, 0x7F, 0x00, 0x80])
        let samples = decoder.decode(bytes)
        XCTAssertEqual(samples.count, 5)
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[1], 0.5)
        XCTAssertEqual(samples[2], -0.5)
        XCTAssertEqual(samples[3], 32767.0 / 32768.0)
        XCTAssertEqual(samples[4], -1)
        XCTAssertFalse(decoder.hasPendingByte)
    }

    func testChunkEndingMidSampleKeepsTheByteForTheNextChunk() {
        var decoder = PCMSampleDecoder()
        // The sample 0x4000 (0.5) is split across two chunks, after two whole samples.
        let first = decoder.decode(Data([0x00, 0x00, 0x00, 0xC0, 0x00]))
        XCTAssertEqual(first, [0, -0.5])
        XCTAssertTrue(decoder.hasPendingByte)
        let second = decoder.decode(Data([0x40, 0x00, 0x00]))
        XCTAssertEqual(second, [0.5, 0])
        XCTAssertFalse(decoder.hasPendingByte)
    }

    func testSingleByteChunksGiveTheSameSamplesAsOneChunk() {
        let bytes = Data((0..<64).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) })
        var whole = PCMSampleDecoder()
        let expected = whole.decode(bytes)
        var pieces = PCMSampleDecoder()
        var actual: [Float] = []
        for byte in bytes { actual += pieces.decode(Data([byte])) }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(expected.count, 32)
    }

    func testEmptyChunkChangesNothing() {
        var decoder = PCMSampleDecoder()
        XCTAssertEqual(decoder.decode(Data()), [])
        _ = decoder.decode(Data([0x01]))
        XCTAssertEqual(decoder.decode(Data()), [])
        XCTAssertTrue(decoder.hasPendingByte)
    }
}

final class ReplySpeechSettingsTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "PnoeReplySpeech-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testRegisteredDefaultsAreOffAndDefaultVoices() throws {
        let defaults = try makeDefaults()
        defaults.register(defaults: ReplySpeechSettings.registeredDefaults)
        XCTAssertFalse(ReplySpeechSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(ReplySpeechSettings.ollamaVoice(defaults: defaults), "default")
        XCTAssertEqual(ReplySpeechSettings.appleVoice(defaults: defaults), "")
    }

    func testRegisteredDefaultsDoNotReplaceASavedChoice() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: ReplySpeechSettings.enabledKey)
        defaults.set("emma", forKey: ReplySpeechSettings.ollamaVoiceKey)
        defaults.register(defaults: ReplySpeechSettings.registeredDefaults)
        XCTAssertTrue(ReplySpeechSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(ReplySpeechSettings.ollamaVoice(defaults: defaults), "emma")
    }

    func testBlankSavedOllamaVoiceFallsBackToDefault() throws {
        let defaults = try makeDefaults()
        defaults.set("  ", forKey: ReplySpeechSettings.ollamaVoiceKey)
        XCTAssertEqual(ReplySpeechSettings.ollamaVoice(defaults: defaults), "default")
    }

    func testBackupApplyWritesGivenValuesAndKeepsTheRest() throws {
        let defaults = try makeDefaults()
        defaults.set("emma", forKey: ReplySpeechSettings.ollamaVoiceKey)
        // An older backup has none of the three: nothing changes.
        ReplySpeechSettings.apply(enabled: nil, ollamaVoice: nil, appleVoice: nil, to: defaults)
        XCTAssertFalse(ReplySpeechSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(ReplySpeechSettings.ollamaVoice(defaults: defaults), "emma")

        ReplySpeechSettings.apply(enabled: true, ollamaVoice: nil, appleVoice: "com.apple.voice.compact.en-US.Samantha", to: defaults)
        XCTAssertTrue(ReplySpeechSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(ReplySpeechSettings.ollamaVoice(defaults: defaults), "emma")
        XCTAssertEqual(ReplySpeechSettings.appleVoice(defaults: defaults), "com.apple.voice.compact.en-US.Samantha")
    }

    func testBackupFieldsSurviveEncodingAndAnOlderFileDecodes() throws {
        struct Slice: Codable {
            let readRepliesAloud: Bool?
            let readRepliesOllamaVoice: String?
            let readRepliesAppleVoice: String?
        }
        let decoded = try JSONDecoder().decode(Slice.self, from: Data(#"{"readRepliesAloud":true,"readRepliesOllamaVoice":"emma"}"#.utf8))
        XCTAssertEqual(decoded.readRepliesAloud, true)
        XCTAssertEqual(decoded.readRepliesOllamaVoice, "emma")
        XCTAssertNil(decoded.readRepliesAppleVoice)
        let old = try JSONDecoder().decode(Slice.self, from: Data("{}".utf8))
        XCTAssertNil(old.readRepliesAloud)
    }

    func testOllamaAddressComesFromTheSavedValue() throws {
        let defaults = try makeDefaults()
        XCTAssertEqual(ReplySpeechSettings.ollamaBaseURL(defaults: defaults).absoluteString, "http://localhost:11434")
        defaults.set("http://studio.local:11434", forKey: ReplySpeechSettings.ollamaBaseURLKey)
        XCTAssertEqual(ReplySpeechSettings.ollamaBaseURL(defaults: defaults).absoluteString, "http://studio.local:11434")
        defaults.set("not a url", forKey: ReplySpeechSettings.ollamaBaseURLKey)
        XCTAssertEqual(ReplySpeechSettings.ollamaBaseURL(defaults: defaults).absoluteString, "http://localhost:11434")
    }

    func testEffectiveVoiceKeepsASavedOneThatExistsAndReplacesAStaleOne() {
        XCTAssertEqual(ReplySpeechSettings.effectiveOllamaVoice(saved: "emma", available: ["default", "emma"]), "emma")
        XCTAssertEqual(ReplySpeechSettings.effectiveOllamaVoice(saved: "gone", available: ["default", "emma"]), "default")
        XCTAssertEqual(ReplySpeechSettings.effectiveOllamaVoice(saved: "gone", available: ["emma", "kent"]), "emma")
        XCTAssertEqual(ReplySpeechSettings.effectiveOllamaVoice(saved: "gone", available: []), "gone")
    }
}
