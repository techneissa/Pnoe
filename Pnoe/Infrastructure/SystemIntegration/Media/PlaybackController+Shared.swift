extension PlaybackController {
    static let shared = PlaybackController(
        resumptionDelay: { MediaController.shared.audioResumptionDelay },
        levelMeter: ProcessTapLevelMeter(),
        isStartSoundOn: { SoundManager.shared.playableSound(for: .start) != nil }
    )
}
