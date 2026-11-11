import Foundation

/// Optional, explicitly configured, local-only embedding runtime. This protocol
/// grants no evidence access; callers must obtain input and revalidate results
/// through the canonical evidence owner. At most one request may predict at once.
public protocol LocalEmbeddingRuntimeProtocol: Actor {
    func prepare() async throws -> LocalEmbeddingDescriptor
    /// Complete bounded windows or an error; never silent truncation/partial output.
    func embed(_ text: String) async throws -> LocalEmbeddingBatch
    func status() async -> LocalEmbeddingStatus
    /// Terminal, coalesced, cancellation-independent join. No active-operation
    /// metrics arrive after successful close; a failed cleanup remains retryable.
    func close() async throws
}
