import Foundation

/// The six starter templates that run on a local model: what the picker shows and which prompt each one
/// uses. It holds no app types, so the catalog facts can be tested; the app's `StarterModeCatalog` builds
/// its entries from it.
enum LocalWorkflowTemplate: String, CaseIterable, Identifiable {
    case cleanedText
    case checklist
    case meetingNotes
    case summary
    case translation
    case emailReply

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cleanedText: "Cleaned Text"
        case .checklist: "Checklist"
        case .meetingNotes: "Meeting Notes"
        case .summary: "Summary"
        case .translation: "Translation"
        case .emailReply: "Email Reply"
        }
    }

    /// An SF Symbol name.
    var symbol: String {
        switch self {
        case .cleanedText: "text.badge.checkmark"
        case .checklist: "checklist"
        case .meetingNotes: "note.text"
        case .summary: "text.alignleft"
        case .translation: "character.bubble"
        case .emailReply: "arrowshape.turn.up.left.fill"
        }
    }

    /// The one sentence behind the picker's (i).
    var summary: String {
        switch self {
        case .cleanedText:
            "Fixes punctuation, capitals and fillers but keeps your exact words; if the AI changes more, the plain transcript is pasted."
        case .checklist: "Turns what you say into a checklist of to-dos."
        case .meetingNotes: "Turns a spoken recap into short notes with decisions and action items."
        case .summary: "Boils what you say down to the main points."
        case .translation: "Translates what you say into the language you choose."
        case .emailReply: "Drafts a reply to the selected or open email from the points you dictate."
        }
    }

    /// The template's id in `StarterModeCatalog` (the first five belong to the older templates).
    var templateId: UUID {
        UUID(uuidString: "10000000-0000-0000-0000-0000000000\(Self.numberSuffix(for: self, base: 6))")!
    }

    /// The seeded prompt's id in `PromptTemplates` (the first five belong to the older prompts).
    var promptId: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-0000000000\(Self.numberSuffix(for: self, base: 6))")!
    }

    /// Cleaned Text keeps the speaker's words and is held to them by the formatter's guards. The others
    /// rewrite the text, so only the output sanitizer applies.
    var rewritesText: Bool { self != .cleanedText }

    var asksForTargetLanguage: Bool { self == .translation }

    /// Email Reply reads the email being answered: selected text, clipboard and the window.
    var readsEmailContext: Bool { self == .emailReply }

    var pickerOption: WorkflowTemplateOption {
        WorkflowTemplateOption(id: templateId, title: title, icon: symbol, summary: summary, detail: nil)
    }

    /// Prompts for the templates that rewrite the text.
    static let rewritingPromptIds: Set<UUID> = Set(allCases.filter(\.rewritesText).map(\.promptId))

    /// Two hex digits: 06 for the first template, 07 for the next, up to 0B.
    private static func numberSuffix(for template: Self, base: Int) -> String {
        let index = allCases.firstIndex(of: template)! + base
        return String(format: "%02X", index)
    }
}
