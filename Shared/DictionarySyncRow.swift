import SwiftUI

/// The "Sync through iCloud Drive" rows of the Dictionary settings: the switch with its info button, and
/// under it, while the switch is on, where the sync is. The info button is passed in so the rows have no
/// dependency on the app's design system and can be rendered on their own.
struct DictionarySyncRow<InfoButton: View>: View {
    @Binding var isOn: Bool
    let status: DictionarySyncStatus
    let symbolPhase: MotionPhase
    @ViewBuilder var infoButton: InfoButton

    var body: some View {
        Group {
            HStack(spacing: 4) {
                Toggle("Sync through iCloud Drive", isOn: $isOn)
                infoButton
            }

            if isOn {
                statusRow
                    .motionFade()
            }
        }
        .motion(.reveal, value: isOn)
    }

    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(symbolPhase == .failed ? Color.orange : Color.secondary)
                .frame(width: 18)
                .motionJobSymbol(symbolPhase)

            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                if showsLastSync, let lastSyncAt = status.lastSyncAt {
                    Text("Last synced \(lastSyncAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        Motion.symbol(for: symbolPhase, idle: "icloud", running: "arrow.triangle.2.circlepath.icloud")
    }

    private var message: LocalizedStringKey {
        switch status.phase {
        case .off, .idle:
            if let lastSyncAt = status.lastSyncAt {
                return "Last synced \(lastSyncAt.formatted(date: .abbreviated, time: .shortened))"
            }
            return "Not synced yet"
        case .syncing:
            return "Syncing…"
        case .driveOff:
            return "iCloud Drive is off. Pnoe will try again."
        case .waitingForDownload:
            return "Waiting for iCloud Drive to download the sync file."
        case .unreadable:
            return "The sync file can't be read, so Pnoe left it as it is."
        case .failed:
            return "Pnoe couldn't sync. It will try again."
        }
    }

    /// The idle message already says it; the others add it on a second line.
    private var showsLastSync: Bool {
        switch status.phase {
        case .driveOff, .waitingForDownload, .unreadable, .failed: return true
        case .off, .idle, .syncing: return false
        }
    }
}
