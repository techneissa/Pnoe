import SwiftUI

private struct DictionaryTransferAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct DictionarySettingsPanel: View {
    @Environment(\.modelContext) private var modelContext

    let onDismiss: () -> Void
    let onReviewNow: () -> Void
    @AppStorage(AutoLearnSettings.isEnabledKey) private var isAutoLearnDictionaryEnabled = true
    @AppStorage(AutoLearnSettings.reviewScheduleKey)
    private var reviewScheduleRawValue = AutoLearnReviewSchedule.immediately.rawValue
    @AppStorage(AutoLearnSettings.repeatThresholdKey)
    private var repeatThresholdRawValue = AutoLearnRepeatThreshold.default.rawValue
    @AppStorage(AutoLearnSettings.usesAIReviewKey) private var usesAIReview = false
    @State private var pendingCorrectionCount = 0
    @State private var pendingImport: DictionaryImportPayload?
    @State private var transferAlert: DictionaryTransferAlert?
    @ObservedObject private var driveSync = DictionarySyncController.shared
    @State private var exportFolderName: String?
    @State private var importFileName: String?
    private let exportFolder = RememberedLocation(defaults: .standard, key: DictionaryLocationKeys.exportFolder)
    private let importFile = RememberedLocation(defaults: .standard, key: DictionaryLocationKeys.importFile)

    var body: some View {
        QuickPanelScaffold {
            Form {
                Section {
                    LabeledContent("Quick Add to Dictionary") {
                        ShortcutRecorder(action: .quickAddToDictionary)
                            .controlSize(.small)
                    }
                } header: {
                    Text("Shortcut")
                }

                Section {
                    Toggle("Auto-Learn Dictionary", isOn: $isAutoLearnDictionaryEnabled)
                        .onChange(of: isAutoLearnDictionaryEnabled) { _, isEnabled in
                            Task {
                                await AutoLearnService.shared.settingDidChange(isEnabled: isEnabled)
                            }
                        }

                    if isAutoLearnDictionaryEnabled {
                        AutoLearnRepeatThresholdRow(selection: repeatThreshold) {
                            InfoTip(
                                "Pnoe adds a correction to the dictionary once you have made the same one this many times: the same heard text changed to the same corrected text. A single fix is often a one-off, so two is a safe start."
                            )
                        }

                        HStack(spacing: 4) {
                            Toggle("Review with AI", isOn: $usesAIReview)
                                .onChange(of: usesAIReview) { _, _ in
                                    Task {
                                        await AutoLearnService.shared.reviewScheduleDidChange()
                                    }
                                }
                            InfoTip(
                                "Off by default. When on, a correction that reached the count above is sent to your AI provider, which decides whether to save it. Without it, Pnoe saves the correction as it is."
                            )
                        }

                        // Corrections queued before the count existed still need these controls.
                        if usesAIReview || pendingCorrectionCount > 0 {
                            AutoLearnModelSelectionView()

                            LabeledContent {
                                Picker("", selection: $reviewScheduleRawValue) {
                                    ForEach(AutoLearnReviewSchedule.allCases) { schedule in
                                        Text(schedule.title).tag(schedule.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .onChange(of: reviewScheduleRawValue) { _, _ in
                                    Task {
                                        await AutoLearnService.shared.reviewScheduleDidChange()
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Review corrections")
                                    InfoTip(
                                        "Choose when saved corrections are sent to your AI provider. Manual review keeps them local until you select Review Now."
                                    )
                                }
                            }

                            LabeledContent("Corrections to review") {
                                Text("\(pendingCorrectionCount)")
                                    .foregroundStyle(.secondary)
                            }

                            Button("Review Now") {
                                onReviewNow()
                            }
                            .focusEffectDisabled()
                            .disabled(pendingCorrectionCount == 0)
                        }
                    }
                } header: {
                    AutoLearnSectionHeader()
                }

                // Interim sync between Macs through a file the user chooses (iCloud Drive or any folder),
                // until the CloudKit sync of issue #5 can be built (it needs a paid Apple Developer
                // membership). Hidden where the dictionary store already syncs through CloudKit (signed
                // release builds). Nothing runs by itself: only the Sync now button.
                if DictionarySyncController.isAvailable {
                    Section {
                        DictionarySyncRow(
                            file: driveSync.syncFile,
                            result: driveSync.result,
                            isWorking: driveSync.isWorking,
                            canSync: driveSync.canSync,
                            symbolPhase: driveSync.symbolPhase,
                            chooseExisting: { chooseSyncFile(createNew: false) },
                            chooseNew: { chooseSyncFile(createNew: true) },
                            syncNow: { driveSync.syncNowTapped() },
                            cancel: { driveSync.cancel() }
                        ) {
                            InfoTip(
                                "Pick one file, for example in the Pnoe folder of your iCloud Drive, and pick the same file on your other Macs. Sync now merges your vocabulary, word replacements and snippets with the file, both ways. The newest edit of each entry wins. Before it removes entries that were deleted on another Mac, Pnoe asks. Nothing syncs until you click."
                            )
                        }
                    } header: {
                        Text("Sync")
                    }
                }

                Section {
                    DictionaryTransferRow(
                        title: "Export Dictionary", actionTitle: "Export", rememberedName: exportFolderName,
                        change: changeExportFolder, action: exportDictionary)

                    DictionaryTransferRow(
                        title: "Import Dictionary", actionTitle: "Import", rememberedName: importFileName,
                        change: changeImportFile, action: chooseDictionaryFile)
                } header: {
                    Text("Dictionary Data")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 68, for: .scrollContent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } header: {
            panelHeader
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            refreshRememberedNames()
            await refreshPendingCorrectionCount()
        }
        .sheet(
            item: Binding(
                get: { driveSync.review },
                // Closing the sheet any other way keeps the entries.
                set: { if $0 == nil, driveSync.review != nil { driveSync.answerReview(.keep) } })
        ) { review in
            DictionarySyncReviewSheet(
                review: review,
                onRemove: { driveSync.answerReview(.remove) },
                onKeep: { driveSync.answerReview(.keep) })
        }
        .onReceive(NotificationCenter.default.publisher(for: .autoLearnQueueDidChange)) { _ in
            Task {
                await refreshPendingCorrectionCount()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .autoLearnReviewProposalsDidChange)
        ) { _ in
            Task {
                await refreshPendingCorrectionCount()
            }
        }
        .sheet(item: $pendingImport) { payload in
            DictionaryImportPreviewSheet(
                payload: payload,
                onCancel: {
                    pendingImport = nil
                },
                onImported: { _ in
                    pendingImport = nil
                }
            )
        }
        .alert(item: $transferAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .cancel(Text("OK"))
            )
        }
    }

    private var repeatThreshold: Binding<AutoLearnRepeatThreshold> {
        Binding(
            get: { AutoLearnRepeatThreshold(rawValue: repeatThresholdRawValue) ?? .default },
            set: { repeatThresholdRawValue = $0.rawValue }
        )
    }

    private var panelHeader: some View {
        HStack(spacing: 12) {
            Text("Dictionary Settings")
                .font(.headline)
                .fontWeight(.semibold)

            Spacer()

            AppIconButton(
                systemName: "xmark",
                help: "Close",
                size: 28,
                iconSize: 14,
                cornerRadius: AppTheme.Radius.control,
                action: onDismiss
            )
        }
        .padding(.horizontal, 20)
        .frame(height: QuickPanelMetrics.headerHeight)
    }

    @MainActor
    private func refreshPendingCorrectionCount() async {
        let pending = (try? await AutoLearnService.shared.outstandingReviewCount()) ?? 0
        let proposals = (try? await AutoLearnService.shared.reviewProposalCount()) ?? 0
        pendingCorrectionCount = pending + proposals
    }

    private func refreshRememberedNames() {
        exportFolderName = exportFolder.resolve()?.lastPathComponent
        importFileName = importFile.resolve()?.lastPathComponent
    }

    @MainActor
    private func chooseSyncFile(createNew: Bool) {
        guard let url = DictionaryFilePanelService.chooseSyncFile(createNew: createNew) else { return }
        driveSync.useSyncFile(url)
    }

    @MainActor
    private func changeExportFolder() {
        guard let folder = DictionaryFilePanelService.chooseExportFolder() else { return }
        exportFolder.remember(folder)
        refreshRememberedNames()
    }

    @MainActor
    private func changeImportFile() {
        guard let file = DictionaryFilePanelService.chooseImportFile() else { return }
        importFile.remember(file)
        refreshRememberedNames()
    }

    /// Writes into the remembered folder without a dialog; the first export asks for the folder.
    @MainActor
    private func exportDictionary() {
        do {
            let folder: URL
            if let remembered = exportFolder.resolve() {
                folder = remembered
            } else {
                guard let chosen = DictionaryFilePanelService.chooseExportFolder() else { return }
                exportFolder.remember(chosen)
                folder = chosen
            }
            let archive = try DictionaryImportExportService.makeArchive(modelContext: modelContext)
            let data = try DictionaryImportExportService.encodeArchive(archive)
            let url = try DictionaryTransfer.export(data, toFolder: folder)
            refreshRememberedNames()
            showTransferAlert(
                title: String(localized: "Dictionary Exported"),
                message: String(
                    format: String(localized: "Vocabulary and word replacements were exported to %@ in %@."),
                    url.lastPathComponent, folder.lastPathComponent
                )
            )
        } catch {
            showTransferAlert(
                title: String(localized: "Export Failed"),
                message: error.localizedDescription
            )
        }
    }

    /// Reads the remembered file into the usual preview; the first import asks for the file.
    @MainActor
    private func chooseDictionaryFile() {
        do {
            let file: URL
            if let remembered = importFile.resolve() {
                file = remembered
            } else {
                guard let chosen = DictionaryFilePanelService.chooseImportFile() else { return }
                importFile.remember(chosen)
                file = chosen
                refreshRememberedNames()
            }
            pendingImport = try DictionaryImportExportService.decodeArchiveData(
                try DictionaryTransfer.importData(from: file))
        } catch {
            showTransferAlert(
                title: String(localized: "Import Failed"),
                message: error.localizedDescription
            )
        }
    }

    private func showTransferAlert(title: String, message: String) {
        transferAlert = DictionaryTransferAlert(title: title, message: message)
    }
}
