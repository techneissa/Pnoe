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

    /// What a new local template starts on: Ollama when it runs with a suitable model; else Built-in when a Built-in
    /// model is installed (never Built-in with none); else nothing, and the provider is what the editor would
    /// pick anyway. Nothing is downloaded or started.
    static func chooseLocal(
        ollama: @Sendable () async -> [FormatterModelEntry],
        builtIn: @Sendable () async -> [FormatterModelEntry]
    ) async -> PreselectedProvider? {
        if let choice = await choose(discovery: ollama) { return choice }
        guard let entry = BuiltInModels.suggested(from: await builtIn()) else { return nil }
        return PreselectedProvider(providerName: BuiltInModels.providerName, modelName: entry.id)
    }

    /// The provider a new workflow's editor starts on: the one it already has, when that is on offer; else the
    /// first connected provider, as before Built-in existed. Built-in is on offer to everyone, so it is never the
    /// fallback: with no model installed it would be a provider that cannot run.
    static func defaultProvider(inherited: String?, available: [String], builtIn: String) -> String? {
        if let inherited, available.contains(inherited) { return inherited }
        return available.first { $0 != builtIn }
    }

    /// The lookup can finish after the user has already picked a provider; theirs wins.
    static func shouldApply(currentProvider: String?, startingProvider: String?) -> Bool {
        currentProvider == startingProvider
    }
}
