import Foundation
import Shared

/// Public Shared adapter around the measured, pinned CPU-only runtime. There is
/// no artifact discovery, download, evidence admission or index activation here.
public actor LocalEmbeddingRuntime: LocalEmbeddingRuntimeProtocol {
    private let native: MiniLMEmbeddingRuntime
    private var closed = false

    public init(configuration: LocalEmbeddingConfiguration,
                recordMetric: @escaping @Sendable (LocalEmbeddingMetric) -> Void) {
        native = MiniLMEmbeddingRuntime(configuration: .init(modelPackageURL: configuration.modelPackageURL,
            tokenizerURL: configuration.tokenizerURL, privateCacheParentURL: configuration.privateCacheParentURL),
            recordMetric: { value in
                // Both schemas are closed content-free enums. The callback only
                // enqueues; App drains its bounded inbox after joined shutdown.
                let operation: LocalEmbeddingMetric.Operation
                switch value.operation {
                case .preparation: operation = .preparation
                case .embedding: operation = .embedding
                case .cleanup: operation = .cleanup
                }
                let outcome: LocalEmbeddingMetric.Outcome
                switch value.outcome {
                case .completed: outcome = .completed
                case .rejected: outcome = .rejected
                case .cancelled: outcome = .cancelled
                case .failed: outcome = .failed
                }
                recordMetric(.init(operation: operation, outcome: outcome,
                    windowCount: value.windowCount, elapsedMilliseconds: value.elapsedMilliseconds))
            })
    }

    public func prepare() async throws -> LocalEmbeddingDescriptor {
        guard !closed else { throw LocalEmbeddingError.closed }
        try Self.validatePin()
        do {
            try await native.prepare()
            guard !closed else { throw LocalEmbeddingError.closed }
            return .miniLM
        } catch { throw Self.mapped(error) }
    }

    public func embed(_ text: String) async throws -> LocalEmbeddingBatch {
        guard !closed else { throw LocalEmbeddingError.closed }
        try Self.validatePin()
        do {
            let windows = try await native.embed(text)
            guard !closed else { throw LocalEmbeddingError.closed }
            return .init(descriptor: .miniLM, windows: windows.map {
                .init(tokenStart: $0.tokenStart, tokenEnd: $0.tokenEnd,
                      inputUTF16Range: .init(location: $0.utf16Location, length: $0.utf16Length), vector: $0.vector)
            })
        } catch { throw Self.mapped(error) }
    }

    public func status() async -> LocalEmbeddingStatus {
        let value = await native.status()
        return .init(isPrepared: value.isPrepared && !closed, isEmbedding: value.isEmbedding,
                     completedWindowCount: value.completedWindowCount, totalWindowCount: value.totalWindowCount)
    }

    public func close() async throws {
        closed = true
        do { try await native.close() } catch { throw Self.mapped(error) }
    }

    private static func validatePin() throws {
        let expected = LocalEmbeddingDescriptor.miniLM
        guard expected.modelID == MiniLMModelPin.modelID, expected.modelRevision == MiniLMModelPin.modelRevision,
              expected.modelPackageSHA256 == MiniLMModelPin.packageManifestSHA256,
              expected.tokenizerSHA256 == MiniLMModelPin.tokenizer.sha256,
              expected.transformSHA256 == MiniLMModelPin.transformSHA256,
              expected.dimensions == MiniLMModelPin.dimensions else { throw LocalEmbeddingError.modelInvalid }
    }

    private static func mapped(_ error: Error) -> Error {
        guard let error = error as? MiniLMRuntimeError else { return error }
        switch error {
        case .artifactUnavailable: return LocalEmbeddingError.artifactUnavailable
        case .artifactInvalid: return LocalEmbeddingError.artifactInvalid
        case .modelInvalid: return LocalEmbeddingError.modelInvalid
        case .predictionFailed: return LocalEmbeddingError.predictionFailed
        case .invalidOutput: return LocalEmbeddingError.invalidOutput
        case .inputTooLarge: return LocalEmbeddingError.inputTooLarge
        case .emptyInput: return LocalEmbeddingError.emptyInput
        case .busy: return LocalEmbeddingError.busy
        case .closed: return LocalEmbeddingError.closed
        case .cleanupFailed: return LocalEmbeddingError.cleanupFailed
        }
    }
}
