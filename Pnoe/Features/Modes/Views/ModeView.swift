import SwiftData
import SwiftUI

extension View {
    func placeholder<Content: View>(
        when shouldShow: Bool,
        alignment: Alignment = .center,
        @ViewBuilder placeholder: () -> Content
    ) -> some View {

        ZStack(alignment: alignment) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}

enum ConfigurationMode: Hashable {
    case add
    case edit(ModeConfig)

    var isAdding: Bool {
        if case .add = self { return true }
        return false
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .add:
            hasher.combine(0)
        case .edit(let config):
            hasher.combine(1)
            hasher.combine(config.id)
        }
    }

    static func == (lhs: ConfigurationMode, rhs: ConfigurationMode) -> Bool {
        switch (lhs, rhs) {
        case (.add, .add):
            return true
        case (.edit(let lhsConfig), .edit(let rhsConfig)):
            return lhsConfig.id == rhsConfig.id
        default:
            return false
        }
    }
}

enum ConfigurationType {
    case application
    case website
}

struct ModeView: View {
    @StateObject private var modeManager = ModeManager.shared
    @StateObject private var modeWarmupStore = ModeFormWarmupStore.shared
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @State private var activePanel: PanelType?
    @State private var panelID = UUID()
    @State private var playgroundModel: WorkflowPlaygroundModel?

    private enum PanelType {
        case templatePicker
        case configuration(ConfigurationMode, StarterModeTemplate?)
        case settings
        case playground
    }

    private var isPanelOpen: Bool {
        activePanel != nil
    }

    private var isPlaygroundOpen: Bool {
        if case .playground? = activePanel { return true }
        return false
    }

    private var headerControls: some View {
        HStack(spacing: 8) {
            playgroundButton
            addModeButton
            settingsButton
        }
    }

    private var addModeButton: some View {
        AppIconButton(
            systemName: "plus.circle.fill",
            help: "Add a new workflow"
        ) {
            openTemplatePicker()
        }
    }

    private var playgroundButton: some View {
        AppIconButton(
            systemName: "flask.fill",
            help: "Try a workflow on a sample"
        ) {
            openPlayground()
        }
    }

    private var settingsButton: some View {
        AppIconButton(
            systemName: "gearshape.fill",
            help: "Workflows Settings"
        ) {
            openSettingsPanel()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "Workflows",
                infoMessage: "A workflow sets how Pnoe transcribes, enhances and delivers your speech for a task or app."
            ) {
                headerControls
            }

            Group {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(spacing: 0) {
                            if modeManager.configurations.isEmpty {
                                VStack(spacing: 24) {
                                    Spacer()
                                        .frame(height: geometry.size.height * 0.2)

                                    VStack(spacing: 16) {
                                        Image(systemName: "square.grid.2x2.fill")
                                            .font(.system(size: 48, weight: .regular))
                                            .foregroundColor(.secondary.opacity(0.6))

                                        VStack(spacing: 8) {
                                            Text("Create your first workflow")
                                                .font(.system(size: 20, weight: .medium))
                                                .foregroundColor(.primary)

                                            Button("Choose a template") {
                                                openTemplatePicker()
                                            }
                                            .buttonStyle(.link)
                                        }
                                    }

                                    Spacer()
                                }
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: geometry.size.height)
                            } else {
                                VStack(spacing: 0) {
                                    ModeConfigurationsGrid(
                                        modeManager: modeManager,
                                        onEditConfig: { config in
                                            openPanel(mode: .edit(config))
                                        }
                                    )
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 20)

                                    Spacer()
                                        .frame(height: 40)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sidePanel(
            isPresented: .init(
                get: { isPanelOpen },
                set: { if !$0 { closePanel() } }
            ), width: isPlaygroundOpen ? 720 : 400, dismissOnExitCommand: false
        ) {
            switch activePanel {
            case .templatePicker?:
                WorkflowTemplatePickerView(
                    options: StarterModeCatalog.pickerTemplates.map(\.pickerOption),
                    onSelect: { option in
                        let template = StarterModeCatalog.templates.first { $0.id == option?.id }
                        if let template { seedPrompts(for: template) }
                        openPanel(mode: .add, template: template)
                    },
                    onDismiss: closePanel
                )
            case .configuration(let mode, let template)?:
                ModeConfigEditorView(mode: mode, modeManager: modeManager, template: template, onDismiss: closePanel)
                    .environmentObject(modeWarmupStore)
                    .id(panelID)
            case .settings?:
                ModeSettingsPanelView(modeManager: modeManager, onDismiss: closePanel)
            case .playground?:
                if let playgroundModel {
                    WorkflowPlaygroundView(model: playgroundModel, onDismiss: closePanel)
                }
            case nil:
                EmptyView()
            }
        }
        .onAppear {
            modeWarmupStore.configure(
                aiService: aiService,
                enhancementService: enhancementService,
                transcriptionModelManager: transcriptionModelManager
            )
        }
    }

    /// A template's prompt is added to the prompt list the first time the template is used.
    private func seedPrompts(for template: StarterModeTemplate) {
        let seeded = StarterModePromptSeeder.ensurePrompts(for: [template.kind], in: enhancementService.customPrompts)
        if seeded.didChange {
            enhancementService.customPrompts = seeded.prompts
            modeWarmupStore.refreshSnapshot()
        }
    }

    private func openPanel(mode: ConfigurationMode, template: StarterModeTemplate? = nil) {
        panelID = UUID()
        activePanel = .configuration(mode, template)
    }

    private func openTemplatePicker() {
        activePanel = .templatePicker
    }

    private func closePanel() {
        playgroundModel?.cancel()
        activePanel = nil
    }

    private func openPlayground() {
        playgroundModel = makePlaygroundModel()
        activePanel = .playground
    }

    /// The Playground lists the workflows that use AI and runs one on a typed sample through the same
    /// enhancement call a dictation uses, with no pasted-in context and nothing pasted out.
    private func makePlaygroundModel() -> WorkflowPlaygroundModel {
        let configurations = modeManager.configurations
        let enhancementService = enhancementService
        let aiService = aiService
        let workflows: [PlaygroundWorkflow] = configurations.compactMap { config in
            guard config.isAIEnhancementEnabled else { return nil }
            let promptId = config.selectedPrompt.flatMap(UUID.init(uuidString:))
            // The provider and model the workflow itself would use.
            let own = ModeRuntimeResolver.currentEnhancementConfiguration(
                mode: config, enhancementService: enhancementService, aiService: aiService)
            return PlaygroundWorkflow(
                id: config.id, name: config.name,
                template: LocalWorkflowTemplate.template(forPromptId: promptId),
                defaultChoice: own.provider.map {
                    PlaygroundModelChoice(provider: $0.rawValue, model: $0 == .localCLI ? nil : own.modelName)
                })
        }
        // The models the user can run now, from the lists the app already keeps.
        let choices = PlaygroundModelOptions.choices(
            from: aiService.connectedProviders.map { provider in
                PlaygroundModelOptions.Provider(
                    name: provider.rawValue,
                    models: provider == .localCLI ? [] : aiService.availableModels(for: provider),
                    usesDefaultModel: provider == .localCLI)
            })
        return WorkflowPlaygroundModel(workflows: workflows, modelChoices: choices, store: .standard()) {
            text, workflow, choice in
            guard let config = modeManager.getConfiguration(with: workflow.id) else {
                throw EnhancementError.notConfigured
            }
            var runtime = ModeRuntimeResolver.currentEnhancementConfiguration(
                mode: config, enhancementService: enhancementService, aiService: aiService)
            // A model picked in the Playground applies to this run only: a copy of the configuration goes
            // through the same call, so the guards and the fallback are the same.
            if let choice, let provider = AIProvider(rawValue: choice.provider), choice != workflow.defaultChoice {
                runtime = runtime.overriding(provider: provider, modelName: choice.model)
            }
            // The same preparation and the same call dictation uses, so this is what would be pasted.
            let prepared = PreparedTranscript.make(
                config.isTextFormattingEnabled ? ParagraphFormatter.format(text) : text, modelContext: enhancementService.modelContext, respondInRecorder: false)
            guard enhancementService.runsEnhancement(for: prepared, configuration: runtime) else {
                return PlaygroundOutcome(
                    output: prepared.transcript, duration: 0,
                    skippedReason: prepared.skipsEnhancement
                        ? "The take is too short or only snippets, so dictation pastes it without the model."
                        : "AI is not set up for this workflow, so dictation pastes the transcript.")
            }
            do {
                let (result, finalText) = try await enhancementService.enhanceTranscript(prepared, configuration: runtime)
                return PlaygroundOutcome(
                    output: finalText, duration: result.duration, fallbackReason: result.fallbackReason,
                    rejectedText: result.rejectedText)
            } catch {
                throw PlaygroundRunError(message: EnhancementFailureFormatter.description(for: error))
            }
        }
    }

    private func openSettingsPanel() {
        activePanel = .settings
    }
}

struct SectionHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.system(size: 16, weight: .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
    }
}

/// A failed Playground run, worded for the screen.
private struct PlaygroundRunError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
