import Foundation

/// This descriptor identifies one measured conversion, not an arbitrary model
/// that happens to expose a compatible vector shape. A new conversion requires
/// new pins and parity evidence before its outputs can share an index.
enum MiniLMModelPin {
    struct Artifact: Sendable {
        let relativePath: String
        let byteCount: Int
        let sha256: String
    }

    static let modelID = "sentence-transformers/all-MiniLM-L6-v2"
    static let modelRevision = "1110a243fdf4706b3f48f1d95db1a4f5529b4d41"
    static let packageManifestSHA256 = "d3806da4c9148f87ef92f5054d4fbc74875589ce5ee81640d65c7813d7a17779"
    static let transformSHA256 = "266a80a756948759e1818406797949566dda34fd16dd16987d36544bf10b42e5"
    static let dimensions = 384
    static let sequenceLength = 256
    static let maximumWindows = 32
    static let tokenizer = Artifact(relativePath: "tokenizer.json", byteCount: 466_247,
        sha256: "be50c3628f2bf5bb5e3a7f17b1f74611b2561a3a27eeab05e5aa30f411572037")
    static let modelArtifacts: [Artifact] = [
        .init(relativePath: "Manifest.json", byteCount: 617,
              sha256: "44bd49f33c3af9f3b203230228b69cd99bbaad6a80a686e66884a610a8fe05e4"),
        .init(relativePath: "Data/com.apple.CoreML/model.mlmodel", byteCount: 60_372,
              sha256: "57f2e627c5a5b7c300a09765d311a87a51061a5ac5893f26e94090d03f2b59a4"),
        .init(relativePath: "Data/com.apple.CoreML/weights/weight.bin", byteCount: 89_874_816,
              sha256: "e2c6457e856a114a62f0abedccdaf7edbaf48e4cfd97ec2eb7e0c00fc7eafba1")
    ]
}

struct MiniLMEmbeddingConfiguration: Sendable {
    let modelPackageURL: URL
    let tokenizerURL: URL
    /// An existing private application-owned directory. Runtime-owned children
    /// are removed on close; unrelated entries are never enumerated or removed.
    let privateCacheParentURL: URL
}

struct MiniLMEmbeddingWindow: Sendable {
    let tokenStart: Int
    let tokenEnd: Int
    let utf16Location: Int
    let utf16Length: Int
    let vector: [Float]
}

enum MiniLMRuntimeError: Error, Sendable, Equatable {
    case artifactUnavailable
    case artifactInvalid
    case modelInvalid
    case predictionFailed
    case invalidOutput
    case inputTooLarge
    case emptyInput
    case busy
    case closed
    case cleanupFailed
}

/// The owning App adapter persists this categorical event as a daily metric.
/// It contains no text, paths, evidence identity, application, or source labels.
struct MiniLMRuntimeMetric: Sendable {
    enum Operation: String, Sendable { case preparation, embedding, cleanup }
    enum Outcome: String, Sendable { case completed, rejected, cancelled, failed }
    let operation: Operation
    let outcome: Outcome
    let windowCount: Int
    let elapsedMilliseconds: Double
}

struct MiniLMRuntimeStatus: Sendable {
    let isPrepared: Bool
    let isEmbedding: Bool
    let completedWindowCount: Int
    let totalWindowCount: Int
}
