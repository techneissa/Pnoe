import FormatterModels
import Foundation

/// The provider and model a new AI workflow starts on.
struct PreselectedProvider: Equatable {
    let providerName: String
    let modelName: String
}

/// New AI templates run locally when they can: if Ollama is running with an installed chat model,
/// that model is preselected. Otherwise nothing is chosen and the provider stays for the user to pick.
/// Nothing is downloaded or started.
enum TemplateProviderPreselection {
    /// The raw value of the app's Ollama provider.
    static let ollamaProviderName = "Ollama"

    /// `discovery` lists the installed models (`OllamaModelDiscovery.fetch` in the app, a fake in tests).
    static func choose(discovery: @Sendable () async -> [FormatterModelEntry]) async -> PreselectedProvider? {
        guard let entry = await LocalModelPreselection.choose(discovery: discovery) else { return nil }
        return PreselectedProvider(providerName: ollamaProviderName, modelName: entry.spec.identifier)
    }

    /// The lookup can finish after the user has already picked a provider; theirs wins.
    static func shouldApply(currentProvider: String?, startingProvider: String?) -> Bool {
        currentProvider == startingProvider
    }
}
