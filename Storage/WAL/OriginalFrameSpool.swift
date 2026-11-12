import AVFoundation
import Darwin
import Foundation
import Shared

/// Versioned acknowledgements live beside the original pixels. Queue admission,
/// a playable video, or a completed-looking status never substitutes for them.
struct OriginalSpoolReceipt: Codable {
    var version = 1
    var sourceStoreID: UUID?
    var sealed = false
    var sourceBytes: UInt64?
    var sourceFrames: Int?
    var mappings: [OriginalArchiveMapping] = []
    var deleted: [OriginalDeletedFrame] = []

    var archiveComplete: Bool {
        guard sealed, let sourceFrames else { return false }
        return Set(mappings.map(\.sourceIndex)).union(deleted.map(\.sourceIndex)).count == sourceFrames
    }
}

struct OriginalDeletedFrame: Codable {
    let frameID: Int64
    let sourceIndex: Int
}

struct OriginalArchiveMapping: Codable {
    let frameID: Int64
    let sourceIndex: Int
    let archiveIndex: Int
    let archive: VideoSegment
    let file: OriginalArchiveFileIdentity
}

struct OriginalArchiveFileIdentity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modified: Date
}

private struct OriginalStoreAttribution: Decodable {
    let sourceStoreID: UUID?
}

private struct ProvenOriginalReadFailure: Error, Sendable {
    let error: ExactFrameReadError
}

extension WALManager {
    func sessionDirectory(videoID: VideoSegmentID) -> URL {
        let current = walRootURL.appendingPathComponent("original_segment_\(videoID.value)")
        return FileManager.default.fileExists(atPath: current.path)
            ? current : walRootURL.appendingPathComponent("active_segment_\(videoID.value)")
    }

    private func originalReaderKey(videoID: VideoSegmentID) -> String {
        walRootURL.resolvingSymlinksInPath().standardizedFileURL.path + ":" + videoID.stringValue
    }

    public func configureOriginalStore(storeID: UUID) throws {
        guard originalStoreID == nil || originalStoreID == storeID || liveSessionIDs.isEmpty else {
            throw StorageError.fileWriteFailed(path: walRootURL.path, underlying: "Cannot change original store while capture owns a writer")
        }
        originalStoreID = storeID
    }

    func originalReceipt(for session: WALSession) throws -> OriginalSpoolReceipt {
        try validateOriginalSession(session)
        let url = session.sessionDir.appendingPathComponent("original-retention.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return OriginalSpoolReceipt() }
        let data = try boundedOriginalReceiptData(url)
        let receipt = try JSONDecoder().decode(OriginalSpoolReceipt.self, from: data)
        guard receipt.version == 1,
              Set(receipt.mappings.map(\.sourceIndex)).count == receipt.mappings.count,
              Set(receipt.mappings.map(\.frameID)).count == receipt.mappings.count,
              Set(receipt.deleted.map(\.sourceIndex)).count == receipt.deleted.count,
              receipt.mappings.allSatisfy({ $0.sourceIndex >= 0 && $0.archiveIndex >= 0 && $0.frameID > 0 }),
              receipt.deleted.allSatisfy({ $0.sourceIndex >= 0 && $0.frameID > 0 }) else {
            throw originalFailure(session, "Invalid original retention receipt")
        }
        return receipt
    }

    private func boundedOriginalReceiptData(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = 2 * 1_024 * 1_024
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            throw StorageError.fileReadFailed(path: url.path, underlying: "Original receipt exceeds its metadata budget")
        }
        return data
    }

    func saveOriginalReceipt(_ receipt: OriginalSpoolReceipt, for session: WALSession) throws {
        try validateOriginalSession(session)
        let url = session.sessionDir.appendingPathComponent("original-retention.json")
        try JSONEncoder().encode(receipt).write(to: url, options: .atomic)
        try OriginalSpoolFiles.synchronizeFileAndParent(url)
        try accountOriginalFile(url)
    }

    func validateOriginalSession(_ session: WALSession) throws {
        let root = walRootURL.resolvingSymlinksInPath().standardizedFileURL
        let name = session.sessionDir.lastPathComponent
        guard ["active_segment_\(session.videoID.value)", "original_segment_\(session.videoID.value)"].contains(name) else {
            throw originalFailure(session, "Unknown original session namespace")
        }
        let expected = root.appendingPathComponent(name).standardizedFileURL
        guard session.videoID.value > 0,
              session.sessionDir.resolvingSymlinksInPath().standardizedFileURL.path == expected.path,
              session.framesURL.resolvingSymlinksInPath().standardizedFileURL.path == expected.appendingPathComponent("frames.bin").path else {
            throw originalFailure(session, "Original session path escaped its storage root")
        }
        for name in ["metadata.json", "frame_id_map.bin", "original-retention.json"] {
            let url = session.sessionDir.appendingPathComponent(name)
            guard url.resolvingSymlinksInPath().standardizedFileURL.path == expected.appendingPathComponent(name).path else {
                throw originalFailure(session, "Original receipt path escaped its session")
            }
        }
    }

    func ensureOriginalSpoolAdmission(incomingBytes incoming: Int64) throws {
        let usage = try originalSpoolUsage()
        // Reserve bounded space for the ID map, archive receipt and atomic metadata
        // replacement before admitting pixels; acknowledgements must remain writable.
        let reserve = usage.reservedBytes.addingReportingOverflow(1_024)
        let sum = usage.bytes.addingReportingOverflow(incoming)
        let projected = sum.partialValue.addingReportingOverflow(reserve.partialValue)
        guard !reserve.overflow, !sum.overflow, !projected.overflow,
              projected.partialValue <= maximumSpoolBytes else {
            throw OriginalSpoolPressure.capacityLimit(retainedBytes: usage.bytes, incomingBytes: incoming,
                                                       limitBytes: maximumSpoolBytes)
        }
        let free = try availableSpoolBytes()
        let requiredFree = incoming.addingReportingOverflow(reserve.partialValue)
        guard !requiredFree.overflow, free >= minimumFreeBytes,
              requiredFree.partialValue <= free - minimumFreeBytes else {
            throw OriginalSpoolPressure.freeSpaceHeadroom(availableBytes: free, incomingBytes: requiredFree.partialValue,
                                                         minimumFreeBytes: minimumFreeBytes)
        }
    }

    private func originalSpoolUsage() throws -> (bytes: Int64, reservedBytes: Int64) {
        try cachedOriginalSpoolUsage()
    }

    public func originalSpoolStatus() async throws -> OriginalSpoolStatus {
        let sessions = try await listActiveSessions()
        return OriginalSpoolStatus(retainedBytes: try originalSpoolUsage().bytes, limitBytes: maximumSpoolBytes,
            availableBytes: try availableSpoolBytes(), minimumFreeBytes: minimumFreeBytes,
            retainedSessions: sessions.count,
            unattributedSessions: sessions.filter { (try? originalReceipt(for: $0).sourceStoreID) == nil }.count)
    }

    /// Locate originals by the persisted database identity, including after recovery
    /// has changed the current encoded-video path and frame index.
    public func readOriginalFrameForProcessing(sourceStoreID: UUID, frame: FrameReference,
                                              originalVideoPathID: VideoSegmentID? = nil,
                                              expectedWidth: Int, expectedHeight: Int) async throws -> CapturedFrame? {
        try BackgroundProcessingContext.checkCancellation()
        guard frame.source == .native, frame.id.value > 0,
              expectedWidth > 0, expectedHeight > 0 else { throw ExactFrameReadError.integrityFailure }
        var matching: CapturedFrame?
        var sourceFailure: ExactFrameReadError?
        let candidates: [WALSession]
        if let pathID = originalVideoPathID {
            // The V24 unique store/frame alias supplies the immutable source path.
            // New and historical processing never enumerates unrelated sessions.
            let directory = sessionDirectory(videoID: pathID)
            let frames = directory.appendingPathComponent("frames.bin")
            guard FileManager.default.fileExists(atPath: frames.path) else { return nil }
            do {
                candidates = [WALSession(videoID: pathID, sessionDir: directory, framesURL: frames,
                                         metadata: try originalSessionMetadata(directory))]
            } catch { throw ExactFrameReadError.integrityFailure }
        } else {
            // Compatibility-only discovery for unattributed legacy callers.
            candidates = try await listActiveSessions()
        }
        for session in candidates {
            try BackgroundProcessingContext.checkCancellation()
            let candidate: CapturedFrame?
            do {
                candidate = try await withOriginalReadLease(videoID: session.videoID) {
                    try await self.readOriginalCandidate(session: session, sourceStoreID: sourceStoreID,
                        frame: frame, expectedWidth: expectedWidth, expectedHeight: expectedHeight)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ExactFrameReadError where error == .cancelled {
                throw error
            } catch let failure as ProvenOriginalReadFailure {
                sourceFailure = failure.error
                continue
            } catch {
                // An unavailable, unqualified session cannot deny a different
                // frame's verified archive. Its pixels remain retained.
                continue
            }
            if let candidate {
                guard matching == nil else { throw ExactFrameReadError.integrityFailure }
                matching = candidate
            }
        }
        if let sourceFailure { throw sourceFailure }
        return matching
    }

    private func readOriginalCandidate(session: WALSession, sourceStoreID: UUID, frame: FrameReference,
                                       expectedWidth: Int, expectedHeight: Int) async throws -> CapturedFrame? {
        guard originalCandidateBelongsTo(session: session, sourceStoreID: sourceStoreID, frameID: frame.id.value) else {
            return nil
        }
        do {
            let receipt = try originalReceipt(for: session)
            guard receipt.sourceStoreID == sourceStoreID else { throw ExactFrameReadError.integrityFailure }
            guard !receipt.deleted.contains(where: { $0.frameID == frame.id.value }) else { return nil }
            return try await readExactFrame(videoID: session.videoID, frameID: frame.id.value,
                expectedTimestamp: frame.timestamp, expectedWidth: expectedWidth, expectedHeight: expectedHeight,
                expectedDisplayID: frame.metadata.displayID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ExactFrameReadError where error == .cancelled {
            throw error
        } catch {
            throw ProvenOriginalReadFailure(error: error as? ExactFrameReadError ?? .integrityFailure)
        }
    }

    /// This identifies the scope of a possible integrity failure; it never
    /// authorizes pixels. The full receipt and conflict-checked map are verified
    /// by readOriginalCandidate/readExactFrame after both identities match.
    private func originalCandidateBelongsTo(session: WALSession, sourceStoreID: UUID, frameID: Int64) -> Bool {
        do {
            try validateOriginalSession(session)
            let data = try boundedOriginalReceiptData(session.sessionDir.appendingPathComponent("original-retention.json"))
            let attribution = try JSONDecoder().decode(OriginalStoreAttribution.self, from: data)
            guard attribution.sourceStoreID == sourceStoreID else { return false }
            let map = try FileHandle(forReadingFrom: session.sessionDir.appendingPathComponent("frame_id_map.bin"))
            defer { try? map.close() }
            while let record = try map.read(upToCount: 16), record.count == 16 {
                if record.withUnsafeBytes({ $0.loadUnaligned(as: Int64.self) }) == frameID { return true }
            }
        } catch { }
        return false
    }

    /// Storage validates every archived sample and persists its identity before this
    /// receipt can participate in deleting originals. Video IDs here are database IDs.
    func confirmOriginalArchive(session: WALSession, video: VideoSegment,
                                sourceIndices: [Int], frameIDs: [Int64], governor: (any BackgroundProcessingProtocol)? = nil) async throws {
        try await withOriginalReadLease(videoID: session.videoID) {
            try await self.confirmOriginalArchiveWithLease(session: session, video: video,
                sourceIndices: sourceIndices, frameIDs: frameIDs, governor: governor)
        }
    }

    private func confirmOriginalArchiveWithLease(session: WALSession, video: VideoSegment,
                                                 sourceIndices: [Int], frameIDs: [Int64], governor: (any BackgroundProcessingProtocol)? = nil) async throws {
        try BackgroundProcessingContext.checkCancellation()
        guard let storeID = originalStoreID, try originalReceipt(for: session).sourceStoreID == storeID else {
            throw originalFailure(session, "Archive acknowledgement cannot adopt an unbound or different original store")
        }
        guard sourceIndices.count == frameIDs.count,
              sourceIndices.count == video.frameCount,
              Set(sourceIndices).count == sourceIndices.count,
              Set(frameIDs).count == frameIDs.count else {
            throw originalFailure(session, "Archive acknowledgement has ambiguous frame mappings")
        }
        let root = walRootURL.deletingLastPathComponent()
        let fingerprint = try await OriginalSpoolFiles.verifyArchive(video, storageRoot: root, governor: governor)
        let reader = try WALRecoveryReader(session: session)
        let scan = try await reader.scan()
        let wanted = Dictionary(uniqueKeysWithValues: sourceIndices.enumerated().map { ($0.element, $0.offset) })
        var additions: [OriginalArchiveMapping] = []
        var offset: UInt64 = 0
        for index in 0..<scan.frameCount {
            guard let record = try await reader.readRecord(at: offset, index: index, loadPixels: false) else {
                throw originalFailure(session, "Original source changed during archive acknowledgement")
            }
            offset = record.nextOffset
            guard let archiveIndex = wanted[index] else { continue }
            guard record.databaseFrameID == frameIDs[archiveIndex],
                  record.frame.width == video.width, record.frame.height == video.height else {
                throw originalFailure(session, "Archive acknowledgement does not match its original frame")
            }
            additions.append(OriginalArchiveMapping(frameID: frameIDs[archiveIndex], sourceIndex: index,
                archiveIndex: archiveIndex, archive: video, file: fingerprint))
        }
        guard additions.count == sourceIndices.count, try await reader.sourceIsUnchanged() else {
            throw originalFailure(session, "Archive acknowledgement has missing originals")
        }
        var receipt = try originalReceipt(for: session)
        for mapping in additions {
            guard !receipt.deleted.contains(where: { $0.frameID == mapping.frameID }) else { continue }
            receipt.mappings.removeAll { $0.sourceIndex == mapping.sourceIndex }
            receipt.mappings.append(mapping)
        }
        if scan.tailError == nil, scan.frameCount >= session.metadata.frameCount {
            receipt.sourceBytes = scan.sourceSize
            receipt.sourceFrames = scan.frameCount
        }
        try BackgroundProcessingContext.checkCancellation()
        try saveOriginalReceipt(receipt, for: session)
    }

    func confirmOriginalArchive(video: VideoSegment, governor: (any BackgroundProcessingProtocol)? = nil) async throws {
        guard let sourceID = Int64(URL(fileURLWithPath: video.relativePath).deletingPathExtension().lastPathComponent),
              let session = try await listActiveSessions().first(where: { $0.videoID.value == sourceID }) else { return }
        try await withOriginalReadLease(videoID: session.videoID) {
            try await self.confirmOriginalArchiveWithLease(video: video, session: session, governor: governor)
        }
    }

    private func confirmOriginalArchiveWithLease(video: VideoSegment, session: WALSession,
        governor: (any BackgroundProcessingProtocol)? = nil) async throws {
        let reader = try WALRecoveryReader(session: session)
        let scan = try await reader.scan()
        guard scan.tailError == nil, scan.frameCount == video.frameCount else {
            throw originalFailure(session, "Archive does not cover every original record")
        }
        var ids: [Int64] = []
        var offset: UInt64 = 0
        for index in 0..<scan.frameCount {
            guard let record = try await reader.readRecord(at: offset, index: index, loadPixels: false),
                  let frameID = record.databaseFrameID else {
                throw originalFailure(session, "Original frame has no durable database identity")
            }
            ids.append(frameID)
            offset = record.nextOffset
        }
        try await confirmOriginalArchive(session: session, video: video,
                                          sourceIndices: Array(0..<scan.frameCount), frameIDs: ids, governor: governor)
    }

    func markOriginalDeleted(session: WALSession, storeID: UUID, frameID: Int64, sourceIndex: Int) throws {
        var receipt = try originalReceipt(for: session)
        guard receipt.sourceStoreID == storeID else {
            throw originalFailure(session, "Deletion acknowledgement belongs to a different original store")
        }
        if receipt.deleted.contains(where: { $0.frameID == frameID && $0.sourceIndex == sourceIndex }) { return }
        guard !receipt.deleted.contains(where: { $0.frameID == frameID || $0.sourceIndex == sourceIndex }) else {
            throw originalFailure(session, "Conflicting original deletion identity")
        }
        receipt.deleted.append(OriginalDeletedFrame(frameID: frameID, sourceIndex: sourceIndex))
        receipt.mappings.removeAll { $0.frameID == frameID }
        try saveOriginalReceipt(receipt, for: session)
    }

    public func reconcileOriginalSpool(
        prepareArchives: Bool = false,
        governor: (any BackgroundProcessingProtocol)? = nil,
        disposition: @escaping @Sendable (FrameID) async throws -> OriginalFrameDisposition
    ) async throws -> OriginalSpoolStatus {
        try BackgroundProcessingContext.checkCancellation()
        if let originalSpoolReconciliation { return try await originalSpoolReconciliation.value }
        let task = Task { try await self.performOriginalReconciliation(prepareArchives: prepareArchives, governor: governor, disposition: disposition) }
        originalSpoolReconciliation = task
        defer { originalSpoolReconciliation = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func performOriginalReconciliation(
        prepareArchives: Bool,
        governor: (any BackgroundProcessingProtocol)?,
        disposition: @escaping @Sendable (FrameID) async throws -> OriginalFrameDisposition
    ) async throws -> OriginalSpoolStatus {
        for session in try await listActiveSessions() {
            try BackgroundProcessingContext.checkCancellation()
            do {
                try refreshOriginalSessionAccounting(session)
                guard let boundStoreID = try originalReceipt(for: session).sourceStoreID else { continue }
                // Map/header setup is one bounded source operation. Every following
                // record proof yields admission, so a large spool cannot hold the slot.
                let reader = try await BackgroundProcessingContext.run(governor: governor, kind: .freshOCR) {
                    try WALRecoveryReader(session: session)
                }
                var acknowledged = true
                var offset: UInt64 = 0
                var index = 0
                while true {
                    let position = offset, recordIndex = index
                    let unit = try await BackgroundProcessingContext.run(governor: governor, kind: .freshOCR) {
                        guard let record = try await reader.readRecord(at: position, index: recordIndex, loadPixels: false) else {
                            return Optional<(WALRecoveryRecord, OriginalFrameDisposition)>.none
                        }
                        let state: OriginalFrameDisposition
                        if let id = record.databaseFrameID { state = try await disposition(FrameID(value: id)) }
                        else { state = .pending }
                        return (record, state)
                    }
                    guard let (record, state) = unit else { break }
                    offset = record.nextOffset
                    defer { index += 1 }
                    guard let id = record.databaseFrameID else { acknowledged = false; continue }
                    try BackgroundProcessingContext.checkCancellation()
                    switch state {
                    case .pending:
                        acknowledged = false
                    case .deleted(let storeID):
                        guard storeID == boundStoreID else { acknowledged = false; continue }
                        try markOriginalDeleted(session: session, storeID: storeID, frameID: id, sourceIndex: index)
                    case .extracted(let storeID, let frame, let archive),
                         .skippedByAppFilter(let storeID, let frame, let archive):
                        var receipt = try originalReceipt(for: session)
                        // A normal capture can finish before OCR. Archive proof is
                        // prepared here, under App's joined governor permit, rather
                        // than blocking the recording writer on native decoding.
                        if prepareArchives, receipt.sealed, storeID == boundStoreID,
                           receipt.mappings.isEmpty,
                           URL(fileURLWithPath: archive.relativePath).deletingPathExtension().lastPathComponent == session.videoID.stringValue {
                            try await confirmOriginalArchive(video: archive, governor: governor)
                            receipt = try originalReceipt(for: session)
                        }
                        guard storeID == boundStoreID,
                              let mapping = receipt.mappings.first(where: { $0.frameID == id && $0.sourceIndex == index }),
                              frame.id.value == id, frame.source == .native, archive.source == .native,
                              frame.videoID == archive.id, mapping.archive.id == archive.id,
                              frame.frameIndexInSegment == mapping.archiveIndex,
                              mapping.archive.relativePath == archive.relativePath,
                              mapping.archive.frameCount == archive.frameCount,
                              record.frame.width == archive.width, record.frame.height == archive.height,
                              record.frame.metadata.displayID == frame.metadata.displayID,
                              abs(record.frame.timestamp.timeIntervalSince(frame.timestamp)) <= 0.001,
                              !receipt.deleted.contains(where: { $0.frameID == id }),
                              let file = try? OriginalSpoolFiles.archiveIdentity(archive, storageRoot: walRootURL.deletingLastPathComponent()),
                              file == mapping.file else { acknowledged = false; continue }
                    }
                }
                guard acknowledged, index >= session.metadata.frameCount, !liveSessionIDs.contains(session.videoID),
                      try originalReceipt(for: session).sealed,
                      try await reader.sourceIsUnchanged() else { continue }
                let key = originalReaderKey(videoID: session.videoID)
                guard await OriginalSpoolReaders.shared.beginRemoval(key) else { continue }
                do {
                    try BackgroundProcessingContext.checkCancellation()
                    try removeAcknowledgedSession(session)
                    await OriginalSpoolReaders.shared.endRemoval(key)
                } catch {
                    await OriginalSpoolReaders.shared.endRemoval(key)
                    throw error
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ExactFrameReadError where error == .cancelled {
                throw error
            } catch {
                // One damaged session cannot hold every independently proved
                // original. Its files stay in place and still count as pressure.
                Log.warning("Original spool session retained: cleanup proof is unavailable", category: .storage)
            }
        }
        return try await originalSpoolStatus()
    }

    func withOriginalReadLease<T: Sendable>(videoID: VideoSegmentID,
        operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let key = originalReaderKey(videoID: videoID)
        try await OriginalSpoolReaders.shared.beginRead(key)
        do {
            try BackgroundProcessingContext.checkCancellation()
            let value = try await operation()
            try BackgroundProcessingContext.checkCancellation()
            await OriginalSpoolReaders.shared.endRead(key)
            return value
        } catch {
            await OriginalSpoolReaders.shared.endRead(key)
            throw error
        }
    }

    private func originalFailure(_ session: WALSession, _ reason: String) -> StorageError {
        .fileReadFailed(path: session.framesURL.path, underlying: reason)
    }
}

private actor OriginalSpoolReaders {
    static let shared = OriginalSpoolReaders()
    private var readers: [String: Int] = [:]
    private var removing: Set<String> = []

    func beginRead(_ key: String) throws {
        guard !removing.contains(key) else { throw ExactFrameReadError.frameFinalising }
        readers[key, default: 0] += 1
    }

    func endRead(_ key: String) {
        let remaining = max(0, readers[key, default: 0] - 1)
        if remaining == 0 { readers.removeValue(forKey: key) } else { readers[key] = remaining }
    }

    func beginRemoval(_ key: String) -> Bool {
        guard readers[key, default: 0] == 0, !removing.contains(key) else { return false }
        removing.insert(key)
        return true
    }

    func endRemoval(_ key: String) { removing.remove(key) }
}

enum OriginalSpoolFiles {
    static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw StorageError.fileWriteFailed(path: url.path, underlying: "Cannot open durability directory") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw StorageError.fileWriteFailed(path: url.path, underlying: "Cannot synchronize durability directory")
        }
    }

    static func synchronizeFileAndParent(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    static func archiveURL(_ video: VideoSegment, storageRoot: URL) throws -> URL {
        guard video.source == .native, video.id.value > 0, video.frameCount > 0,
              video.width > 0, video.height > 0, video.fileSizeBytes > 0,
              !video.relativePath.isEmpty, !video.relativePath.hasPrefix("/"),
              !video.relativePath.split(separator: "/").contains("..") else { throw ExactFrameReadError.integrityFailure }
        let root = storageRoot.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(video.relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw ExactFrameReadError.integrityFailure }
        return url
    }

    static func archiveIdentity(_ video: VideoSegment, storageRoot: URL) throws -> OriginalArchiveFileIdentity {
        let url = try archiveURL(video, storageRoot: storageRoot)
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              let device = values[.systemNumber] as? NSNumber, let inode = values[.systemFileNumber] as? NSNumber,
              let size = values[.size] as? NSNumber, size.int64Value == video.fileSizeBytes,
              let modified = values[.modificationDate] as? Date else { throw ExactFrameReadError.integrityFailure }
        return OriginalArchiveFileIdentity(device: device.uint64Value, inode: inode.uint64Value,
                                            size: size.uint64Value, modified: modified)
    }

    /// Decode one sample at a time, checking every timestamp and frame dimension.
    /// This avoids repeated random-access decoders or a resident frame array.
    static func verifyArchive(_ video: VideoSegment, storageRoot: URL,
        governor: (any BackgroundProcessingProtocol)? = nil) async throws -> OriginalArchiveFileIdentity {
        let cancellation = BackgroundProcessingContext.permit?.cancellation
        let task = Task.detached(priority: .utility) {
            try BackgroundProcessingContext.checkCancellation()
            if cancellation?.isCancelled == true { throw CancellationError() }
            let url = try archiveURL(video, storageRoot: storageRoot)
            let initial = try archiveIdentity(video, storageRoot: storageRoot)
            let link = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-spool-\(UUID()).mp4")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            defer { try? FileManager.default.removeItem(at: link) }
            let asset = AVURLAsset(url: link)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExactFrameReadError.integrityFailure }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw ExactFrameReadError.integrityFailure }
            reader.add(output)
            guard reader.startReading() else { throw ExactFrameReadError.integrityFailure }
            defer { reader.cancelReading() }
            let unit = OriginalArchiveReadUnit(reader: reader, output: output, video: video)
            while try await BackgroundProcessingContext.run(governor: governor, kind: .freshOCR,
                operation: { try unit.readNext() }) {
                // No permit remains held here. The governor's speech priority
                // chooses the next owner before this task requests another frame.
                await Task.yield()
            }
            guard try archiveIdentity(video, storageRoot: storageRoot) == initial else {
                throw ExactFrameReadError.integrityFailure
            }
            try synchronizeFileAndParent(url)
            try BackgroundProcessingContext.checkCancellation()
            return initial
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

/// A single serial verification task owns this native reader. The Sendable
/// boundary only permits one awaited frame unit at a time; neither the reader
/// nor its output is exposed to another task or retained after joined teardown.
private final class OriginalArchiveReadUnit: @unchecked Sendable {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let video: VideoSegment
    private var index = 0

    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, video: VideoSegment) {
        self.reader = reader; self.output = output; self.video = video
    }

    func readNext() throws -> Bool {
        try BackgroundProcessingContext.checkCancellation()
        guard let sample = output.copyNextSampleBuffer() else {
            guard reader.status == .completed, index == video.frameCount else {
                throw ExactFrameReadError.integrityFailure
            }
            return false
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard index < video.frameCount, time.isNumeric, time.seconds.isFinite,
              abs(time.seconds - Double(index) / 30) <= 1.0 / 600_000,
              let pixels = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferGetWidth(pixels) == video.width, CVPixelBufferGetHeight(pixels) == video.height else {
            throw ExactFrameReadError.integrityFailure
        }
        index += 1
        try BackgroundProcessingContext.checkCancellation()
        return true
    }
}
