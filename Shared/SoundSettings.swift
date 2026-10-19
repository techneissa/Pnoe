import AVFoundation
import Foundation

/// The sound picked for each event, plus the audio file the user imported for it.
@MainActor
final class SoundSettings: ObservableObject {
    static let shared = SoundSettings()

    private static let maxSoundDuration: TimeInterval = 3.0

    @Published private(set) var choices: [SoundEvent: SoundChoice]
    @Published private var customFilenames: [SoundEvent: String]

    private let defaults: UserDefaults
    private let customSoundsDirectory: URL?

    init(
        defaults: UserDefaults = .standard,
        customSoundsDirectory: URL? = SoundSettings.defaultCustomSoundsDirectory
    ) {
        self.defaults = defaults
        self.customSoundsDirectory = customSoundsDirectory

        Self.migrateLegacySelections(in: defaults)

        var filenames: [SoundEvent: String] = [:]
        for event in SoundEvent.allCases {
            if let filename = defaults.string(forKey: event.customFilenameKey) {
                filenames[event] = filename
            }
        }
        var loaded: [SoundEvent: SoundChoice] = [:]
        for event in SoundEvent.allCases {
            let stored = defaults.string(forKey: event.choiceKey).flatMap(SoundChoice.init(storageValue:))
            if let stored, stored != .custom || filenames[event] != nil {
                loaded[event] = stored
            } else {
                loaded[event] = event.defaultChoice
            }
        }
        self.customFilenames = filenames
        self.choices = loaded

        if let customSoundsDirectory {
            try? FileManager.default.createDirectory(at: customSoundsDirectory, withIntermediateDirectories: true)
        }
    }

    nonisolated static var defaultCustomSoundsDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Pnoe/CustomSounds")
    }

    // MARK: - Reading

    func choice(for event: SoundEvent) -> SoundChoice {
        choices[event] ?? event.defaultChoice
    }

    func customFilename(for event: SoundEvent) -> String? {
        customFilenames[event]
    }

    func customSoundURL(for event: SoundEvent) -> URL? {
        guard let filename = customFilenames[event] else { return nil }
        return customSoundsDirectory?.appendingPathComponent(filename)
    }

    func isDefault(for event: SoundEvent) -> Bool {
        choice(for: event) == event.defaultChoice
    }

    var hasAnySoundEnabled: Bool {
        SoundEvent.allCases.contains { choice(for: $0) != .none }
    }

    // MARK: - Changing

    func select(_ choice: SoundChoice, for event: SoundEvent) {
        if choice == .custom, customFilenames[event] == nil { return }
        choices[event] = choice
        defaults.set(choice.storageValue, forKey: event.choiceKey)
    }

    func resetToDefault(for event: SoundEvent) {
        select(event.defaultChoice, for: event)
    }

    /// Copies the file into the custom sounds folder and selects it for the event.
    func setCustomSound(url: URL, for event: SoundEvent) async -> Result<Void, CustomSoundError> {
        if case .failure(let error) = await Self.validateAudioFile(url: url) {
            return .failure(error)
        }

        switch copySoundFile(from: url, standardName: event.customStandardName) {
        case .success(let filename):
            customFilenames[event] = filename
            defaults.set(filename, forKey: event.customFilenameKey)
            select(.custom, for: event)
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    // MARK: - Migration

    /// VoiceInk's seven sounds are gone. A stored VoiceInk sound moves to the new default for that event;
    /// "none" and a custom file stay as they were. Cancel and error had no setting before, so they follow
    /// the old start and stop: silent only when both were off.
    nonisolated static func migrateLegacySelections(in defaults: UserDefaults) {
        let needsMigration = SoundEvent.allCases.contains { defaults.object(forKey: $0.choiceKey) == nil }
        guard needsMigration else { return }

        let legacySoundFeedback = defaults.object(forKey: "isSoundFeedbackEnabled").map { _ in
            defaults.bool(forKey: "isSoundFeedbackEnabled")
        }

        var legacy: [SoundEvent: SoundChoice] = [:]
        for event in [SoundEvent.start, .stop] {
            let selectionKey = "selected\(event.rawValue.capitalized)SoundSelection"
            switch defaults.string(forKey: selectionKey) {
            case "none":
                legacy[event] = SoundChoice.none
            case "custom" where defaults.string(forKey: event.customFilenameKey) != nil:
                legacy[event] = .custom
            case nil where legacySoundFeedback == false:
                legacy[event] = SoundChoice.none
            default:
                legacy[event] = event.defaultChoice
            }
        }
        let silent = legacy[.start] == SoundChoice.none && legacy[.stop] == SoundChoice.none

        for event in SoundEvent.allCases where defaults.object(forKey: event.choiceKey) == nil {
            let choice = legacy[event] ?? (silent ? SoundChoice.none : event.defaultChoice)
            defaults.set(choice.storageValue, forKey: event.choiceKey)
        }

        for event in [SoundEvent.start, .stop] {
            let capitalized = event.rawValue.capitalized
            defaults.removeObject(forKey: "selected\(capitalized)SoundSelection")
            defaults.removeObject(forKey: "selected\(capitalized)BuiltInSound")
        }
    }

    // MARK: - Files

    private func copySoundFile(from sourceURL: URL, standardName: String) -> Result<String, CustomSoundError> {
        guard let directory = customSoundsDirectory else {
            return .failure(.directoryCreationFailed)
        }

        let newFilename = "\(standardName).\(sourceURL.pathExtension)"
        let destinationURL = directory.appendingPathComponent(newFilename)

        if sourceURL.resolvingSymlinksInPath() == destinationURL.resolvingSymlinksInPath() {
            return .success(newFilename)
        }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return .success(newFilename)
        } catch {
            return .failure(.fileCopyFailed)
        }
    }

    private static func validateAudioFile(url: URL) async -> Result<Void, CustomSoundError> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.fileNotFound)
        }

        do {
            _ = try AVAudioPlayer(contentsOf: url)
        } catch {
            return .failure(.invalidAudioFile)
        }

        let duration: TimeInterval
        do {
            duration = try await AVAsset(url: url).load(.duration).seconds
        } catch {
            return .failure(.invalidAudioFile)
        }

        guard duration.isFinite && duration > 0 else {
            return .failure(.invalidAudioFile)
        }

        if duration > maxSoundDuration {
            return .failure(.durationTooLong(duration: duration, maxDuration: maxSoundDuration))
        }

        return .success(())
    }
}

enum CustomSoundError: LocalizedError {
    case fileNotFound
    case invalidAudioFile
    case durationTooLong(duration: TimeInterval, maxDuration: TimeInterval)
    case directoryCreationFailed
    case fileCopyFailed

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return String(localized: "Audio file not found")
        case .invalidAudioFile:
            return String(localized: "Invalid audio file format")
        case .durationTooLong(let duration, let maxDuration):
            return String(
                format: String(
                    localized:
                        "Audio file is %.1f seconds long. Please use an audio file that is %.0f seconds or shorter for start, stop, cancel and error sounds."
                ), duration, maxDuration)
        case .directoryCreationFailed:
            return String(localized: "Failed to create custom sounds directory")
        case .fileCopyFailed:
            return String(localized: "Failed to copy audio file")
        }
    }
}
