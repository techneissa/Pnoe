import Foundation

/// A provider and model the Playground can run a workflow on. Strings only, so the screen and its tests hold
/// no app types; the app maps them to its own provider type when it runs.
struct PlaygroundModelChoice: Hashable, Identifiable {
    /// The provider's name as the app shows it ("Ollama", "Anthropic").
    let provider: String
    /// The model, or nil for a provider that has no model to pick (Local CLI runs its own command).
    let model: String?
    /// What to show instead of `model` when that is an id and not a name (a Built-in model is a file).
    var title: String? = nil

    var id: String { provider + "|" + (model ?? "") }
    /// The menu row: "Ollama · gemma3:4b".
    var label: String { (title ?? model).map { "\(provider) · \($0)" } ?? provider }
    /// The name for the time line.
    var modelName: String { title ?? model ?? provider }

    // Two choices are the same choice when they name the same provider and model; the title is only a label.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
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

    /// `choices` with `own` first when missing, and no repeats. A repeat that has a title gives it to the first
    /// copy (the workflow's own choice carries an id; the model list knows its name).
    static func merged(_ choices: [PlaygroundModelChoice], own: PlaygroundModelChoice?) -> [PlaygroundModelChoice] {
        var result: [PlaygroundModelChoice] = []
        var index: [String: Int] = [:]
        for choice in (own.map { [$0] } ?? []) + choices {
            if let existing = index[choice.id] {
                if result[existing].title == nil, choice.title != nil { result[existing].title = choice.title }
            } else {
                index[choice.id] = result.count
                result.append(choice)
            }
        }
        return result
    }

    /// The installed Built-in models, listed by name. The model is the id that the workflow stores.
    static func builtIn(_ rows: [BuiltInModelRow], providerName: String) -> [PlaygroundModelChoice] {
        rows.map { PlaygroundModelChoice(provider: providerName, model: $0.id, title: $0.name) }
    }
}
