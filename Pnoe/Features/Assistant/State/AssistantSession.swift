import Foundation

/// The Assistant panel's conversation plus where its answers come from.
@MainActor
final class AssistantSession: AssistantConversation {
    private(set) var provider: AIProvider?
    private(set) var modelName: String?
    private(set) var modeName: String?
    private(set) var modeEmoji: String?
    private(set) var promptName: String?

    init() {
        super.init(speaker: .live())
    }

    var canSendFollowUp: Bool {
        provider != nil && !messages.isEmpty && !isBusy
    }

    func beginInitialResponse(
        transcript: String,
        provider: AIProvider?,
        modelName: String?,
        modeName: String?,
        modeEmoji: String?,
        promptName: String?
    ) {
        self.provider = provider
        self.modelName = modelName
        self.modeName = modeName
        self.modeEmoji = modeEmoji
        self.promptName = promptName
        beginConversation(transcript: transcript)
    }

    override func reset() {
        super.reset()
        provider = nil
        modelName = nil
        modeName = nil
        modeEmoji = nil
        promptName = nil
    }
}
