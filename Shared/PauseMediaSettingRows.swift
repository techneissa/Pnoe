import AppKit
import SwiftUI

/// The "Pause Media While Recording" switch with its help text, and the note that appears when macOS has not
/// granted the System Audio Recording permission and the switch turned itself off. Lives apart from the audio
/// settings screen so it can be rendered on its own.
struct PauseMediaSettingRows: View {
    @ObservedObject var playbackController: PlaybackController

    var body: some View {
        Toggle(isOn: $playbackController.isPauseMediaEnabled) {
            Label {
                Text("Pause Media While Recording")
            } icon: {
                Image(
                    systemName: Motion.toggleSymbol(
                        isOn: playbackController.isPauseMediaEnabled, on: "pause.circle.fill", off: "pause.circle")
                )
                .motionSymbolReplace(value: playbackController.isPauseMediaEnabled)
            }
        }

        Text("Does not start music you just paused. Needs the System Audio Recording permission.")
            .font(.caption)
            .foregroundStyle(.secondary)

        if playbackController.needsPermission {
            HStack {
                Label {
                    Text("Pausing media needs the System Audio Recording permission, so it was turned off.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .motionWiggle(when: true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Open System Settings") {
                    NSWorkspace.shared.open(PlaybackController.permissionSettingsURL)
                }
                .controlSize(.small)
            }
            .motionFade()
        }
    }
}
