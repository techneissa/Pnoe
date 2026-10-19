import Testing
@testable import FormatterCore

struct SpanCase: Sendable, CustomTestStringConvertible {
    let spoken: String
    /// The take with spoken forms written out.
    let normalized: String
    /// Written text of each protected span, in order.
    let spans: [String]
    var testDescription: String { spoken }
}

@Suite("TokenProtector and SpokenNormalizer")
struct TokenProtectorTests {
    static let positives: [SpanCase] = [
        // URLs and emails, spoken and written
        SpanCase(spoken: "send it to tom at example dot com thanks", normalized: "send it to tom@example.com thanks", spans: ["tom@example.com"]),
        SpanCase(spoken: "contact Tom at tom at example dot com thanks", normalized: "contact Tom at tom@example.com thanks", spans: ["tom@example.com"]),
        SpanCase(spoken: "john dot smith at gmail dot com", normalized: "john.smith@gmail.com", spans: ["john.smith@gmail.com"]),
        SpanCase(spoken: "mail jo@example.org please", normalized: "mail jo@example.org please", spans: ["jo@example.org"]),
        SpanCase(spoken: "see https://example.com/a?b=c. now", normalized: "see https://example.com/a?b=c. now", spans: ["https://example.com/a?b=c"]),
        SpanCase(spoken: "go to github dot com slash techneissa slash Pnoe today", normalized: "go to github.com/techneissa/Pnoe today", spans: ["github.com/techneissa/Pnoe"]),
        SpanCase(spoken: "open example.com in the browser", normalized: "open example.com in the browser", spans: ["example.com"]),
        // File names and paths
        SpanCase(spoken: "open config dot yaml and look", normalized: "open config.yaml and look", spans: ["config.yaml"]),
        SpanCase(spoken: "test underscore user dot py fails", normalized: "test_user.py fails", spans: ["test_user.py"]),
        SpanCase(spoken: "in the AIEnhancementService dot swift rename it", normalized: "in the AIEnhancementService.swift rename it", spans: ["AIEnhancementService.swift"]),
        SpanCase(spoken: "the function in utils slash text dot py is slow", normalized: "the function in utils/text.py is slow", spans: ["utils/text.py"]),
        SpanCase(spoken: "branch feature slash settings and push", normalized: "branch feature/settings and push", spans: ["feature/settings"]),
        SpanCase(spoken: "file source slash auth slash login dot ts now", normalized: "file source/auth/login.ts now", spans: ["source/auth/login.ts"]),
        SpanCase(spoken: "under Views slash Settings keep it", normalized: "under Views/Settings keep it", spans: ["Views/Settings"]),
        SpanCase(spoken: "slash usr slash local is full", normalized: "/usr/local is full", spans: ["/usr/local"]),
        SpanCase(spoken: "put it in tilde slash documents later", normalized: "put it in ~/documents later", spans: ["~/documents"]),
        SpanCase(spoken: "the path utils/text.py is slow", normalized: "the path utils/text.py is slow", spans: ["utils/text.py"]),
        SpanCase(spoken: "edit README.md before release", normalized: "edit README.md before release", spans: ["README.md"]),
        SpanCase(spoken: "my underscore file dash name dot json is here", normalized: "my_file-name.json is here", spans: ["my_file-name.json"]),
        // Identifiers
        SpanCase(spoken: "the function parseTranscript is slow", normalized: "the function parseTranscript is slow", spans: ["parseTranscript"]),
        SpanCase(spoken: "rename makeRequest to performRequest now", normalized: "rename makeRequest to performRequest now", spans: ["makeRequest", "performRequest"]),
        SpanCase(spoken: "set max_retries to something", normalized: "set max_retries to something", spans: ["max_retries"]),
        SpanCase(spoken: "run it with --verbose please", normalized: "run it with --verbose please", spans: ["--verbose"]),
        SpanCase(spoken: "run `git status` first", normalized: "run `git status` first", spans: ["`git status`"]),
        SpanCase(spoken: "the SwiftLint check passes", normalized: "the SwiftLint check passes", spans: ["SwiftLint"]),
        SpanCase(spoken: "the parseTranscript's output looks wrong", normalized: "the parseTranscript's output looks wrong", spans: ["parseTranscript"]),
        // Versions
        SpanCase(spoken: "upgrade to v2 or 1.2.3 today", normalized: "upgrade to v2 or 1.2.3 today", spans: ["v2", "1.2.3"]),
        // Numbers
        SpanCase(spoken: "we have thirty seats left and fifty on the waitlist", normalized: "we have 30 seats left and 50 on the waitlist", spans: ["30", "50"]),
        SpanCase(spoken: "the budget is forty thousand for Q3 and sixty thousand for Q4 so total is one hundred thousand", normalized: "the budget is 40,000 for Q3 and 60,000 for Q4 so total is 100,000", spans: ["40,000", "Q3", "60,000", "Q4", "100,000"]),
        SpanCase(spoken: "the total of twelve thousand five hundred dollars is high", normalized: "the total of 12,500 dollars is high", spans: ["12,500"]),
        SpanCase(spoken: "a ten percent discount please", normalized: "a 10% discount please", spans: ["10%"]),
        SpanCase(spoken: "about two point four seconds", normalized: "about 2.4 seconds", spans: ["2.4"]),
        SpanCase(spoken: "tomorrow at ten am in the hall", normalized: "tomorrow at 10 AM in the hall", spans: ["10 AM"]),
        SpanCase(spoken: "meet me at gate twelve around six thirty PM ok", normalized: "meet me at gate 12 around 6:30 PM ok", spans: ["12", "6:30 PM"]),
        SpanCase(spoken: "call me at 3 pm today", normalized: "call me at 3 PM today", spans: ["3 PM"]),
        SpanCase(spoken: "in room four oh two please", normalized: "in room 402 please", spans: ["402"]),
        SpanCase(spoken: "wait five minutes and retry", normalized: "wait 5 minutes and retry", spans: ["5"]),
        SpanCase(spoken: "read issue ten and write a plan", normalized: "read issue 10 and write a plan", spans: ["10"]),
        SpanCase(spoken: "it was two thousand twenty six when", normalized: "it was 2026 when", spans: ["2026"]),
        SpanCase(spoken: "we need twenty-one chairs", normalized: "we need 21 chairs", spans: ["21"]),
        SpanCase(spoken: "port 8080 or 9090 works", normalized: "port 8080 or 9090 works", spans: ["8080", "9090"]),
        SpanCase(spoken: "price is $12,500. thanks", normalized: "price is $12,500. thanks", spans: ["$12,500"]),
        // Priority: a URL beats a file name, a path beats a number
        SpanCase(spoken: "visit swift dot org slash docs now", normalized: "visit swift.org/docs now", spans: ["swift.org/docs"]),
    ]

    static let negatives: [String] = [
        "the dot on the map is red",
        "slash prices at the store",
        "we want a slash and burn policy",
        "this and slash or that works",
        "I think maybe the deadline is Friday",
        "two or three fixes would do",
        "the first three errors matter",
        "one of the options is fine",
        "meet me at the airport",
        "he said hello dot",
        "good point about the plan",
        "I have one minute left",
    ]

    @Test(arguments: positives)
    func writesOutAndProtectsSpans(_ c: SpanCase) {
        let result = TokenProtector.protect(c.spoken)
        #expect(result.normalized == c.normalized)
        #expect(result.spans.map(\.written) == c.spans)
        #expect(result.restore(result.text) == result.normalized)
        // Each span became exactly one marker, numbered from 1 in order.
        #expect(result.spans.map(\.id) == Array(1...max(result.spans.count, 1)).prefix(result.spans.count).map { $0 })
        for span in result.spans { #expect(result.text.contains(TokenProtector.marker(span.id))) }
    }

    @Test(arguments: negatives)
    func negativesProtectNothingUnexpected(_ text: String) {
        let result = TokenProtector.protect(text)
        #expect(result.spans.isEmpty, "unexpected spans \(result.spans.map(\.written)) in \(text)")
        #expect(result.normalized == text)
        #expect(result.text == text)
    }

    @Test func roundTripOverRoundOneSet() {
        for item in RoundOneInputs.all {
            let cleaned = FillerCleaner.clean(item.raw, context: item.context)
            let result = TokenProtector.protect(cleaned)
            #expect(result.restore(result.text) == result.normalized, "round trip failed for \(item.id)")
        }
    }

    @Test func markersCarryTrailingPunctuationOutside() {
        let result = TokenProtector.protect("open config dot yaml, then utils slash text dot py.")
        #expect(result.text == "open ⟦1⟧, then ⟦2⟧.")
        #expect(result.normalized == "open config.yaml, then utils/text.py.")
    }

    @Test func vocabularyKeepsCanonicalSpelling() {
        let result = TokenProtector.protect("tell pnoe and dana whitfield's team about kubernetes", vocabulary: ["Pnoe", "Dana Whitfield", "Kubernetes"])
        #expect(result.normalized == "tell Pnoe and Dana Whitfield's team about Kubernetes")
        #expect(result.spans.map(\.written) == ["Pnoe", "Dana Whitfield", "Kubernetes"])
        #expect(result.text == "tell ⟦1⟧ and ⟦2⟧'s team about ⟦3⟧")
    }

    @Test func vocabularyLosesToEarlierCategories() {
        // "config" is claimed by the file name first, so the vocabulary entry does not split it.
        let result = TokenProtector.protect("open config dot yaml", vocabulary: ["config"])
        #expect(result.spans.map(\.written) == ["config.yaml"])
    }

    @Test func existingMarkersInTheTakeAreRemoved() {
        let result = TokenProtector.protect("say ⟦9⟧ and open config dot yaml")
        #expect(!result.normalized.contains("⟦"))
        #expect(result.spans.map(\.written) == ["9", "config.yaml"])
    }

    @Test func restoreLeavesUnknownMarkersAlone() {
        let result = TokenProtector.protect("open config dot yaml")
        #expect(result.restore("Open ⟦1⟧ and ⟦7⟧.") == "Open config.yaml and ⟦7⟧.")
    }
}
