import SwiftUI

/// Rows of the "Hide Microphones" section: one per connected input, plus hidden ones that are not
/// connected now, which stay listed so they can be shown again. Style the toggles with `HideToggleStyle`.
struct MicrophoneVisibilityRows: View {
    let rows: [MicrophoneVisibilityRow]
    /// Set when every connected microphone is hidden: what recording uses instead.
    let allHiddenFallback: AllHiddenFallback?
    let setHidden: (MicrophoneVisibilityRow, Bool) -> Void

    var body: some View {
        if let allHiddenFallback {
            Label {
                Text(Self.allHiddenNotice(allHiddenFallback))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .motionWiggle(when: true)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .motionFade()
        }

        if rows.isEmpty {
            Text("No microphones detected.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(rows) { row in
                Toggle(isOn: Binding(get: { row.isHidden }, set: { setHidden(row, $0) })) {
                    HStack(spacing: 8) {
                        Image(systemName: Motion.toggleSymbol(isOn: row.isHidden, on: "eye.slash", off: "eye"))
                            .frame(width: 18)
                            .motionSymbolReplace(value: row.isHidden)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                                .lineLimit(1)
                            if !row.isConnected {
                                Text("Not connected")
                                    .font(.caption)
                            }
                        }
                    }
                    .foregroundStyle(row.isHidden ? .secondary : .primary)
                    .opacity(row.isHidden ? 0.6 : 1)
                    .motion(.change, value: row.isHidden)
                }
            }
        }
    }
}

extension MicrophoneVisibilityRows {
    static func allHiddenNotice(_ fallback: AllHiddenFallback) -> String {
        switch fallback {
        case .builtInMicrophone:
            return String(localized: "Every microphone is hidden. Pnoe records from the built-in microphone.")
        case .input(let name):
            return String(format: String(localized: "Every microphone is hidden. Pnoe records from %@."), name)
        case .unavailable:
            return String(localized: "Every microphone is hidden, and the built-in microphone is unavailable while the lid is closed.")
        }
    }
}

/// A "Hide" switch at the trailing edge of the row. The settings view applies it to the rows.
struct HideToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
            Spacer()
            Text("Hide")
                .foregroundStyle(.secondary)
            Toggle("Hide", isOn: configuration.$isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
