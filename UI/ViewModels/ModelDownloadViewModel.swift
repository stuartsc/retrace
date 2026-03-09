import Foundation
import SwiftUI
import Shared
import App

/// ViewModel for model download onboarding and settings
/// Manages download state and progress for AI models via ModelManager
/// Owner: UI module
@MainActor
class ModelDownloadViewModel: ObservableObject {

    // MARK: - Published State

    @Published var models: [ModelDisplayInfo] = []
    @Published var modelStatuses: [String: ModelStatusInfo] = [:]
    @Published var downloadProgress: [String: DownloadProgressInfo] = [:]
    @Published var isDownloading = false
    @Published var error: String?

    // MARK: - Display Types

    struct ModelDisplayInfo: Identifiable {
        let id = UUID()
        let name: String
        let filename: String
        let sizeMB: Int
        let purpose: String
    }

    struct ModelStatusInfo {
        let isDownloaded: Bool
        let isValid: Bool
        let fileSizeBytes: Int64?
    }

    struct DownloadProgressInfo {
        let bytesDownloaded: Int64
        let totalBytes: Int64
        let percentage: Double

        var downloadedMB: Int {
            Int(bytesDownloaded / 1_048_576)
        }

        var totalMB: Int {
            Int(totalBytes / 1_048_576)
        }
    }

    // MARK: - Dependencies

    private let modelManager: ModelManager

    // MARK: - Initialization

    init(modelManager: ModelManager) {
        self.modelManager = modelManager

        self.models = ModelManager.allModels.map { model in
            ModelDisplayInfo(
                name: model.name,
                filename: model.filename,
                sizeMB: model.sizeMB,
                purpose: model.purpose
            )
        }
    }

    // MARK: - Computed Properties

    var totalSizeString: String {
        let totalMB = models.reduce(0) { $0 + $1.sizeMB }
        if totalMB > 1024 {
            let gb = Double(totalMB) / 1024.0
            return String(format: "%.1f GB", gb)
        } else {
            return "\(totalMB) MB"
        }
    }

    var allModelsDownloaded: Bool {
        models.allSatisfy { model in
            modelStatuses[model.name]?.isDownloaded == true &&
            modelStatuses[model.name]?.isValid == true
        }
    }

    // MARK: - Actions

    func checkModelStatuses() async {
        let statuses = await modelManager.getAllModelStatuses()
        for status in statuses {
            modelStatuses[status.model.name] = ModelStatusInfo(
                isDownloaded: status.isDownloaded,
                isValid: status.isValid,
                fileSizeBytes: status.fileSizeBytes
            )
        }
    }

    func downloadModels() async {
        isDownloading = true
        error = nil

        do {
            for modelInfo in ModelManager.allModels {
                _ = try await modelManager.downloadModel(modelInfo) { [weak self] progress in
                    Task { @MainActor in
                        self?.downloadProgress[progress.model.name] = DownloadProgressInfo(
                            bytesDownloaded: progress.bytesDownloaded,
                            totalBytes: progress.totalBytes,
                            percentage: progress.percentage
                        )
                    }
                }

                // Update status after each model completes
                let status = await modelManager.getModelStatus(modelInfo)
                modelStatuses[modelInfo.name] = ModelStatusInfo(
                    isDownloaded: status.isDownloaded,
                    isValid: status.isValid,
                    fileSizeBytes: status.fileSizeBytes
                )
            }

            Log.info("[ModelDownloadViewModel] All models downloaded successfully", category: .app)
        } catch {
            self.error = error.localizedDescription
            Log.error("[ModelDownloadViewModel] Model download failed: \(error.localizedDescription)", category: .app)
        }

        isDownloading = false
    }

    func downloadModel(_ modelInfo: ModelManager.ModelInfo) async {
        isDownloading = true
        error = nil

        do {
            _ = try await modelManager.downloadModel(modelInfo) { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress[progress.model.name] = DownloadProgressInfo(
                        bytesDownloaded: progress.bytesDownloaded,
                        totalBytes: progress.totalBytes,
                        percentage: progress.percentage
                    )
                }
            }

            let status = await modelManager.getModelStatus(modelInfo)
            modelStatuses[modelInfo.name] = ModelStatusInfo(
                isDownloaded: status.isDownloaded,
                isValid: status.isValid,
                fileSizeBytes: status.fileSizeBytes
            )

            Log.info("[ModelDownloadViewModel] Downloaded \(modelInfo.name)", category: .app)
        } catch {
            self.error = error.localizedDescription
            Log.error("[ModelDownloadViewModel] Download failed for \(modelInfo.name): \(error.localizedDescription)", category: .app)
        }

        isDownloading = false
    }

    func deleteModel(_ modelInfo: ModelManager.ModelInfo) async {
        do {
            try await modelManager.deleteModel(modelInfo)
            let status = await modelManager.getModelStatus(modelInfo)
            modelStatuses[modelInfo.name] = ModelStatusInfo(
                isDownloaded: status.isDownloaded,
                isValid: status.isValid,
                fileSizeBytes: status.fileSizeBytes
            )
            downloadProgress.removeValue(forKey: modelInfo.name)
            Log.info("[ModelDownloadViewModel] Deleted \(modelInfo.name)", category: .app)
        } catch {
            self.error = error.localizedDescription
            Log.error("[ModelDownloadViewModel] Failed to delete \(modelInfo.name): \(error)", category: .app)
        }
    }

    func skip() {
        Log.info("[ModelDownloadViewModel] User skipped model download", category: .app)
    }
}
