import FormatterModels
import SwiftUI

struct ModeConfigEditorView: View {
    let mode: ConfigurationMode
    let modeManager: ModeManager
    let onDismiss: () -> Void

    @EnvironmentObject private var enhancementService: AIEnhancementService
    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject private var modeWarmupStore: ModeFormWarmupStore

    @State private var draft: ModeConfigDraft
    @State private var validationErrors: [ModeValidationError] = []
    @State private var showValidationAlert = false
    @State private var promptEditorMode: PromptEditorView.Mode?
    @State private var promptEditorID = UUID()
    @State private var didSaveConfiguration = false

    init(
        mode: ConfigurationMode,
        modeManager: ModeManager,
        template: StarterModeTemplate? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.mode = mode
        self.modeManager = modeManager
        self.onDismiss = onDismiss
        _draft = State(initialValue: ModeConfigDraft(mode: mode, modeManager: modeManager, template: template))
    }

    var body: some View {
        Group {
            if let promptEditorMode {
                PromptEditorView(
                    mode: promptEditorMode,
                    onDismiss: closePromptEditor,
                    onSave: handlePromptSaved,
                    onDelete: handlePromptDeleted
                )
                .environmentObject(enhancementService)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(promptEditorID)
            } else {
                ModeConfigFormView(
                    mode: mode,
                    modeManager: modeManager,
                    draft: $draft,
                    validationErrors: $validationErrors,
                    showValidationAlert: $showValidationAlert,
                    onDismiss: onDismiss,
                    onSave: saveConfiguration,
                    onDelete: deleteConfiguration,
                    openPromptEditor: openPromptEditor
                )
            }
        }
        .onAppear(perform: prepareView)
        .onDisappear(perform: cleanupUnsavedShortcutIfNeeded)
        .onExitCommand(perform: handleExitCommand)
    }

    private func openPromptEditor(mode: PromptEditorView.Mode) {
        promptEditorID = UUID()
        promptEditorMode = mode
    }

    private func closePromptEditor() {
        promptEditorMode = nil
    }

    private func handlePromptSaved(_ prompt: CustomPrompt) {
        draft.selectedPromptId = prompt.id
        closePromptEditor()
    }

    private func handlePromptDeleted(_ prompt: CustomPrompt) {
        enhancementService.deletePrompt(prompt)
        if draft.selectedPromptId == prompt.id {
            draft.selectedPromptId = enhancementService.allPrompts.first?.id
        }
    }

    private func handleExitCommand() {
        if promptEditorMode != nil {
            closePromptEditor()
        } else {
            onDismiss()
        }
    }

    private func prepareView() {
        modeWarmupStore.configure(
            aiService: aiService,
            enhancementService: enhancementService,
            transcriptionModelManager: transcriptionModelManager
        )

        let snapshot = modeWarmupStore.snapshot

        if case .add = mode {
            draft.applyAddModeDefaults(snapshot: snapshot)
            draft.inheritUsableTranscriptionModelSelection(from: snapshot)
            if let promptId = draft.selectedPromptId, !snapshot.prompts.contains(where: { $0.id == promptId }) {
                draft.selectedPromptId = nil
            }
        } else if let selectedModelName = draft.selectedTranscriptionModelName,
            !snapshot.hasUsableTranscriptionModel(named: selectedModelName)
        {
            draft.selectedTranscriptionModelName = nil
        }

        draft.ensurePromptSelection(firstPromptId: snapshot.firstPromptId)

        if case .add = mode, draft.prefersLocalModel {
            preselectInstalledOllamaModel()
        }

        if let selectedModelName = draft.selectedTranscriptionModelName,
            let model = snapshot.transcriptionModel(named: selectedModelName)
        {
            draft.useCompatibleLanguage(for: model)
        }
    }

    /// A template built for a local model starts on the smallest suitable Gemma or Qwen model Ollama has
    /// already pulled; with Ollama not running, on an installed Built-in model. Nothing is downloaded or
    /// started; with none of either the provider stays as it was.
    private func preselectInstalledOllamaModel() {
        let startingProvider = draft.selectedAIProvider
        let endpoint = URL(string: AIProvider.ollama.baseURL) ?? OllamaModelDiscovery.defaultEndpoint
        Task { @MainActor in
            guard
                let choice = await TemplateProviderPreselection.chooseLocal(
                    ollama: { await OllamaModelDiscovery(endpoint: endpoint).fetch() },
                    builtIn: { await BuiltInModels.installed(chosenFiles: BuiltInEngine.storedChosenFiles()) })
            else { return }
            // Ollama only counts as a connected provider once the app has looked at it.
            if choice.providerName == TemplateProviderPreselection.ollamaProviderName {
                _ = await aiService.refreshOllamaAvailability()
            }
            draft.preselect(choice, startingProvider: startingProvider)
        }
    }

    private func saveConfiguration() {
        let config = draft.makeConfig(mode: mode)
        let validator = ModeValidator(modeManager: modeManager)
        validationErrors = validator.validateForSave(config: config, mode: mode)

        if !validationErrors.isEmpty {
            showValidationAlert = true
            return
        }

        switch mode {
        case .add:
            modeManager.addConfiguration(config)
        case .edit:
            modeManager.updateConfiguration(config)
        }

        didSaveConfiguration = true
        onDismiss()
    }

    private func deleteConfiguration() -> ModeRemovalResult {
        let result = modeManager.removeConfiguration(with: draft.id)
        switch result {
        case .removed, .notFound:
            onDismiss()
        case .blockedDefault:
            break
        }
        return result
    }

    private func cleanupUnsavedShortcutIfNeeded() {
        guard case .add = mode, !didSaveConfiguration else {
            return
        }

        ShortcutStore.removeShortcutStorage(for: .mode(draft.id))
    }
}
