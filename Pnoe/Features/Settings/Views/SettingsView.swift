import Carbon.HIToolbox
import Cocoa
import SwiftUI

@MainActor
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var menuBarManager: MenuBarManager
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager
    @EnvironmentObject private var recorderUIManager: RecorderUIManager
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @ObservedObject private var launchAtLoginManager = LaunchAtLoginManager.shared
    @ObservedObject private var mediaController = MediaController.shared
    @ObservedObject private var playbackController = PlaybackController.shared
    @AppStorage(OnboardingSettings.completedV2Key) private var hasCompletedOnboardingV2 = true
    @AppStorage("restoreClipboardAfterPaste") private var restoreClipboardAfterPaste = true
    @AppStorage("clipboardRestoreDelay") private var clipboardRestoreDelay = 2.0
    @AppStorage(PasteMethod.userDefaultsKey) private var pasteMethodRawValue = PasteMethod.standard.rawValue
    @AppStorage(AppAppearancePreference.userDefaultsKey) private var appAppearancePreference = AppAppearancePreference
        .system
    @AppStorage(AppLanguagePreference.userDefaultsKey) private var appLanguagePreference = AppLanguagePreference
        .systemValue
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    @AppStorage(RecorderDisplaySettingsKeys.liveTranscriptSize) private var liveTranscriptSize = LiveTranscriptSize.medium.rawValue
    @AppStorage(RecorderDisplaySettingsKeys.theme) private var recorderTheme = RecorderTheme.dark.rawValue
    @AppStorage(RecorderDisplaySettingsKeys.levelDisplay) private var recorderLevelDisplay = RecorderLevelDisplay.bars.rawValue
    @AppStorage(RecorderDisplaySettingsKeys.display) private var recorderDisplay = RecorderDisplaySelection.active.storedValue
    @AppStorage(RecorderDisplaySettingsKeys.miniPlacement) private var recorderMiniPlacement = MiniRecorderPlacement.bottom.rawValue
    @AppStorage(RecorderDisplaySettingsKeys.visibility) private var recorderVisibility = RecorderVisibility.whileRecording.rawValue
    @AppStorage(RecorderSideSlots.storageKey(for: .mini)) private var miniSlotsRaw = RecorderSideSlots.defaults(for: .mini).storedValue
    @AppStorage(RecorderSideSlots.storageKey(for: .notch)) private var notchSlotsRaw = RecorderSideSlots.defaults(for: .notch).storedValue
    @AppStorage(RecorderSideSlots.storageKey(for: .pill)) private var pillSlotsRaw = RecorderSideSlots.defaults(for: .pill).storedValue
    @ObservedObject private var modeManager = ModeManager.shared
    @AppStorage(FinishAndSendSettings.key) private var finishAndSendKey = FinishAndSendKey.none.rawValue
    @State private var showResetOnboardingAlert = false
    @State private var showLanguageRestartAlert = false
    @State private var cancelRecordingShortcutRecorderResetID = 0
    @State private var isImportingSettings = false

    @State private var isRestoreClipboardExpanded = false

    /// Connected displays for the picker, plus the chosen one while it is disconnected so the
    /// picker keeps showing the stored choice.
    private var recorderDisplayChoices: [String] {
        var names = RecorderScreenResolver.connectedDisplayNames
        if case .named(let stored) = RecorderDisplaySelection(storedValue: recorderDisplay), !names.contains(stored) {
            names.append(stored)
        }
        return names
    }

    /// The side slots of the chosen style, from the stored value of that style.
    private var recorderSlots: RecorderSideSlots {
        let style = recorderUIManager.recorderPanelStyle
        switch style {
        case .mini: return RecorderSideSlots(storedValue: miniSlotsRaw, style: .mini)
        case .notch: return RecorderSideSlots(storedValue: notchSlotsRaw, style: .notch)
        case .pill: return RecorderSideSlots(storedValue: pillSlotsRaw, style: .pill)
        case .dot: return RecorderSideSlots.defaults(for: .dot)
        }
    }

    private func recorderSlotBinding(_ side: RecorderSlotSide) -> Binding<RecorderSlotContent> {
        Binding(
            get: { recorderSlots.content(on: side) },
            set: { newValue in
                let style = recorderUIManager.recorderPanelStyle
                let updated = recorderSlots.setting(side, to: newValue).storedValue
                switch style {
                case .mini: miniSlotsRaw = updated
                case .notch: notchSlotsRaw = updated
                case .pill: pillSlotsRaw = updated
                case .dot: break
                }
            })
    }

    private var recorderPreviewConfiguration: RecorderStylePreviewConfiguration {
        RecorderStylePreviewConfiguration(
            style: recorderUIManager.recorderPanelStyle,
            theme: RecorderTheme(rawValue: recorderTheme) ?? .dark,
            placement: MiniRecorderPlacement(rawValue: recorderMiniPlacement) ?? .bottom,
            slots: recorderSlots,
            levelDisplay: RecorderLevelDisplay(rawValue: recorderLevelDisplay) ?? .bars,
            showsLiveText: showLiveTranscript,
            transcriptSize: LiveTranscriptSize(rawValue: liveTranscriptSize) ?? .medium,
            modeName: modeManager.currentEffectiveConfiguration?.name ?? String(localized: "None"))
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Primary Shortcut") {
                    HStack(spacing: 8) {
                        Spacer()
                        shortcutModePicker(binding: $recordingShortcutManager.primaryRecordingShortcutMode)
                        ShortcutRecorder(action: .primaryRecording) {
                            recordingShortcutManager.primaryRecordingShortcut = .custom
                            recordingShortcutManager.updateShortcutStatus()
                        }
                        .controlSize(.small)
                    }
                }

                if recordingShortcutManager.secondaryRecordingShortcut != .none {
                    LabeledContent("Secondary Shortcut") {
                        HStack(spacing: 8) {
                            Spacer()
                            shortcutModePicker(binding: $recordingShortcutManager.secondaryRecordingShortcutMode)
                            ShortcutRecorder(action: .secondaryRecording) {
                                recordingShortcutManager.secondaryRecordingShortcut = .custom
                                recordingShortcutManager.updateShortcutStatus()
                            }
                            .controlSize(.small)
                            Button {
                                withAnimation { recordingShortcutManager.secondaryRecordingShortcut = .none }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .focusEffectDisabled()
                    }
                }

                if recordingShortcutManager.secondaryRecordingShortcut == .none {
                    Button("Add Second Shortcut") {
                        withAnimation { recordingShortcutManager.secondaryRecordingShortcut = .custom }
                    }
                    .focusEffectDisabled()
                }

            } header: {
                HStack(spacing: 4) {
                    Text("Shortcuts")
                    InfoTip("Supports keyboard combinations and mouse buttons.")
                }
            }

            Section("Additional Shortcuts") {
                LabeledContent("Paste Last Transcription (Original)") {
                    ShortcutRecorder(action: .pasteLastTranscription) {
                        recordingShortcutManager.updateShortcutStatus()
                    }
                    .controlSize(.small)
                }

                LabeledContent("Paste Last Transcription (Enhanced)") {
                    ShortcutRecorder(action: .pasteLastEnhancement) {
                        recordingShortcutManager.updateShortcutStatus()
                    }
                    .controlSize(.small)
                }

                LabeledContent("Retry Last Transcription") {
                    ShortcutRecorder(action: .retryLastTranscription) {
                        recordingShortcutManager.updateShortcutStatus()
                    }
                    .controlSize(.small)
                }

                LabeledContent {
                    HStack(spacing: 8) {
                        ShortcutRecorder(
                            action: .cancelRecorder,
                            defaultShortcut: Self.defaultCancelRecordingShortcut
                        )
                        .id(cancelRecordingShortcutRecorderResetID)
                        .controlSize(.small)

                        Button {
                            RecorderPanelShortcutManager.resetEscapeConfirmationHint()
                            ShortcutStore.setShortcut(nil, for: .cancelRecorder)
                            cancelRecordingShortcutRecorderResetID += 1
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.plain)
                        .help("Reset to default")
                    }
                    .focusEffectDisabled()
                } label: {
                    HStack(spacing: 2) {
                        Text("Cancel Recording")
                        InfoTip(
                            "The assigned shortcut cancels the recording. Resetting restores the default double-Escape behavior."
                        )
                    }
                }

            }

            Section("Pasting") {
                HStack(spacing: 4) {
                    Picker(selection: $finishAndSendKey) {
                        ForEach(FinishAndSendKey.allCases, id: \.self) { key in
                            Text(key.displayName).tag(key.rawValue)
                        }
                    } label: {
                        Text("Auto Send")
                    }
                    InfoTip("Press Return while recording to stop and deliver the result. Pnoe will then paste the result and press the selected key to send it. Choose None to disable this feature.")
                }

                ExpandableSettingsRow(
                    isExpanded: $isRestoreClipboardExpanded,
                    isEnabled: $restoreClipboardAfterPaste,
                    label: "Keep Clipboard Content",
                    infoMessage:
                        "Default and AppleScript temporarily use the clipboard to paste transcription. When enabled, this restores your previous clipboard content after the selected delay. Direct Typing leaves the clipboard unchanged."
                ) {
                    Picker("Restore Delay", selection: $clipboardRestoreDelay) {
                        Text("250ms").tag(0.25)
                        Text("500ms").tag(0.5)
                        Text("1s").tag(1.0)
                        Text("2s").tag(2.0)
                        Text("3s").tag(3.0)
                        Text("4s").tag(4.0)
                        Text("5s").tag(5.0)
                    }
                }
                .disabled(pasteMethodRawValue == PasteMethod.directTyping.rawValue)

                HStack(spacing: 4) {
                    Picker(selection: $pasteMethodRawValue) {
                        ForEach(PasteMethod.allCases) { method in
                            Text(method.displayName).tag(method.rawValue)
                        }
                    } label: {
                        Text("Paste Method")
                    }
                        .pickerStyle(.menu)
                        .onChange(of: pasteMethodRawValue) { _, newValue in
                            guard let method = PasteMethod(rawValue: newValue) else {
                                pasteMethodRawValue = PasteMethod.standard.rawValue
                                return
                            }
                            PasteMethod.setCurrent(method)
                        }
                    InfoTip(
                        "Default uses Cmd+V. AppleScript offers an alternative way to send Cmd+V. Direct Typing enters text without using the clipboard. Some editors may not support it."
                    )
                }
            }

            Section("Interface") {
                Picker("Appearance", selection: $appAppearancePreference) {
                    ForEach(AppAppearancePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: appAppearancePreference) { _, newValue in
                    newValue.apply()
                }

                Picker("Language", selection: $appLanguagePreference) {
                    ForEach(AppLanguagePreference.availableOptions) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: appLanguagePreference) { oldValue, newValue in
                    guard oldValue != newValue else { return }
                    let normalizedValue = AppLanguagePreference.normalizedRawValue(newValue)
                    if normalizedValue != newValue {
                        appLanguagePreference = normalizedValue
                        return
                    }
                    AppLanguagePreference.apply(rawValue: normalizedValue)
                    showLanguageRestartAlert = true
                }

                Picker("Recorder Style", selection: $recorderUIManager.recorderPanelStyle) {
                    ForEach(RecorderPanelStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.menu)

                // The real layouts with a made-up input level and sample text, inside this
                // window. It follows every picker below at once.
                RecorderStylePreview(configuration: recorderPreviewConfiguration)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))

                Picker("Recorder Theme", selection: $recorderTheme) {
                    ForEach(RecorderTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Picker("Level Display", selection: $recorderLevelDisplay) {
                    ForEach(RecorderLevelDisplay.allCases) { display in
                        Text(display.displayName).tag(display.rawValue)
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: 4) {
                    Picker(selection: $recorderDisplay) {
                        Text("Active Screen").tag(RecorderDisplaySelection.active.storedValue)
                        Text("Main Screen").tag(RecorderDisplaySelection.main.storedValue)
                        ForEach(recorderDisplayChoices, id: \.self) { name in
                            Text(name).tag(RecorderDisplaySelection.named(name).storedValue)
                        }
                    } label: {
                        Text("Recorder Display")
                    }
                        .pickerStyle(.menu)
                    InfoTip(
                        "The active screen is the one with the focused window. A display that is not connected falls back to the active screen. The Notch style becomes Mini on a built-in display without a notch."
                    )
                }

                if recorderUIManager.recorderPanelStyle.hasSideSlots {
                    HStack(spacing: 4) {
                        Picker(selection: recorderSlotBinding(.left)) {
                            ForEach(RecorderSlotContent.allCases) { content in
                                Text(content.displayName).tag(content)
                            }
                        } label: {
                            Text("Left Side")
                        }
                            .pickerStyle(.menu)
                        InfoTip(
                            "What the recorder shows on its left and right side. The level meter is in the centre unless you put it on a side; then the centre stays empty. The same item cannot be on both sides. On the Notch the centre is the camera housing, so the level meter sits right beside it. The Pill has no workflow button, so the workflow name is the only way to see the workflow there.")
                    }

                    Picker("Right Side", selection: recorderSlotBinding(.right)) {
                        ForEach(RecorderSlotContent.allCases) { content in
                            Text(content.displayName).tag(content)
                        }
                    }
                    .pickerStyle(.menu)
                }

                HStack(spacing: 4) {
                    Picker(selection: $recorderMiniPlacement) {
                        ForEach(MiniRecorderPlacement.allCases) { placement in
                            Text(placement.displayName).tag(placement.rawValue)
                        }
                    } label: {
                        Text("Position")
                    }
                        .pickerStyle(.menu)
                    InfoTip("Top or bottom of the screen for Mini, Pill and Dot. Notch always hangs from the top edge.")
                }

                Picker("Show Recorder", selection: $recorderVisibility) {
                    ForEach(RecorderVisibility.allCases) { visibility in
                        Text(visibility.displayName).tag(visibility.rawValue)
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: 4) {
                    Toggle("Live Text Display", isOn: $showLiveTranscript)
                    InfoTip("Shows live text while recording with realtime models.")
                }

                Picker("Live Text Size", selection: $liveTranscriptSize) {
                    ForEach(LiveTranscriptSize.allCases) { size in
                        Text(size.displayName).tag(size.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!showLiveTranscript)

                if !recorderUIManager.recorderPanelStyle.showsLiveTranscript {
                    Text("The Dot shows no live text. While the assistant is open it expands to the Pill, which does.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("General") {
                Toggle("Hide Dock Icon", isOn: $menuBarManager.isMenuBarOnly)

                Toggle(
                    String(localized: "Launch at Login"),
                    isOn: Binding(
                        get: { launchAtLoginManager.isEnabled },
                        set: { launchAtLoginManager.setEnabled($0) }
                    )
                )
                .disabled(launchAtLoginManager.isUpdating)

                Button("Reset Onboarding") {
                    showResetOnboardingAlert = true
                }
                .focusEffectDisabled()
            }

            Section {
                LabeledContent("Export Settings") {
                    Button("Export") {
                        Task {
                            await ImportExportService.shared.exportSettings(
                                enhancementService: enhancementService,
                                recordingShortcutManager: recordingShortcutManager,
                                menuBarManager: menuBarManager,
                                mediaController: mediaController,
                                playbackController: playbackController,
                                recorderUIManager: recorderUIManager,
                                modelContext: modelContext
                            )
                        }
                    }
                }
                .focusEffectDisabled()

                LabeledContent("Import Settings") {
                    Button("Import") {
                        guard !isImportingSettings else { return }
                        isImportingSettings = true
                        Task { @MainActor in
                            defer { isImportingSettings = false }
                            await ImportExportService.shared.importSettings(
                                enhancementService: enhancementService,
                                recordingShortcutManager: recordingShortcutManager,
                                menuBarManager: menuBarManager,
                                mediaController: mediaController,
                                playbackController: playbackController,
                                recorderUIManager: recorderUIManager,
                                modelContext: modelContext,
                                transcriptionModelManager: transcriptionModelManager
                            )
                        }
                    }
                    .disabled(isImportingSettings)
                }
                .focusEffectDisabled()
            } header: {
                Text("Backup")
            } footer: {
                Text("Export all settings, or choose specific categories when importing a backup.")
            }

            Section("Diagnostics") {
                DiagnosticsSettingsView()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .alert("Reset Onboarding", isPresented: $showResetOnboardingAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                DispatchQueue.main.async {
                    hasCompletedOnboardingV2 = false
                }
            }
        } message: {
            Text("You'll see the introduction screens again the next time you launch the app.")
        }
        .alert("Restart Pnoe to Apply Language", isPresented: $showLanguageRestartAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your language change will take full effect after you quit and reopen Pnoe.")
        }
    }

    private static let defaultCancelRecordingShortcut = Shortcut.key(
        keyCode: UInt16(kVK_Escape),
        modifierFlags: []
    )

    @ViewBuilder
    private func shortcutModePicker(binding: Binding<RecordingShortcutManager.Mode>) -> some View {
        Picker("", selection: binding) {
            ForEach(RecordingShortcutManager.Mode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

extension Text {
    func settingsDescription() -> some View {
        self
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
