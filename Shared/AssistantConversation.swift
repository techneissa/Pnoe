import Combine
import Foundation

enum AssistantMessageRole: String, Codable {
    case user
    case assistant
}

struct AssistantDisplayMessage: Identifiable, Equatable {
    let id: UUID
    let role: AssistantMessageRole
    let content: String
    let createdAt: Date
}

enum AssistantPhase: Equatable {
    case inactive
    case responding
    case ready
    case sendingFollowUp
    case failed(String)
}

/// The messages and phase of the Assistant panel, and the speech that follows an answer. `AssistantSession` adds the
/// provider and model the answers come from. Lives here so tests reach it.
@MainActor
class AssistantConversation: ObservableObject {
    @Published private(set) var phase: AssistantPhase = .inactive
    @Published private(set) var messages: [AssistantDisplayMessage] = []

    /// Reads the Assistant's answers aloud when "Read Replies Aloud" is on.
    let speaker: ReplySpeaker

    private(set) var systemPrompt: String?

    init(speaker: ReplySpeaker) {
        self.speaker = speaker
    }

    var isVisible: Bool {
        phase != .inactive
    }

    var isBusy: Bool {
        phase == .responding || phase == .sendingFollowUp
    }

    func beginConversation(transcript: String) {
        messages = []

        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTranscript.isEmpty {
            messages.append(
                AssistantDisplayMessage(
                    id: UUID(),
                    role: .user,
                    content: trimmedTranscript,
                    createdAt: Date()
                )
            )
        }

        phase = .responding
    }

    /// An answer that arrives after the panel closed (`reset()`) is dropped: it must neither reopen the session nor
    /// be spoken where the stop button cannot be reached.
    func finishInitialResponse(_ response: String, systemPrompt: String?) {
        guard phase == .responding else { return }
        self.systemPrompt = systemPrompt

        let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedResponse.isEmpty {
            appendOrReplace(
                message: AssistantDisplayMessage(
                    id: UUID(),
                    role: .assistant,
                    content: trimmedResponse,
                    createdAt: Date()
                )
            )
        }
        phase = .ready
        speaker.speakIfEnabled(trimmedResponse)
    }

    @discardableResult
    func beginFollowUp(_ text: String) -> AssistantDisplayMessage {
        let userMessage = AssistantDisplayMessage(
            id: UUID(),
            role: .user,
            content: text,
            createdAt: Date()
        )
        appendOrReplace(message: userMessage)
        phase = .sendingFollowUp
        speaker.stop(.replaced)
        return userMessage
    }

    /// Like `finishInitialResponse`, an answer that arrives when no follow-up is waiting (the panel closed) is dropped.
    @discardableResult
    func finishFollowUp(_ text: String) -> AssistantDisplayMessage {
        let assistantMessage = AssistantDisplayMessage(
            id: UUID(),
            role: .assistant,
            content: text,
            createdAt: Date()
        )
        guard phase == .sendingFollowUp else { return assistantMessage }
        appendOrReplace(message: assistantMessage)
        phase = .ready
        speaker.speakIfEnabled(text)
        return assistantMessage
    }

    func hasMessage(id: UUID) -> Bool {
        messages.contains { $0.id == id }
    }

    func fail(_ message: String) {
        // A failure that arrives after the panel closed must not bring the session back.
        guard isBusy else { return }
        phase = .failed(message)
    }

    /// Closing the panel, or starting over, ends any speech.
    func reset() {
        speaker.stop(.panelClosed)
        phase = .inactive
        messages = []
        systemPrompt = nil
    }

    private func appendOrReplace(message: AssistantDisplayMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }
}
