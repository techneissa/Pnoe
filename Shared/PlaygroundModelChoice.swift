import Foundation

/// A provider and model the Playground can run a workflow on. Strings only, so the screen and its tests hold
/// no app types; the app maps them to its own provider type when it runs.
struct PlaygroundModelChoice: Hashable, Identifiable {
    /// The provider's name as the app shows it ("Ollama", "Anthropic").
    let provider: String
    /// The model, or nil for a provider that has no model to pick (Local CLI runs its own command).
    let model: String?

    var id: String { provider + "|" + (model ?? "") }
    /// The menu row: "Ollama · gemma3:4b".
    var label: String { model.map { "\(provider) · \($0)" } ?? provider }
    /// The name for the time line.
    var modelName: String { model ?? provider }
}

/// What the Playground's model menu lists, built from the providers the app reports as connected.
enum PlaygroundModelOptions {
    struct Provider: Equatable {
        let name: String
        let models: [String]
        /// A provider with no model to choose (Local CLI): listed once by name.
        var usesDefaultModel = false
    }

    /// Every model of every provider given, in order. A provider with no models and no default is left out.
    /// `own` (the workflow's own provider and model) is listed first when it is not in the list already.
    static func choices(from providers: [Provider], including own: PlaygroundModelChoice? = nil) -> [PlaygroundModelChoice] {
        var result: [PlaygroundModelChoice] = []
        for provider in providers {
            if provider.usesDefaultModel {
                result.append(PlaygroundModelChoice(provider: provider.name, model: nil))
            } else {
                result += provider.models.map { PlaygroundModelChoice(provider: provider.name, model: $0) }
            }
        }
        return merged(result, own: own)
    }

    /// `choices` with `own` first when missing, and no repeats.
    static func merged(_ choices: [PlaygroundModelChoice], own: PlaygroundModelChoice?) -> [PlaygroundModelChoice] {
        var seen = Set<String>()
        return ((own.map { [$0] } ?? []) + choices).filter { seen.insert($0.id).inserted }
    }
}
