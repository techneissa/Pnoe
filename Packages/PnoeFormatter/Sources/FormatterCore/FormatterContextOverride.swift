import Foundation

/// What the user picks for one app in the per-app list. `auto` means "use the tables".
public enum FormatterContextOverride: String, Sendable, CaseIterable, Codable {
    case auto
    case email
    case chat
    case notes
    case agent
    /// No AI cleanup for this app.
    case off

    /// The context this override forces, nil for `auto`.
    var choice: FormatterContextChoice? {
        switch self {
        case .auto: nil
        case .email: .context(.email)
        case .chat: .context(.chat)
        case .notes: .context(.notes)
        case .agent: .context(.agent)
        case .off: .off
        }
    }
}

/// The result of context selection: format with a context, or leave the take alone.
public enum FormatterContextChoice: Sendable, Equatable {
    case context(FormatterContext)
    case off
}

/// Per-app overrides, `[bundleID: override]`. Codable so the app can store it wherever it likes.
public struct FormatterContextOverrides: Sendable, Equatable, Codable {
    public private(set) var entries: [String: FormatterContextOverride]

    public init(_ entries: [String: FormatterContextOverride] = [:]) {
        self.entries = entries
    }

    /// Codes as the plain `[bundleID: choice]` dictionary.
    public init(from decoder: Decoder) throws {
        entries = try decoder.singleValueContainer().decode([String: FormatterContextOverride].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }

    /// Bundle IDs compare case-insensitively; an exact match wins.
    public subscript(bundleID: String) -> FormatterContextOverride {
        get {
            if let exact = entries[bundleID] { return exact }
            let lowered = bundleID.lowercased()
            return entries.first { $0.key.lowercased() == lowered }?.value ?? .auto
        }
        set {
            let lowered = bundleID.lowercased()
            for key in entries.keys where key.lowercased() == lowered { entries[key] = nil }
            if newValue != .auto { entries[bundleID] = newValue }
        }
    }
}
