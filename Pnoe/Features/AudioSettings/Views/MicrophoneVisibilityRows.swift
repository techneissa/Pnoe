import SwiftUI

/// Rows of the "Hide Microphones" section: one per connected input, plus hidden ones that are not
/// connected now, which stay listed so they can be shown again. Style the toggles with `HideToggleStyle`.
struct MicrophoneVisibilityRows: View {
    let rows: [MicrophoneVisibilityRow]
    let allDevicesHidden: Bool
    let setHidden: (MicrophoneVisibilityRow, Bool) -> Void

    var body: some View {
        if allDevicesHidden {
            Label {
                Text("Every microphone is hidden. Pnoe records from the built-in microphone.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        if rows.isEmpty {
            Text("No microphones detected.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(rows) { row in
                Toggle(isOn: Binding(get: { row.isHidden }, set: { setHidden(row, $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .lineLimit(1)
                        if !row.isConnected {
                            Text("Not connected")
                                .font(.caption)
                        }
                    }
                    .foregroundStyle(row.isHidden ? .secondary : .primary)
                    .opacity(row.isHidden ? 0.6 : 1)
                }
            }
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
