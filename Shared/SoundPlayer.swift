import AVFoundation
import AppKit
import Foundation
import os

/// A sound ready to play: a file, or a macOS sound by name.
enum PlayableSound: Equatable {
    case file(URL, volume: Float)
    case system(name: String, volume: Float)
}

/// The one call `SoundManager` makes to make noise. Tests swap in a fake that records it.
@MainActor
protocol SoundPlaying: AnyObject {
    func play(_ sound: PlayableSound)
}

@MainActor
final class AppSoundPlayer: SoundPlaying {
    private struct CachedPlayer {
        let player: AVAudioPlayer
        let modified: Date?
    }

    private let logger = Logger(subsystem: "com.techneissa.pnoe", category: "SoundPlayer")
    private var filePlayers: [URL: CachedPlayer] = [:]

    func play(_ sound: PlayableSound) {
        switch sound {
        case .file(let url, let volume):
            guard let player = filePlayer(for: url) else { return }
            player.volume = volume
            player.currentTime = 0
            player.play()
        case .system(let name, let volume):
            guard let systemSound = NSSound(named: NSSound.Name(name)) else {
                logger.error("System sound not found: \(name, privacy: .public)")
                return
            }
            systemSound.stop()
            systemSound.volume = volume
            systemSound.play()
        }
    }

    private func filePlayer(for url: URL) -> AVAudioPlayer? {
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let cached = filePlayers[url], cached.modified == modified {
            return cached.player
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            filePlayers[url] = CachedPlayer(player: player, modified: modified)
            return player
        } catch {
            logger.error("Failed to load sound: \(error, privacy: .public)")
            return nil
        }
    }
}
