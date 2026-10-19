import Foundation

enum StarterModeKind: String, CaseIterable, Identifiable {
    case clean
    case enhance
    case email
    case rewrite
    case assistant
    case cleanedText
    case checklist
    case meetingNotes
    case summary
    case translation
    case emailReply

    var id: String { rawValue }

    /// The local-model template behind this kind, for the six added with local AI.
    var local: LocalWorkflowTemplate? {
        switch self {
        case .cleanedText: .cleanedText
        case .checklist: .checklist
        case .meetingNotes: .meetingNotes
        case .summary: .summary
        case .translation: .translation
        case .emailReply: .emailReply
        case .clean, .enhance, .email, .rewrite, .assistant: nil
        }
    }

    /// Templates built for a local model: the editor looks for an installed Ollama chat model and
    /// preselects it, so they run on this Mac with no setup.
    var prefersLocalModel: Bool { local != nil }

    /// Translation asks which language to write.
    var asksForTargetLanguage: Bool { local?.asksForTargetLanguage ?? false }
}

struct StarterModeTemplate: Identifiable {
    let kind: StarterModeKind
    let id: UUID
    let name: String
    let icon: ModeIcon
    let description: String
    let guidance: String
    let promptId: UUID?
    let outputMode: ModeOutputMode
    let usesAIEnhancement: Bool
    let useSelectedTextContext: Bool
    let useScreenCapture: Bool
    let isDefault: Bool

    var featureLabels: [String] {
        var labels = ["Transcription", "Realtime"]

        if usesAIEnhancement {
            labels.append("AI")
        } else {
            labels.append("No AI")
        }

        if outputMode == .respond {
            labels.append("Respond")
        } else {
            labels.append("Paste")
        }

        return labels
    }
}

extension StarterModeTemplate {
    /// A paste workflow with AI on, from one of the local-model templates. Its single sentence goes behind
    /// the picker's (i); there is no longer guidance.
    init(_ kind: StarterModeKind, _ local: LocalWorkflowTemplate) {
        self.init(
            kind: kind,
            id: local.templateId,
            name: local.title,
            icon: .symbol(local.symbol),
            description: local.summary,
            guidance: "",
            promptId: local.promptId,
            outputMode: .paste,
            usesAIEnhancement: true,
            useSelectedTextContext: local.readsEmailContext,
            useScreenCapture: local.readsEmailContext,
            isDefault: false
        )
    }

    var pickerOption: WorkflowTemplateOption {
        WorkflowTemplateOption(
            id: id,
            title: name,
            icon: icon.value,
            isEmoji: icon.kind == .emoji,
            summary: description,
            detail: guidance.isEmpty ? nil : guidance
        )
    }
}

enum StarterModeCatalog {
    static let templates: [StarterModeTemplate] = [
        StarterModeTemplate(
            kind: .clean,
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            name: "Dictation",
            icon: .symbol("mic.fill"),
            description: String(localized: "Fast transcription with no AI enhancement."),
            guidance: String(
                localized:
                    "Use this when you want the quickest possible voice-to-text result. It records with your configured transcription model and pastes the transcript as-is."
            ),
            promptId: nil,
            outputMode: .paste,
            usesAIEnhancement: false,
            useSelectedTextContext: false,
            useScreenCapture: false,
            isDefault: true
        ),
        StarterModeTemplate(
            kind: .enhance,
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            name: "Enhancement",
            icon: .symbol("sparkles"),
            description: "Clean up dictated text while preserving your meaning.",
            guidance:
                "Use this for everyday writing when you want grammar, flow, and light formatting improved before the result is pasted.",
            promptId: PromptTemplates.defaultPromptId,
            outputMode: .paste,
            usesAIEnhancement: true,
            useSelectedTextContext: true,
            useScreenCapture: true,
            isDefault: false
        ),
        StarterModeTemplate(
            kind: .email,
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
            name: "Email",
            icon: .symbol("envelope.fill"),
            description: "Turn a rough thought into a clean email.",
            guidance:
                "Use this after selecting relevant text or opening the related window. Pnoe uses that context to shape a clear email draft.",
            promptId: PromptTemplates.emailPromptId,
            outputMode: .paste,
            usesAIEnhancement: true,
            useSelectedTextContext: true,
            useScreenCapture: true,
            isDefault: false
        ),
        StarterModeTemplate(
            kind: .rewrite,
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!,
            name: "Rewrite",
            icon: .symbol("quote.bubble.fill"),
            description: "Rewrite selected or dictated text with better clarity.",
            guidance:
                "Use this when you have text selected and want a stronger version. The selected text is available as context for the rewrite.",
            promptId: PromptTemplates.rewritePromptId,
            outputMode: .paste,
            usesAIEnhancement: true,
            useSelectedTextContext: true,
            useScreenCapture: false,
            isDefault: false
        ),
        StarterModeTemplate(
            kind: .assistant,
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!,
            name: "Assistant",
            icon: .symbol("bubble.left.and.bubble.right.fill"),
            description: "Ask a question and keep the answer in the recorder.",
            guidance:
                "Use this for answers, summaries, and follow-ups. Instead of pasting, Pnoe keeps the conversation inside the recorder.",
            promptId: PromptTemplates.assistantPromptId,
            outputMode: .respond,
            usesAIEnhancement: true,
            useSelectedTextContext: false,
            useScreenCapture: false,
            isDefault: false
        ),
        StarterModeTemplate(.cleanedText, .cleanedText),
        StarterModeTemplate(.checklist, .checklist),
        StarterModeTemplate(.meetingNotes, .meetingNotes),
        StarterModeTemplate(.summary, .summary),
        StarterModeTemplate(.translation, .translation),
        StarterModeTemplate(.emailReply, .emailReply),
    ]

    /// The templates the New Workflow picker offers. Enhancement stays in the catalog for onboarding and
    /// for workflows already created from it, but Cleaned Text replaces it in the picker.
    static var pickerTemplates: [StarterModeTemplate] {
        templates.filter { $0.kind != .enhance }
    }

    static var ids: Set<UUID> {
        Set(templates.map(\.id))
    }
}
