import Foundation

/// The kind of text field a dictation is pasted into. Chosen in code, never by the model.
public enum FormatterContext: String, Sendable, CaseIterable, Codable {
    case email
    case chat
    case notes
    case agent
    /// Unknown apps: only punctuation, case and fillers change.
    case plain

    /// The label the prompt envelope carries for this context.
    public var promptLabel: String {
        switch self {
        case .email: "email body"
        case .chat: "chat message"
        case .notes: "notes app"
        case .agent: "prompt to an AI coding agent"
        case .plain: "plain text field"
        }
    }
}
