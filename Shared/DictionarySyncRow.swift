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

/// The question before a pass removes entries on this Mac or has to pick between two versions of an
/// entry. Nothing is written until the user continues; Cancel (or closing it) changes nothing.
struct DictionarySyncReviewSheet: View {
    let review: DictionarySyncReview
    let onContinue: (DictionarySyncAnswer) -> Void
    let onCancel: () -> Void

    @State private var answer = DictionarySyncAnswer()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review before syncing")
                .font(.headline)

            if !review.conflicts.isEmpty {
                conflictSection
            }
            if !review.deletedElsewhere.isEmpty {
                removalSection(
                    review.deletedElsewhere,
                    title: review.deletedElsewhere.count == 1
                        ? "Deleted on another Mac (1 entry)"
                        : "Deleted on another Mac (\(review.deletedElsewhere.count) entries)")
            }
            if !review.notInFile.isEmpty {
                removalSection(
                    review.notInFile,
                    title: review.notInFile.count == 1
                        ? "Not in the sync file, unchanged here for over 90 days (1 entry)"
                        : "Not in the sync file, unchanged here for over 90 days (\(review.notInFile.count) entries)")
            }
            if !review.removals.isEmpty {
                Picker("Entries to remove", selection: $answer.removals) {
                    Text("Keep them").tag(DictionarySyncDeletionChoice.keep)
                    Text("Remove them").tag(DictionarySyncDeletionChoice.remove)
                }
                .pickerStyle(.segmented)
                Text("Keeping puts them back into the sync file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Sync") { onContinue(answer) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var conflictSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                verbatim: review.conflicts.count == 1
                    ? "Changed on both Macs (1 entry)" : "Changed on both Macs (\(review.conflicts.count) entries)"
            )
            .font(.subheadline.weight(.semibold))
            ForEach(Array(review.conflicts.prefix(DictionarySyncReview.sampleSize).enumerated()), id: \.offset) { _, conflict in
                VStack(alignment: .leading, spacing: 1) {
                    Text(conflict.title).lineLimit(1).truncationMode(.tail)
                    Text("This Mac: " + Self.oneLine(conflict.thisMac ?? String(localized: "deleted")))
                        .foregroundStyle(.secondary)
                    Text("Other Mac: " + Self.oneLine(conflict.otherMac ?? String(localized: "deleted")))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            let more = review.conflicts.count - DictionarySyncReview.sampleSize
            if more > 0 {
                Text("and \(more) more").font(.callout).foregroundStyle(.secondary)
            }
            Picker("Which version", selection: $answer.conflicts) {
                Text("Use this Mac's").tag(DictionarySyncConflictChoice.thisMac)
                Text("Use the other Mac's").tag(DictionarySyncConflictChoice.otherMac)
            }
            .pickerStyle(.segmented)
        }
    }

    /// A text with line breaks on one line, so a long snippet still shows its start.
    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private func removalSection(_ removals: [DictionarySyncRemoval], title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title).font(.subheadline.weight(.semibold))
            ForEach(Array(removals.prefix(DictionarySyncReview.sampleSize).enumerated()), id: \.offset) { _, removal in
                Text("• " + removal.title).font(.callout).lineLimit(1).truncationMode(.tail)
            }
            let more = removals.count - DictionarySyncReview.sampleSize
            if more > 0 {
                Text("and \(more) more").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
