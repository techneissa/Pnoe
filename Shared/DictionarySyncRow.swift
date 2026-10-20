import SwiftUI

/// The "Sync file" rows of the Dictionary settings: the chosen file with a Choose menu, and under it the
/// result of the last sync with the Sync now button. The info button is passed in so the rows have no
/// dependency on the app's design system and can be rendered on their own.
struct DictionarySyncRow<InfoButton: View>: View {
    let file: DictionarySyncFileDescription?
    let result: DictionarySyncResultLine?
    let isWorking: Bool
    let canSync: Bool
    let symbolPhase: MotionPhase
    var now: Date = Date()
    let chooseExisting: () -> Void
    let chooseNew: () -> Void
    let syncNow: () -> Void
    let cancel: () -> Void
    @ViewBuilder var infoButton: InfoButton

    var body: some View {
        Group {
            LabeledContent {
                HStack(spacing: 10) {
                    fileText
                    Menu("Choose…") {
                        Button("Use an Existing File…", action: chooseExisting)
                        Button("Create a New File…", action: chooseNew)
                    }
                    .fixedSize()
                    .disabled(isWorking)
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Sync file")
                    infoButton
                }
            }

            HStack(spacing: 8) {
                statusLabel
                Spacer(minLength: 8)
                if isWorking {
                    Button("Cancel", action: cancel)
                }
                Button("Sync now", action: syncNow)
                    .disabled(!canSync)
            }
        }
    }

    @ViewBuilder
    private var fileText: some View {
        if let file {
            VStack(alignment: .trailing, spacing: 1) {
                Text(file.name)
                Text(file.folder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
        } else {
            Text("No file chosen")
                .foregroundStyle(.secondary)
        }
    }

    private var statusLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: Motion.symbol(for: symbolPhase, idle: "arrow.triangle.2.circlepath"))
                .foregroundStyle(symbolPhase == .failed ? Color.red : Color.secondary)
                .frame(width: 18)
                .motionJobSymbol(symbolPhase)
            Text(statusText)
                .foregroundStyle(isFailure ? Color.red : Color.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var isFailure: Bool {
        if case .failure = result?.kind { return !isWorking }
        return false
    }

    private var statusText: String {
        if isWorking { return String(localized: "Syncing…") }
        guard file != nil else { return String(localized: "Choose a file to sync with.") }
        guard let result else { return String(localized: "Not synced yet") }
        let when = Self.relative(result.at, now: now)
        switch result.kind {
        case .success(let added, let updated, let removed):
            return String(localized: "Added \(added), updated \(updated), removed \(removed)") + " · " + when
        case .cancelled:
            return String(localized: "Cancelled") + " · " + when
        case .failure(let reason):
            return reason
        }
    }

    static func relative(_ date: Date, now: Date) -> String {
        if abs(now.timeIntervalSince(date)) < 60 { return String(localized: "just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// The question before a pass removes entries on this Mac.
struct DictionarySyncReviewSheet: View {
    let review: DictionarySyncReview
    let onRemove: () -> Void
    let onKeep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(review.count == 1 ? "Remove 1 entry?" : "Remove \(review.count) entries?")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text(
                    review.count == 1
                        ? "This will remove 1 entry deleted on another Mac:"
                        : "This will remove \(review.count) entries deleted on another Mac:"
                )
                .foregroundStyle(.secondary)
                ForEach(Array(review.sampleNames.enumerated()), id: \.offset) { _, name in
                    Text("• " + name).lineLimit(1).truncationMode(.tail)
                }
                if review.moreCount > 0 {
                    Text("and \(review.moreCount) more").foregroundStyle(.secondary)
                }
            }

            Text("Keep them to leave them here and put them back into the sync file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Remove", action: onRemove)
                Button("Keep Them", action: onKeep)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
