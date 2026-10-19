import SwiftUI

/// How far a WhisperKit model download is, for the model library row.
struct WhisperKitDownloadProgress: Equatable, Sendable {
    let fraction: Double
    let message: String
    let isIndeterminate: Bool
}

/// A WhisperKit model in the model library: name, size before download, a short description, the
/// download progress and the download, cancel or delete controls. The app wraps it in its card and
/// supplies the speed and accuracy dots, so the row has no dependency on the design system.
struct WhisperKitModelRow<Ratings: View>: View {
    let spec: WhisperKitModelSpec
    let isInstalled: Bool
    let progress: WhisperKitDownloadProgress?
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onShowInFinder: () -> Void
    @ViewBuilder var ratings: Ratings

    private var isDownloading: Bool { progress != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(spec.displayName)
                    .font(.system(size: 13, weight: .semibold))

                HStack(spacing: 12) {
                    Label(spec.isMultilingual ? "Multilingual" : "English", systemImage: "globe")
                    Label(spec.formattedSize, systemImage: "internaldrive")
                    ratings
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Text(spec.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                if let progress {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(progress.message).lineLimit(1)
                            if progress.isIndeterminate {
                                ProgressView().controlSize(.small).scaleEffect(0.65)
                            }
                            Spacer()
                            Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                                .fontDesign(.monospaced)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                        ProgressView(value: progress.fraction)
                            .progressViewStyle(.linear)
                    }
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if isInstalled && !isDownloading {
                Label("Downloaded", systemImage: "checkmark.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())

                Menu {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete Model", systemImage: "trash")
                    }
                    Button(action: onShowInFinder) {
                        Label("Show in Finder", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 14))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20, height: 20)
            } else {
                Button(action: isDownloading ? onCancel : onDownload) {
                    HStack(spacing: 4) {
                        Text(isDownloading ? "Cancel" : "Download")
                        Image(systemName: isDownloading ? "xmark.circle" : "arrow.down.circle")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(isDownloading ? Color.red : Color.accentColor))
                }
                .buttonStyle(.plain)
            }
        }
        .focusEffectDisabled()
    }
}
