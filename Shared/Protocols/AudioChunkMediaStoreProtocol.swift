import Foundation

/// Storage owns durable media/journals and reader lifetimes; Database independently
/// authorizes registration, current reads and deletion. Paths alone are not authority.
public protocol AudioChunkMediaStoreProtocol: Sendable {
    func persistChunk(_ input: AudioChunkInput, previous: AudioChunkDescriptor?) async throws -> StoredAudioWindow
    /// Verifies encoded identity and returns the exact ordered valid sample
    /// selection. The descriptor's versioned decode contract determines whether
    /// its initial PCM hash is diagnostic or a strict pretrial read requirement.
    func readWindow(_ window: StoredAudioWindow) async throws -> AudioWindowReadLease
    func release(_ lease: AudioWindowReadLease) async
    func pendingWindows(limit: Int) async throws -> [StoredAudioWindow]
    func acknowledgePublished(_ window: StoredAudioWindow) async throws
    /// Only pass windows/chunks that the canonical writer has durably fenced and
    /// confirmed unreferenced. Implementations revoke readers and join before unlink.
    func deleteAuthorized(windows: [StoredAudioWindow], chunks: [AudioChunkDescriptor]) async throws
    func close() async
}
