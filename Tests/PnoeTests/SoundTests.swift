import AVFoundation
import XCTest

/// Headless checks for the sound pickers: settings, migration, the bundled sets and playback through a fake player.
/// Nothing here plays audio; `FakePlayer` records what would have played.
@MainActor
final class SoundTests: XCTestCase {
    private final class FakePlayer: SoundPlaying {
        var played: [PlayableSound] = []
        func play(_ sound: PlayableSound) { played.append(sound) }
    }

    private let suiteName = "PnoeSoundTests-\(UUID().uuidString)"
    private var defaults = UserDefaults.standard
    private var soundsBundle = Bundle.main

    private var tempDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        // The sets as they sit in the source tree, the folder Xcode copies into the app bundle.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        soundsBundle = try XCTUnwrap(Bundle(url: root.appendingPathComponent("Pnoe/Resources/Sounds", isDirectory: true)))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func makeSettings(systemSounds: [String] = ["Glass", "Ping", "Submarine", "Tink"]) -> SoundSettings {
        SoundSettings(
            defaults: defaults,
            customSoundsDirectory: tempDirectory.appendingPathComponent("Custom"),
            availableSystemSounds: { systemSounds }
        )
    }

    // MARK: - Defaults

    func testDefaultSelection() {
        let settings = makeSettings()
        XCTAssertEqual(settings.choice(for: .start), .pnoe(.kalimba))
        XCTAssertEqual(settings.choice(for: .stop), .pnoe(.feltPiano))
        XCTAssertEqual(settings.choice(for: .cancel), .pnoe(.wood))
        XCTAssertEqual(settings.choice(for: .error), .pnoe(.glass))
        XCTAssertTrue(SoundEvent.allCases.allSatisfy { settings.isDefault(for: $0) })
    }

    func testChoicesAreIndependentAndPersist() {
        let settings = makeSettings()
        settings.select(.pnoe(.drop), for: .start)
        settings.select(.system("Tink"), for: .stop)
        settings.select(.none, for: .cancel)

        let reloaded = makeSettings()
        XCTAssertEqual(reloaded.choice(for: .start), .pnoe(.drop))
        XCTAssertEqual(reloaded.choice(for: .stop), .system("Tink"))
        XCTAssertEqual(reloaded.choice(for: .cancel), .none)
        XCTAssertEqual(reloaded.choice(for: .error), .pnoe(.glass))
    }

    func testStorageValueRoundTrip() {
        let choices: [SoundChoice] =
            [.none, .custom, .system("Glass")] + PnoeSoundSet.allCases.map { SoundChoice.pnoe($0) }
        for choice in choices {
            XCTAssertEqual(SoundChoice(storageValue: choice.storageValue), choice)
        }
        XCTAssertNil(SoundChoice(storageValue: "pnoe:retired-set"))
        XCTAssertNil(SoundChoice(storageValue: "sound3"))
    }

    func testCustomChoiceWithoutFileFallsBackToDefault() {
        defaults.set("custom", forKey: SoundEvent.start.choiceKey)
        XCTAssertEqual(makeSettings().choice(for: .start), .pnoe(.kalimba))

        let settings = makeSettings()
        settings.select(.custom, for: .stop)
        XCTAssertEqual(settings.choice(for: .stop), .pnoe(.feltPiano))
    }

    func testMissingSystemSoundResetsToDefaultOnLoad() {
        defaults.set("system:Gone", forKey: SoundEvent.start.choiceKey)
        defaults.set("system:Tink", forKey: SoundEvent.stop.choiceKey)

        let settings = makeSettings()
        XCTAssertEqual(settings.choice(for: .start), .pnoe(.kalimba))
        XCTAssertEqual(defaults.string(forKey: SoundEvent.start.choiceKey), "pnoe:kalimba")
        XCTAssertEqual(settings.choice(for: .stop), .system("Tink"))
        XCTAssertEqual(makeSettings(systemSounds: []).choice(for: .stop), .pnoe(.feltPiano))
    }

    // MARK: - Migration

    func testVoiceInkSoundsMoveToDefaults() {
        defaults.set("builtIn", forKey: "selectedStartSoundSelection")
        defaults.set("sound2", forKey: "selectedStartBuiltInSound")
        defaults.set("builtIn", forKey: "selectedStopSoundSelection")
        defaults.set("sound7", forKey: "selectedStopBuiltInSound")

        let settings = makeSettings()
        for event in SoundEvent.allCases {
            XCTAssertEqual(settings.choice(for: event), event.defaultChoice)
        }
        for key in ["selectedStartSoundSelection", "selectedStartBuiltInSound", "selectedStopSoundSelection",
                    "selectedStopBuiltInSound"] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
    }

    func testMigrationKeepsNoneAndCustom() {
        defaults.set("none", forKey: "selectedStartSoundSelection")
        defaults.set("custom", forKey: "selectedStopSoundSelection")
        defaults.set("CustomStopSound.wav", forKey: SoundEvent.stop.customFilenameKey)

        let settings = makeSettings()
        XCTAssertEqual(settings.choice(for: .start), .none)
        XCTAssertEqual(settings.choice(for: .stop), .custom)
        XCTAssertEqual(settings.customFilename(for: .stop), "CustomStopSound.wav")
        XCTAssertEqual(settings.choice(for: .cancel), .pnoe(.wood))
        XCTAssertEqual(settings.choice(for: .error), .pnoe(.glass))
    }

    func testMigrationFromBothSoundsOffKeepsCancelAndErrorOff() {
        defaults.set("none", forKey: "selectedStartSoundSelection")
        defaults.set("none", forKey: "selectedStopSoundSelection")

        let settings = makeSettings()
        XCTAssertTrue(SoundEvent.allCases.allSatisfy { settings.choice(for: $0) == .none })
        XCTAssertFalse(settings.hasAnySoundEnabled)
    }

    func testMigrationHonoursTheOldFeedbackSwitch() {
        defaults.set(false, forKey: "isSoundFeedbackEnabled")
        XCTAssertFalse(makeSettings().hasAnySoundEnabled)
    }

    func testMigrationRunsOnceAndKeepsLaterChanges() {
        defaults.set("builtIn", forKey: "selectedStartSoundSelection")
        makeSettings().select(.system("Ping"), for: .start)

        XCTAssertEqual(makeSettings().choice(for: .start), .system("Ping"))
    }

    // MARK: - The bundled sets

    func testEverySetHasAllFourEventsAsPlayableAudio() throws {
        let bundle = soundsBundle
        for set in PnoeSoundSet.allCases {
            for event in SoundEvent.allCases {
                let url = try XCTUnwrap(set.url(for: event, in: bundle), "\(set.rawValue) has no \(event.rawValue) sound")
                let file = try AVAudioFile(forReading: url)
                let seconds = Double(file.length) / file.processingFormat.sampleRate
                XCTAssertGreaterThan(seconds, 0.05, url.lastPathComponent)
                XCTAssertLessThan(seconds, 0.5, url.lastPathComponent)
            }
        }
    }

    func testVoiceInkSoundsAreGone() {
        let bundle = soundsBundle
        for number in 1...7 {
            XCTAssertNil(bundle.url(forResource: "sound\(number)", withExtension: "wav"))
            XCTAssertNil(bundle.url(forResource: "sound\(number)", withExtension: "mp3"))
        }
    }

    // MARK: - Apple's sounds

    func testSystemSoundListSkipsMissingFilesAndFolders() throws {
        let directory = tempDirectory.appendingPathComponent("System", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in ["Pop.aiff", "Basso.aiff", "Glass.aiff", "notes.txt"] {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(file).path, contents: Data())
        }

        XCTAssertEqual(SystemSounds.available(in: directory), ["Basso", "Glass", "Pop"])
        XCTAssertEqual(SystemSounds.available(in: tempDirectory.appendingPathComponent("Missing")), [])
    }

    func testSystemSoundNamedLikeAPnoeSetSaysWhereItComesFrom() {
        XCTAssertEqual(SystemSounds.displayName(for: "Glass"), "Glass (macOS)")
        XCTAssertEqual(SystemSounds.displayName(for: "Tink"), "Tink")
    }

    // MARK: - Playback

    func testNoneChoicePlaysNothing() {
        let settings = makeSettings()
        let player = FakePlayer()
        let manager = SoundManager(settings: settings, player: player, bundle: soundsBundle)

        for event in SoundEvent.allCases {
            settings.select(.none, for: event)
            manager.play(event)
        }
        XCTAssertTrue(player.played.isEmpty)
    }

    func testDefaultsPlayTheirSetFileForTheirEvent() {
        let player = FakePlayer()
        let manager = SoundManager(settings: makeSettings(), player: player, bundle: soundsBundle)

        for event in SoundEvent.allCases { manager.play(event) }

        XCTAssertEqual(
            player.played.compactMap { sound -> String? in
                guard case .file(let url, _) = sound else { return nil }
                return url.lastPathComponent
            },
            ["kalimba-start.wav", "felt-piano-stop.wav", "wood-cancel.wav", "glass-error.wav"]
        )
    }

    func testAppleChoicePlaysBySystemName() {
        let settings = makeSettings()
        let player = FakePlayer()
        let manager = SoundManager(settings: settings, player: player, bundle: soundsBundle)

        settings.select(.system("Submarine"), for: .error)
        manager.play(.error)

        XCTAssertEqual(player.played, [.system(name: "Submarine", volume: SoundManager.systemVolume)])
    }

    func testCustomChoicePlaysTheImportedFile() async throws {
        let settings = makeSettings()
        let player = FakePlayer()
        let manager = SoundManager(settings: settings, player: player, bundle: soundsBundle)
        let source = try XCTUnwrap(PnoeSoundSet.sine.url(for: .start, in: soundsBundle))

        let result = await settings.setCustomSound(url: source, for: .cancel)
        guard case .success = result else { return XCTFail("import failed: \(result)") }
        manager.play(.cancel)

        XCTAssertEqual(settings.choice(for: .cancel), .custom)
        XCTAssertEqual(settings.customFilename(for: .cancel), "CustomCancelSound.wav")
        XCTAssertEqual(player.played, [.file(try XCTUnwrap(settings.customSoundURL(for: .cancel)), volume: SoundManager.fileVolume)])
    }

    func testImportingAnotherFormatDeletesThePreviousCustomFile() async throws {
        let settings = makeSettings()
        let wav = try XCTUnwrap(PnoeSoundSet.sine.url(for: .start, in: soundsBundle))
        let caf = tempDirectory.appendingPathComponent("source.caf")
        let input = try AVAudioFile(forReading: wav)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)))
        try input.read(into: buffer)
        try AVAudioFile(forWriting: caf, settings: input.processingFormat.settings).write(from: buffer)

        let custom = tempDirectory.appendingPathComponent("Custom")
        guard case .success = await settings.setCustomSound(url: wav, for: .cancel) else { return XCTFail("wav import") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: custom.appendingPathComponent("CustomCancelSound.wav").path))

        guard case .success = await settings.setCustomSound(url: caf, for: .cancel) else { return XCTFail("caf import") }
        XCTAssertEqual(settings.customFilename(for: .cancel), "CustomCancelSound.caf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: custom.appendingPathComponent("CustomCancelSound.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: custom.appendingPathComponent("CustomCancelSound.caf").path))
    }
}
