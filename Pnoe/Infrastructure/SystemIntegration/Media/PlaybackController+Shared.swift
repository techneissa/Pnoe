extension PlaybackController {
    static let shared = PlaybackController(
        resumptionDelay: { MediaController.shared.audioResumptionDelay },
        levelMeter: ProcessTapLevelMeter()
    )
}
