import Foundation

/// Step 4: the prompt. The prefix (system turn plus six shot turns) never changes between requests, so a
/// runtime decodes it once. The suffix is one user turn: a JSON envelope with the context label and the
/// transcript, then the rule restated.
public struct PromptBuilder: Sendable {
    public struct Shot: Sendable, Equatable, Decodable {
        public var context: String
        public var transcript: String
        public var output: String

        public init(context: String, transcript: String, output: String) {
            self.context = context
            self.transcript = transcript
            self.output = output
        }
    }

    public enum LoadError: Error, Equatable {
        case missingResource(String)
        case invalidShots
    }

    /// Restated after the transcript on every turn, the shots included.
    public static let closingRule =
        "Output only the cleaned transcript. Keep every ⟦n⟧ marker exactly once, in order, except one that sat inside words you removed as a self-correction."

    public let systemPrompt: String
    public let shots: [Shot]

    public init(systemPrompt: String, shots: [Shot]) {
        self.systemPrompt = systemPrompt
        self.shots = shots
    }

    /// The prompt files shipped in the package.
    public static func bundled() throws -> PromptBuilder {
        guard let systemURL = Bundle.module.url(forResource: "system_prompt", withExtension: "txt") else {
            throw LoadError.missingResource("system_prompt.txt")
        }
        guard let shotsURL = Bundle.module.url(forResource: "shots", withExtension: "json") else {
            throw LoadError.missingResource("shots.json")
        }
        let system = try String(contentsOf: systemURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let shots = try? JSONDecoder().decode([Shot].self, from: Data(contentsOf: shotsURL)), !shots.isEmpty else {
            throw LoadError.invalidShots
        }
        return PromptBuilder(systemPrompt: system, shots: shots)
    }

    public var prefix: PromptPrefix {
        var messages = [ChatMessage(role: .system, content: systemPrompt)]
        for shot in shots {
            messages.append(ChatMessage(role: .user, content: Self.userContent(contextLabel: shot.context, transcript: shot.transcript)))
            messages.append(ChatMessage(role: .assistant, content: shot.output))
        }
        return PromptPrefix(messages: messages)
    }

    public func suffix(transcript: String, context: FormatterContext) -> [ChatMessage] {
        [ChatMessage(role: .user, content: Self.userContent(contextLabel: context.promptLabel, transcript: transcript))]
    }

    private struct Envelope: Encodable {
        var context: String
        var transcript: String
    }

    /// Removes `<tag>` pieces so a take cannot fake an envelope boundary. JSON escaping covers the rest.
    static func stripTags(_ text: String) -> String {
        text.replacing(#/<\/?[A-Za-z!][^<>]*>/#, with: "")
    }

    static func userContent(contextLabel: String, transcript: String) -> String {
        let envelope = Envelope(context: contextLabel, transcript: stripTags(transcript))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(envelope)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return json + "\n\n" + closingRule
    }
}
