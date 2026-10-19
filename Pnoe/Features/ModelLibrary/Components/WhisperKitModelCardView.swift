import SwiftUI

struct WhisperKitModelCardView: View {
    let model: WhisperKitModel
    @ObservedObject private var modelManager = WhisperKitModelManager.shared

    var body: some View {
        if let spec = model.spec {
            WhisperKitModelRow(
                spec: spec,
                isInstalled: modelManager.isModelDownloaded(named: model.name),
                progress: modelManager.downloadStatus(for: spec),
                onDownload: { modelManager.startDownload(spec) },
                onCancel: { modelManager.cancelDownload(spec) },
                onDelete: { modelManager.deleteModel(spec) },
                onShowInFinder: { modelManager.showModelInFinder(spec) },
                downloadFailed: modelManager.hasDownloadFailed(spec)
            ) {
                HStack(spacing: 3) {
                    Text("Speed")
                    progressDotsWithNumber(value: model.speed * 10)
                }
                .fixedSize(horizontal: true, vertical: false)
                HStack(spacing: 3) {
                    Text("Accuracy")
                    progressDotsWithNumber(value: model.accuracy * 10)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(16)
            .background(AppMaterialCardBackground())
        }
    }
}
