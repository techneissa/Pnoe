import Foundation

/// Plays the sound chosen for an event. Preview buttons and the real recording hooks both call `play(_:)`.
@MainActor
final class SoundManager {
    static let shared = SoundManager(settings: .shared, player: AppSoundPlayer())

    /// Pnoe's sounds are already mastered quiet; macOS alert sounds are louder, so they play at half volume.
    static let fileVolume: Float = 1.0
    static let systemVolume: Float = 0.5

    private let settings: SoundSettings
    private let player: SoundPlaying
    private let bundle: Bundle

    init(settings: SoundSettings, player: SoundPlaying, bundle: Bundle = .main) {
        self.settings = settings
        self.player = player
        self.bundle = bundle
    }

    func play(_ event: SoundEvent) {
        guard let sound = playableSound(for: event) else { return }
        player.play(sound)
    }

    func playableSound(for event: SoundEvent) -> PlayableSound? {
        switch settings.choice(for: event) {
        case .none:
            return nil
        case .pnoe(let set):
            return set.url(for: event, in: bundle).map { .file($0, volume: Self.fileVolume) }
        case .system(let name):
            return .system(name: name, volume: Self.systemVolume)
        case .custom:
            return settings.customSoundURL(for: event).map { .file($0, volume: Self.fileVolume) }
        }
    }
}
