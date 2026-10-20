import AppKit
import Foundation
import UniformTypeIdentifiers

/// Owns native file-panel presentation so the archive and import engine stay
/// independent of AppKit and remain directly testable.
@MainActor
enum DictionaryFilePanelService {
    /// A folder for exports.
    static func chooseExportFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.title = String(localized: "Export Dictionary")
        panel.message = String(localized: "Choose the folder Pnoe exports the dictionary to.")
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// The Pnoe dictionary file to import.
    static func chooseImportFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "Import Dictionary")
        panel.message = String(localized: "Choose a Pnoe dictionary JSON file.")
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// The sync file: an existing one, or a new one. The panel opens in the `Pnoe` folder of the iCloud
    /// Drive (or the Drive) when there is one; nothing is created.
    static func chooseSyncFile(createNew: Bool) -> URL? {
        let directory = DictionarySyncFileDescription.suggestedDirectory()
        if createNew {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = DictionarySyncFileDescription.suggestedFileName
            panel.directoryURL = directory
            panel.title = String(localized: "Create Sync File")
            panel.message = String(localized: "Choose where Pnoe keeps the dictionary sync file.")
            return panel.runModal() == .OK ? panel.url : nil
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        panel.title = String(localized: "Choose Sync File")
        panel.message = String(localized: "Choose the dictionary sync file your other Macs use.")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
