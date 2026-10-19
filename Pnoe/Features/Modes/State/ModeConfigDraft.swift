import Foundation

struct ModeConfigDraft {
    var id: UUID
    var name: String
    var icon: ModeIcon
    var appConfigs: [AppConfig]
    var websiteConfigs: [URLConfig]
    var triggerGroups: [ModeTriggerGroup]
    var triggerWords: [String]
    var isAIEnhancementEnabled: Bool
    var selectedPromptId: UUID?
    var selectedTranscriptionModelName: String?
    var isRealtimeTranscriptionEnabled: Bool
    var selectedLanguage: String?
    var isTextFormattingEnabled: Bool
    var useClipboardContext: Bool
    var useSelectedTextContext: Bool
    var useScreenCapture: Bool
    var selectedAIProvider: String?
    var selectedAIModel: String?
    var translationTargetLanguage: String?
    var outputMode: ModeOutputMode
    var autoSendKey: FinishAndSendKey
    var customCommand: String
    var isDefault: Bool
    var isTranscriptionFormattingExpanded: Bool
    /// Set when the draft starts from a template built for a local model (not saved).
    var prefersLocalModel = false

    private var sourceConfig: ModeConfig?

    init(mode: ConfigurationMode, modeManager: ModeManager, template: StarterModeTemplate? = nil) {
        switch mode {
        case .add:
            let inheritedConfig = modeManager.currentEffectiveConfiguration

            id = UUID()
            name = ""
            icon = .defaultIcon
            appConfigs = []
            websiteConfigs = []
            triggerGroups = []
            triggerWords = []
            isAIEnhancementEnabled = false
            selectedPromptId = inheritedConfig?.selectedPrompt.flatMap { UUID(uuidString: $0) }
            selectedTranscriptionModelName = inheritedConfig?.selectedTranscriptionModelName
            isRealtimeTranscriptionEnabled = true
            selectedLanguage = inheritedConfig?.selectedLanguage
            isTextFormattingEnabled = true
            useClipboardContext = false
            useSelectedTextContext = false
            useScreenCapture = true
            selectedAIProvider = inheritedConfig?.selectedAIProvider
            selectedAIModel = inheritedConfig?.selectedAIModel
            translationTargetLanguage = nil
            outputMode = .paste
            autoSendKey = .none
            customCommand = inheritedConfig?.customCommand?.command ?? ""
            isDefault = false
            isTranscriptionFormattingExpanded = false
            sourceConfig = nil

        case .edit(let config):
            let latestConfig = modeManager.getConfiguration(with: config.id) ?? config
            id = latestConfig.id
            name = latestConfig.name
            icon = latestConfig.icon
            appConfigs = latestConfig.appConfigs ?? []
            websiteConfigs = latestConfig.urlConfigs ?? []
            triggerGroups = latestConfig.triggerGroups ?? []
            triggerWords = latestConfig.triggerWords
            isAIEnhancementEnabled = latestConfig.isAIEnhancementEnabled
            selectedPromptId = latestConfig.selectedPrompt.flatMap { UUID(uuidString: $0) }
            selectedTranscriptionModelName = latestConfig.selectedTranscriptionModelName
            isRealtimeTranscriptionEnabled = latestConfig.isRealtimeTranscriptionEnabled
            selectedLanguage = latestConfig.selectedLanguage
            isTextFormattingEnabled = latestConfig.isTextFormattingEnabled
            useClipboardContext = latestConfig.useClipboardContext
            useSelectedTextContext = latestConfig.useSelectedTextContext
            useScreenCapture = latestConfig.useScreenCapture
            selectedAIProvider = latestConfig.selectedAIProvider
            selectedAIModel = latestConfig.selectedAIModel
            translationTargetLanguage = latestConfig.translationTargetLanguage
            outputMode = latestConfig.outputMode
            autoSendKey = latestConfig.autoSendKey
            customCommand = latestConfig.customCommand?.command ?? ""
            isDefault = latestConfig.isDefault
            isTranscriptionFormattingExpanded = false
            sourceConfig = latestConfig
        }

        if case .add = mode, let template {
            apply(template: template, existingNames: Set(modeManager.configurations.map(\.name)))
        }
    }

    /// Starts a new workflow from a starter template. Triggers and shortcuts stay empty so the
    /// copy never collides with the workflow the template was installed as.
    private mutating func apply(template: StarterModeTemplate, existingNames: Set<String>) {
        name = WorkflowNaming.uniqueName(template.name, existing: existingNames)
        icon = template.icon
        isAIEnhancementEnabled = template.usesAIEnhancement
        if let promptId = template.promptId {
            selectedPromptId = promptId
        }
        useSelectedTextContext = template.useSelectedTextContext
        useScreenCapture = template.useScreenCapture
        useClipboardContext = template.kind == .email || template.kind == .emailReply
        prefersLocalModel = template.kind.prefersLocalModel
        translationTargetLanguage = template.kind.asksForTargetLanguage ? TranslationLanguages.defaultName : nil
        outputMode = template.outputMode
    }

    var canSave: Bool {
        !name.isEmpty
    }

    mutating func applyAddModeDefaults(snapshot: ModeFormWarmupSnapshot) {
        let connectedProviders = snapshot.connectedAIProviders
        let inheritedProvider = selectedAIProvider.flatMap(AIProvider.init(rawValue:))
        let provider =
            inheritedProvider.flatMap { provider in
                connectedProviders.contains(provider) ? provider : nil
            } ?? connectedProviders.first

        selectedAIProvider = provider?.rawValue
        guard let provider, provider != .localCLI, provider != .builtIn else {
            selectedAIModel = nil
            return
        }

        let availableModels = snapshot.availableModels(for: provider)
        if let selectedAIModel,
            !selectedAIModel.isEmpty,
            (provider.supportsCustomModelID || availableModels.isEmpty || availableModels.contains(selectedAIModel))
        {
            return
        }

        selectedAIModel = snapshot.selectedModel(for: provider)
    }

    /// Points a new AI workflow at an installed Ollama model. Skipped when the provider was changed since
    /// `startingProvider` was read, so a slow lookup never overrides a choice the user already made.
    mutating func preselect(_ choice: PreselectedProvider, startingProvider: String?) {
        guard prefersLocalModel, isAIEnhancementEnabled,
            TemplateProviderPreselection.shouldApply(currentProvider: selectedAIProvider, startingProvider: startingProvider)
        else { return }
        selectedAIProvider = choice.providerName
        selectedAIModel = choice.modelName
    }

    mutating func inheritUsableTranscriptionModelSelection(from snapshot: ModeFormWarmupSnapshot) {
        if let selectedTranscriptionModelName,
            snapshot.hasUsableTranscriptionModel(named: selectedTranscriptionModelName)
        {
            return
        }

        selectedTranscriptionModelName = snapshot.usableTranscriptionModels.first?.selectionKey
    }

    mutating func ensurePromptSelection(firstPromptId: UUID?) {
        if isAIEnhancementEnabled && selectedPromptId == nil {
            selectedPromptId = firstPromptId
        }
    }

    mutating func useCompatibleLanguage(for model: any TranscriptionModel) {
        selectedLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(
            selectedLanguage ?? "en",
            for: model,
            realtimeEnabled: isRealtimeTranscriptionEnabled
        )
    }

    mutating func applyOutputRules(canRespond: Bool) {
        if outputMode == .respond && !canRespond {
            outputMode = .paste
        }

        if outputMode != .paste {
            autoSendKey = .none
        }

        if outputMode == .respond {
            isDefault = false
        }
    }

    func makeConfig(mode: ConfigurationMode) -> ModeConfig {
        let savedAutoSendKey: FinishAndSendKey = outputMode == .paste ? autoSendKey : .none
        let savedIsDefault = outputMode == .respond ? false : isDefault
        let savedCustomCommand = makeCustomCommand()

        switch mode {
        case .add:
            var config = ModeConfig(
                id: id,
                name: name,
                icon: icon,
                appConfigs: appConfigs.isEmpty ? nil : appConfigs,
                urlConfigs: websiteConfigs.isEmpty ? nil : websiteConfigs,
                triggerGroups: triggerGroups.isEmpty ? nil : triggerGroups,
                triggerWords: triggerWords,
                isAIEnhancementEnabled: isAIEnhancementEnabled,
                selectedPrompt: selectedPromptId?.uuidString,
                selectedTranscriptionModelName: selectedTranscriptionModelName,
                isRealtimeTranscriptionEnabled: isRealtimeTranscriptionEnabled,
                selectedLanguage: selectedLanguage,
                useClipboardContext: useClipboardContext,
                useSelectedTextContext: useSelectedTextContext,
                useScreenCapture: useScreenCapture,
                isTextFormattingEnabled: isTextFormattingEnabled,
                selectedAIProvider: selectedAIProvider,
                selectedAIModel: selectedAIModel,
                outputMode: outputMode,
                autoSendKey: savedAutoSendKey,
                customCommand: savedCustomCommand,
                isDefault: savedIsDefault
            )
            config.translationTargetLanguage = translationTargetLanguage
            return config

        case .edit(let config):
            var updatedConfig = sourceConfig ?? config
            updatedConfig.name = name
            updatedConfig.icon = icon
            updatedConfig.appConfigs = appConfigs.isEmpty ? nil : appConfigs
            updatedConfig.urlConfigs = websiteConfigs.isEmpty ? nil : websiteConfigs
            updatedConfig.triggerGroups = triggerGroups.isEmpty ? nil : triggerGroups
            updatedConfig.triggerWords = ModeConfig.normalizedTriggerWords(triggerWords)
            updatedConfig.isAIEnhancementEnabled = isAIEnhancementEnabled
            updatedConfig.selectedPrompt = selectedPromptId?.uuidString
            updatedConfig.selectedTranscriptionModelName = selectedTranscriptionModelName
            updatedConfig.isRealtimeTranscriptionEnabled = isRealtimeTranscriptionEnabled
            updatedConfig.selectedLanguage = selectedLanguage
            updatedConfig.isTextFormattingEnabled = isTextFormattingEnabled
            updatedConfig.useClipboardContext = useClipboardContext
            updatedConfig.useSelectedTextContext = useSelectedTextContext
            updatedConfig.useScreenCapture = useScreenCapture
            updatedConfig.selectedAIProvider = selectedAIProvider
            updatedConfig.selectedAIModel = selectedAIModel
            updatedConfig.translationTargetLanguage = translationTargetLanguage
            updatedConfig.outputMode = outputMode
            updatedConfig.autoSendKey = savedAutoSendKey
            updatedConfig.customCommand = savedCustomCommand
            updatedConfig.isDefault = savedIsDefault
            return updatedConfig
        }
    }

    private func makeCustomCommand() -> ModeCustomCommand? {
        let command = ModeCustomCommand(command: customCommand)
        return command.trimmedCommand == nil ? nil : command
    }
}
