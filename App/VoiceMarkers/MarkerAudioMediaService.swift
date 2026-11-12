import CryptoKit
import Darwin
import Foundation
import Processing
import Shared
import Storage

public enum MarkerAudioMediaError: Error, Equatable, Sendable {
    case unavailable, staleMarker, invalidMedia, incompleteCoverage
}

public struct MarkerAudioSelection: Sendable {
    public let markerID: UUID
    public let markerRevision: UUID
    public let anchor: SpokenMarkerAnchor
    /// Int16 little-endian mono, exactly the anchor's original 16 kHz sample range.
    public let pcm: Data
}

/// Registers original AAC identities only after the recording writer commits.
/// Files remain owned by recording/retention; no audio is copied into this store.
public actor MarkerAudioMediaService {
    private let root: URL
    private let markers: TimelineMarkerService
    private let nativeStoreID: @Sendable () async throws -> UUID
    public init(storageRoot: URL, markers: TimelineMarkerService,
                nativeStoreID: @escaping @Sendable () async throws -> UUID) {
        self.root = storageRoot; self.markers = markers; self.nativeStoreID = nativeStoreID
    }
    @discardableResult public func register(_ receipt: PersistedAudioBatchReceipt) async throws -> AudioMediaManifest {
        guard receipt.source == .microphone, receipt.sampleRate == 16_000, receipt.channels == 1,
              receipt.frameCount > 0, receipt.frameCount <= 16_000 * 120,
              !receipt.sourceRanges.isEmpty else { throw VoiceRecognitionError.invalidInput }
        let hash = try Self.digest(relativePath: receipt.relativePath, root: root,
            expectedURL: receipt.fileURL, expectedSize: receipt.fileSize)
        let storeID = try await nativeStoreID()
        let identityHash = SHA256.hash(data: Data((storeID.uuidString + "|" + receipt.relativePath + "|" + hash).utf8))
        let bytes = Array(identityHash.prefix(16))
        let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return try await markers.registerAudioManifest(.init(id: id, nativeStoreID: storeID,
            relativePath: receipt.relativePath, sha256: hash, frameCount: receipt.frameCount,
            sourceRanges: receipt.sourceRanges))
    }

    public func resolve(markerID: UUID, expectedRevision: UUID) async throws -> MarkerAudioSelection {
        guard let marker = try await markers.marker(id: markerID), marker.revision == expectedRevision,
              let observation = marker.spokenObservation, observation.status != .withdrawn else {
            throw MarkerAudioMediaError.staleMarker
        }
        let anchor = observation.anchor
        guard anchor.nativeStoreID == (try await nativeStoreID()), anchor.source == .microphone,
              anchor.sampleRate == 16_000, anchor.endSample > anchor.startSample,
              anchor.endSample - anchor.startSample <= 960_000 else { throw MarkerAudioMediaError.invalidMedia }
        let pcm = try await resolvePCM(.init(nativeStoreID: anchor.nativeStoreID, source: anchor.source,
            identity: .init(recordingGeneration: anchor.recordingGeneration, continuityID: anchor.continuityID,
                startSample: anchor.startSample, sampleCount: anchor.endSample - anchor.startSample,
                sampleRate: anchor.sampleRate, approximateOrigin: anchor.approximateOrigin)))
        guard let current = try await markers.marker(id: markerID), current.revision == expectedRevision,
              current.spokenObservation == observation else { throw MarkerAudioMediaError.staleMarker }
        try Task.checkCancellation()
        return MarkerAudioSelection(markerID: markerID, markerRevision: expectedRevision, anchor: anchor, pcm: pcm)
    }

    /// App-only assembler: callers own source-policy and selected-reference revalidation.
    /// It never creates a marker or treats a sample coordinate as disclosure authority.
    func resolvePCM(_ range: NativeAudioSampleRange) async throws -> Data {
        let identity = range.identity
        guard range.nativeStoreID == (try await nativeStoreID()), range.source == .microphone,
              identity.isValid else { throw MarkerAudioMediaError.invalidMedia }
        let endSample = identity.startSample + identity.sampleCount
        let manifests = try await markers.audioManifests(intersecting: range, limit: 100)
        struct Slice {
            let manifest: AudioMediaManifest
            let source: LiveAudioSampleIdentity
            let batchStart: Int64
            let start: Int64
            let end: Int64
        }
        let candidates = manifests.flatMap { manifest in manifest.sourceRanges.compactMap { mapping -> Slice? in
            let source = mapping.source
            guard manifest.nativeStoreID == range.nativeStoreID, manifest.source == .microphone,
                  source.recordingGeneration == identity.recordingGeneration, source.continuityID == identity.continuityID,
                  CompanionWire.sameWireDate(source.approximateOrigin, identity.approximateOrigin), source.sampleRate == identity.sampleRate,
                  source.startSample < endSample, source.startSample + source.sampleCount > identity.startSample else { return nil }
            return Slice(manifest: manifest, source: source, batchStart: mapping.batchStartSample,
                start: max(source.startSample, identity.startSample), end: min(source.startSample + source.sampleCount, endSample))
        } }
        var decoded: [UUID: Data] = [:]
        var result = Data()
        var cursor = identity.startSample
        var slices = 0
        while cursor < endSample {
            try Task.checkCancellation()
            guard slices < 256,
                  let slice = candidates.filter({ $0.start <= cursor && $0.end > cursor }).max(by: {
                      $0.end == $1.end ? $0.manifest.id.uuidString > $1.manifest.id.uuidString : $0.end < $1.end
                  }) else { throw MarkerAudioMediaError.incompleteCoverage }
            let pcm: Data
            if let cached = decoded[slice.manifest.id] { pcm = cached }
            else {
                guard decoded.count < 32 else { throw MarkerAudioMediaError.incompleteCoverage }
                let aac = try await verifiedBytes(for: slice.manifest)
                pcm = try ExactAudioDecoder.decode(aac: aac, expectedFrames: slice.manifest.frameCount)
                decoded[slice.manifest.id] = pcm
            }
            let start = slice.batchStart + cursor - slice.source.startSample
            let count = slice.end - cursor
            guard start >= 0, start <= slice.manifest.frameCount, count <= slice.manifest.frameCount - start,
                  pcm.count == slice.manifest.frameCount * 2 else { throw MarkerAudioMediaError.invalidMedia }
            result.append(pcm.subdata(in: Int(start * 2)..<Int((start + count) * 2)))
            cursor = slice.end; slices += 1
        }
        guard result.count == identity.sampleCount * 2 else { throw MarkerAudioMediaError.invalidMedia }
        try Task.checkCancellation()
        return result
    }

    /// Companion transport and playback share this registered, hash-checked read.
    /// Caller-supplied manifests never confer authority to an arbitrary file.
    public func verifiedBytes(for manifest: AudioMediaManifest) async throws -> Data {
        guard manifest.nativeStoreID == (try await nativeStoreID()),
              try await markers.audioManifest(relativePath: manifest.relativePath) == manifest else {
            throw MarkerAudioMediaError.invalidMedia
        }
        let bytes = try Self.readBytes(relativePath: manifest.relativePath, root: root)
        guard Self.hash(bytes) == manifest.sha256 else { throw MarkerAudioMediaError.invalidMedia }
        try Task.checkCancellation()
        return bytes
    }

    /// A descriptor is opened under a directory chain with O_NOFOLLOW at every
    /// component. Canonical writer paths are still validated against traversals.
    static func digest(relativePath: String, root: URL, expectedURL: URL? = nil, expectedSize: Int64? = nil) throws -> String {
        hash(try readBytes(relativePath: relativePath, root: root, expectedURL: expectedURL, expectedSize: expectedSize))
    }

    private static func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func readBytes(relativePath: String, root: URL, expectedURL: URL? = nil, expectedSize: Int64? = nil) throws -> Data {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 2, components.count <= 8, components.first == "audio",
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }),
              ["m4a", "aac"].contains(URL(fileURLWithPath: relativePath).pathExtension) else {
            throw VoiceRecognitionError.invalidInput
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        if let expectedURL {
            guard expectedURL.standardizedFileURL.path == root.appendingPathComponent(relativePath).standardizedFileURL.path else {
                throw VoiceRecognitionError.invalidInput
            }
        }
        var directory = open(resolvedRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw VoiceRecognitionError.invalidInput }
        defer { Darwin.close(directory) }
        for component in components.dropLast() {
            let child = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw VoiceRecognitionError.invalidInput }
            Darwin.close(directory); directory = child
        }
        let file = openat(directory, components.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw VoiceRecognitionError.invalidInput }
        defer { Darwin.close(file) }
        var before = stat()
        guard fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= 16 * 1_024 * 1_024,
              expectedSize == nil || before.st_size == expectedSize else { throw VoiceRecognitionError.invalidInput }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            let size = Darwin.read(file, &buffer, buffer.count)
            if size == 0 { break }
            if size < 0 { if errno == EINTR { continue }; throw VoiceRecognitionError.invalidInput }
            count += Int64(size)
            guard count <= before.st_size else { throw VoiceRecognitionError.invalidInput }
            data.append(contentsOf: buffer.prefix(size))
        }
        var after = stat()
        guard count == before.st_size, fstat(file, &after) == 0,
              before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw VoiceRecognitionError.invalidInput }
        return data
    }
}
