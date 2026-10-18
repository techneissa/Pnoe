import Foundation

/// What the processes with audio running say about media: which known players are playing, and whether
/// a call is going on. Pnoe only touches the media key when a known player is playing and no call is.
struct MediaApplications: Sendable {
    /// Bundle IDs of known media players. A process matches if its bundle ID is one of these or starts with one
    /// followed by a dot, which covers helper processes (`com.google.Chrome.helper`).
    let players: [String]
    /// Bundle IDs of known calling apps, matched the same way.
    let callApps: [String]

    static let standard = MediaApplications(
        players: [
            // Players
            "com.apple.Music",
            "com.spotify.client",
            "com.apple.podcasts",
            "com.apple.TV",
            "com.apple.QuickTimePlayerX",
            "org.videolan.vlc",
            "com.colliderli.iina",
            // Browsers. Safari plays audio in the shared WebKit GPU process, which any WebKit-based app also uses.
            "com.apple.Safari",
            "com.apple.WebKit.GPU",
            "com.google.Chrome",
            "company.thebrowser.Browser",
            "org.mozilla.firefox",
            "org.mozilla.plugincontainer",
            "com.microsoft.edgemac",
            "com.brave.Browser",
        ],
        callApps: [
            "com.apple.FaceTime",
            "com.apple.avconferenced",
            "us.zoom",
            "com.microsoft.teams",
            "com.microsoft.teams2",
            "com.tinyspeck.slackmacgap",
            "com.hnc.Discord",
            "com.cisco.webexmeetingsapp",
            "com.webex",
            "Cisco-Systems.Spark",
            "com.skype.skype",
        ]
    )

    /// What the processes in `processes` add up to.
    struct Activity: Equatable {
        /// Processes of known players that have output running.
        var playingProcessIDs: Set<pid_t> = []
        /// A known calling app has audio running, or some process has input and output running at once.
        /// That also catches a call in a browser tab, which no bundle ID can tell apart from a video.
        var isCallActive = false
    }

    func activity(in processes: [AudioProcess]) -> Activity {
        var activity = Activity()
        for process in processes {
            if matches(process.bundleID, callApps) || (process.isRunningInput && process.isRunningOutput) {
                activity.isCallActive = true
            } else if process.isRunningOutput, matches(process.bundleID, players) {
                activity.playingProcessIDs.insert(process.pid)
            }
        }
        return activity
    }

    private func matches(_ bundleID: String, _ identifiers: [String]) -> Bool {
        identifiers.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }
}
