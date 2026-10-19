import Foundation

/// Picks the formatter context from what the app already reads for Modes: bundle ID, window title and
/// browser URL. Pure; no Apple Events, no UserDefaults. First hit wins: user override (including off),
/// URL host, bundle ID table, window-title keyword (browsers only), then plain.
public enum FormatterContextResolver {
    public static func resolve(
        bundleID: String?,
        windowTitle: String? = nil,
        url: String? = nil,
        overrides: FormatterContextOverrides = FormatterContextOverrides()
    ) -> FormatterContextChoice {
        if let bundleID, let forced = overrides[bundleID].choice {
            return forced
        }
        if let url, let host = host(of: url), let context = context(forHost: host) {
            return .context(context)
        }
        let loweredID = bundleID?.lowercased()
        if let loweredID, let context = bundleTable[loweredID] {
            return .context(context)
        }
        if let loweredID, browserBundleIDs.contains(loweredID),
           let windowTitle, let context = context(forTitle: windowTitle) {
            return .context(context)
        }
        return .context(.plain)
    }

    // MARK: Tables

    /// Bundle IDs, lowercased for lookup.
    static let bundleIDs: [(context: FormatterContext, ids: [String])] = [
        (.email, [
            "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "it.bloop.airmail2",
            "com.mimestream.Mimestream", "org.mozilla.thunderbird",
        ]),
        (.chat, [
            "com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram",
            "com.hnc.Discord", "com.microsoft.teams2", "org.whispersystems.signal-desktop",
        ]),
        (.notes, [
            "com.apple.Notes", "md.obsidian", "notion.id", "net.shinyfrog.bear", "com.apple.reminders",
            "com.culturedcode.ThingsMac", "com.evernote.Evernote", "com.microsoft.onenote.mac",
        ]),
        (.agent, [
            "com.anthropic.claudefordesktop", "com.openai.chat", "com.todesktop.230313mzl4w4u92",
            "com.microsoft.VSCode", "dev.zed.Zed", "com.apple.Terminal", "com.googlecode.iterm2",
            "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        ]),
    ]

    /// Web apps by host. A host matches itself and any subdomain of it.
    static let hosts: [(context: FormatterContext, hosts: [String])] = [
        (.email, ["mail.google.com", "outlook.office.com", "outlook.live.com"]),
        (.chat, ["app.slack.com", "discord.com", "web.whatsapp.com", "teams.microsoft.com"]),
        (.notes, ["notion.so", "docs.google.com"]),
        (.agent, ["claude.ai", "chatgpt.com", "gemini.google.com"]),
    ]

    /// Title keywords for browsers when no URL is available. Matched as whole words, case-insensitively.
    static let titleKeywords: [(context: FormatterContext, keywords: [String])] = [
        (.email, ["gmail", "outlook"]),
        (.chat, ["slack", "discord", "whatsapp"]),
        (.notes, ["notion", "google docs"]),
        (.agent, ["claude", "chatgpt", "gemini"]),
    ]

    /// Browsers the app can read a URL from, plus Firefox and Zen, which have no URL script but have titles.
    static let browserBundleIDs: Set<String> = Set([
        "com.apple.Safari", "company.thebrowser.Browser", "company.thebrowser.dia", "com.google.Chrome",
        "ai.perplexity.comet", "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi", "com.kagi.kagimacOS", "ru.yandex.desktop.yandex-browser",
        "org.mozilla.firefox", "app.zen-browser.zen",
    ].map { $0.lowercased() })

    private static let bundleTable: [String: FormatterContext] = {
        var table: [String: FormatterContext] = [:]
        for row in bundleIDs { for id in row.ids { table[id.lowercased()] = row.context } }
        return table
    }()

    // MARK: Matching

    static func host(of urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var host = URLComponents(string: candidate)?.host?.lowercased() else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    static func context(forHost host: String) -> FormatterContext? {
        for row in hosts {
            for entry in row.hosts where host == entry || host.hasSuffix("." + entry) {
                return row.context
            }
        }
        return nil
    }

    static func context(forTitle title: String) -> FormatterContext? {
        let lowered = title.lowercased()
        for row in titleKeywords {
            for keyword in row.keywords where containsWord(keyword, in: lowered) {
                return row.context
            }
        }
        return nil
    }

    private static func containsWord(_ word: String, in text: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: word, range: searchStart..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !(before?.isLetter ?? false) && !(after?.isLetter ?? false) { return true }
            searchStart = range.upperBound
        }
        return false
    }
}
