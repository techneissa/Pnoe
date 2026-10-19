import Foundation
import Testing
@testable import FormatterCore

@Suite("FormatterContextResolver")
struct FormatterContextResolverTests {
    private static let safari = "com.apple.Safari"

    // MARK: Tables

    private static let bundleRows: [(String, FormatterContext)] = FormatterContextResolver.bundleIDs.flatMap { row in
        row.ids.map { ($0, row.context) }
    }

    private static let hostRows: [(String, FormatterContext)] = FormatterContextResolver.hosts.flatMap { row in
        row.hosts.map { ($0, row.context) }
    }

    @Test(arguments: bundleRows)
    func everyBundleIDRow(_ id: String, _ expected: FormatterContext) {
        #expect(FormatterContextResolver.resolve(bundleID: id) == .context(expected))
        #expect(FormatterContextResolver.resolve(bundleID: id.lowercased()) == .context(expected))
    }

    @Test(arguments: hostRows)
    func everyHostRow(_ host: String, _ expected: FormatterContext) {
        let choice = FormatterContextResolver.resolve(bundleID: Self.safari, url: "https://\(host)/some/path?q=1")
        #expect(choice == .context(expected))
    }

    @Test func tablesHaveNoDuplicateBundleIDs() {
        let ids = Self.bundleRows.map { $0.0.lowercased() }
        #expect(Set(ids).count == ids.count)
    }

    @Test func tablesCoverTheFourContexts() {
        #expect(Set(Self.bundleRows.map(\.1)) == [.email, .chat, .notes, .agent])
        #expect(Set(Self.hostRows.map(\.1)) == [.email, .chat, .notes, .agent])
    }

    // MARK: Hosts

    @Test func hostMatchesSubdomainsButNotParents() {
        #expect(FormatterContextResolver.resolve(bundleID: Self.safari, url: "https://mail.google.com/mail/u/0/") == .context(.email))
        #expect(FormatterContextResolver.resolve(bundleID: Self.safari, url: "https://google.com/search?q=x") == .context(.plain))
        #expect(FormatterContextResolver.resolve(bundleID: Self.safari, url: "https://www.google.com") == .context(.plain))
        #expect(FormatterContextResolver.resolve(bundleID: Self.safari, url: "https://docs.google.com/document/d/1") == .context(.notes))
        #expect(FormatterContextResolver.resolve(bundleID: Self.safari, url: "https://eu.app.slack.com/client") == .context(.chat))
        #expect(FormatterContextResolver.resolve(bundleID: Self.safari, url: "https://www.notion.so/page") == .context(.notes))
    }

    @Test func hostDoesNotMatchLookalikes() {
        for url in ["https://notnotion.so", "https://evil-claude.ai", "https://discord.com.example.org", "https://example.org/claude.ai"] {
            #expect(FormatterContextResolver.resolve(bundleID: Self.safari, url: url) == .context(.plain), "\(url)")
        }
    }

    @Test func hostParsingIsForgiving() {
        #expect(FormatterContextResolver.resolve(bundleID: Self.safari, url: "MAIL.Google.com/inbox") == .context(.email))
        #expect(FormatterContextResolver.resolve(bundleID: Self.safari, url: "https://mail.google.com.") == .context(.email))
        #expect(FormatterContextResolver.resolve(bundleID: Self.safari, url: "  https://claude.ai/new  ") == .context(.agent))
        #expect(FormatterContextResolver.resolve(bundleID: Self.safari, url: "") == .context(.plain))
        #expect(FormatterContextResolver.resolve(bundleID: Self.safari, url: "not a url") == .context(.plain))
    }

    @Test func hostBeatsBundleID() {
        // A mail host in a chat app's bundle: the URL is the stronger signal.
        #expect(FormatterContextResolver.resolve(bundleID: "com.tinyspeck.slackmacgap", url: "https://mail.google.com") == .context(.email))
    }

    @Test func unknownHostFallsThroughToBundleID() {
        #expect(FormatterContextResolver.resolve(bundleID: "com.apple.Notes", url: "https://example.org") == .context(.notes))
    }

    // MARK: Titles

    @Test(arguments: [
        ("Inbox (3) - person@example.org - Gmail", FormatterContext.email),
        ("Outlook", .email),
        ("Slack | general | Workspace", .chat),
        ("Discord | #dev", .chat),
        ("WhatsApp", .chat),
        ("Roadmap – Notion", .notes),
        ("Untitled document - Google Docs", .notes),
        ("Claude", .agent),
        ("New chat · ChatGPT", .agent),
        ("Gemini", .agent),
    ])
    func titleKeywordsInBrowsers(_ title: String, _ expected: FormatterContext) {
        #expect(FormatterContextResolver.resolve(bundleID: Self.safari, windowTitle: title) == .context(expected))
    }

    @Test func titleKeywordsOnlyForBrowsers() {
        for id in ["com.apple.TextEdit", "com.example.unknown", "com.apple.dt.Xcode"] {
            #expect(FormatterContextResolver.resolve(bundleID: id, windowTitle: "Inbox - Gmail") == .context(.plain), "\(id)")
        }
        #expect(FormatterContextResolver.resolve(bundleID: nil, windowTitle: "Inbox - Gmail") == .context(.plain))
    }

    @Test func titleKeywordsMatchWholeWords() {
        #expect(FormatterContextResolver.resolve(bundleID: Self.safari, windowTitle: "Claudette's recipes") == .context(.plain))
        #expect(FormatterContextResolver.resolve(bundleID: Self.safari, windowTitle: "Slacking off") == .context(.plain))
        #expect(FormatterContextResolver.resolve(bundleID: Self.safari, windowTitle: "") == .context(.plain))
    }

    @Test func urlBeatsTitle() {
        let choice = FormatterContextResolver.resolve(bundleID: Self.safari, windowTitle: "Claude", url: "https://mail.google.com")
        #expect(choice == .context(.email))
    }

    @Test func bundleIDBeatsTitle() {
        // Not reachable for browsers in the tables today, but the order is bundle table first.
        #expect(FormatterContextResolver.resolve(bundleID: "com.apple.Notes", windowTitle: "Slack") == .context(.notes))
    }

    // MARK: Fallback

    @Test func unknownAppIsPlain() {
        #expect(FormatterContextResolver.resolve(bundleID: "com.example.unknown") == .context(.plain))
        #expect(FormatterContextResolver.resolve(bundleID: nil) == .context(.plain))
        #expect(FormatterContextResolver.resolve(bundleID: "com.example.unknown", windowTitle: "Gmail", url: "https://example.org") == .context(.plain))
    }

    // MARK: Overrides

    @Test func overrideBeatsEverything() {
        let overrides = FormatterContextOverrides([Self.safari: .agent])
        let choice = FormatterContextResolver.resolve(
            bundleID: Self.safari, windowTitle: "Gmail", url: "https://mail.google.com", overrides: overrides)
        #expect(choice == .context(.agent))
    }

    @Test(arguments: [
        (FormatterContextOverride.email, FormatterContextChoice.context(.email)),
        (.chat, .context(.chat)),
        (.notes, .context(.notes)),
        (.agent, .context(.agent)),
        (.off, .off),
    ])
    func eachOverrideForcesItsChoice(_ override: FormatterContextOverride, _ expected: FormatterContextChoice) {
        let overrides = FormatterContextOverrides(["com.apple.Notes": override])
        #expect(FormatterContextResolver.resolve(bundleID: "com.apple.Notes", overrides: overrides) == expected)
    }

    @Test func autoOverrideUsesTheTables() {
        let overrides = FormatterContextOverrides(["com.apple.Notes": .auto])
        #expect(FormatterContextResolver.resolve(bundleID: "com.apple.Notes", overrides: overrides) == .context(.notes))
    }

    @Test func offOverrideWinsOverHostAndTable() {
        let overrides = FormatterContextOverrides(["com.apple.mail": .off, Self.safari: .off])
        #expect(FormatterContextResolver.resolve(bundleID: "com.apple.mail", overrides: overrides) == .off)
        #expect(FormatterContextResolver.resolve(bundleID: Self.safari, url: "https://mail.google.com", overrides: overrides) == .off)
    }

    @Test func overrideForAnotherAppDoesNotApply() {
        let overrides = FormatterContextOverrides(["com.apple.mail": .off])
        #expect(FormatterContextResolver.resolve(bundleID: "com.apple.Notes", overrides: overrides) == .context(.notes))
    }

    @Test func overrideLookupIgnoresCase() {
        let overrides = FormatterContextOverrides(["COM.Apple.Mail": .chat])
        #expect(FormatterContextResolver.resolve(bundleID: "com.apple.mail", overrides: overrides) == .context(.chat))
    }

    // MARK: Override store

    @Test func storeSubscriptDefaultsToAutoAndDropsAuto() {
        var store = FormatterContextOverrides()
        #expect(store["com.example.app"] == .auto)
        store["com.example.app"] = .chat
        #expect(store["com.example.app"] == .chat)
        store["COM.EXAMPLE.APP"] = .off
        #expect(store.entries.count == 1)
        #expect(store["com.example.app"] == .off)
        store["com.example.app"] = .auto
        #expect(store.entries.isEmpty)
    }

    @Test func storeRoundTripsAsAPlainDictionary() throws {
        var store = FormatterContextOverrides()
        store["com.apple.Notes"] = .agent
        store["com.apple.mail"] = .off
        let data = try JSONEncoder().encode(store)
        let object = try JSONDecoder().decode([String: String].self, from: data)
        #expect(object == ["com.apple.Notes": "agent", "com.apple.mail": "off"])
        #expect(try JSONDecoder().decode(FormatterContextOverrides.self, from: data) == store)
    }

    @Test func storeRejectsUnknownChoices() {
        let data = Data(#"{"com.apple.Notes":"shouting"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(FormatterContextOverrides.self, from: data) }
    }

    // MARK: Display names

    @Test func everyCaseHasADisplayName() {
        for context in FormatterContext.allCases { #expect(!FormatterContextNames.displayName(context).isEmpty) }
        for override in FormatterContextOverride.allCases { #expect(!FormatterContextNames.displayName(override).isEmpty) }
        #expect(FormatterContextNames.displayName(FormatterContextChoice.off) == "Off")
        #expect(FormatterContextNames.displayName(FormatterContextOverride.agent) == FormatterContextNames.displayName(FormatterContext.agent))
    }
}
