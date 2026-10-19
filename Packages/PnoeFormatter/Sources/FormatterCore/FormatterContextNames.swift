import Foundation

/// Every user-facing string for contexts, in one place. The internal case names stay fixed;
/// change the display names here.
public enum FormatterContextNames {
    public static func displayName(_ context: FormatterContext) -> String {
        switch context {
        case .email: "Email"
        case .chat: "Chat"
        case .notes: "Notes"
        case .agent: "Agent prompt"
        case .plain: "Plain"
        }
    }

    public static func displayName(_ override: FormatterContextOverride) -> String {
        switch override {
        case .auto: "Auto"
        case .email: displayName(FormatterContext.email)
        case .chat: displayName(FormatterContext.chat)
        case .notes: displayName(FormatterContext.notes)
        case .agent: displayName(FormatterContext.agent)
        case .off: "Off"
        }
    }

    public static func displayName(_ choice: FormatterContextChoice) -> String {
        switch choice {
        case .context(let context): displayName(context)
        case .off: "Off"
        }
    }
}
