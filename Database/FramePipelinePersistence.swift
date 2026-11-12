import Foundation
import SQLCipher
import Shared

extension DatabaseManager {
    /// Capture identity and deletion protection become durable together, before
    /// the separate filesystem map can be interrupted by a crash.
    public func insertCapturedFrame(_ frame: FrameReference, originalVideoPathID: VideoSegmentID) async throws -> Int64 {
        let db = try requireRecallConnection()
        guard frame.source == .native, frame.id.value == 0, originalVideoPathID.value > 0,
              frame.frameIndexInSegment >= 0 else { throw PipelineSQL.failure("Invalid original capture identity") }
        return try PipelineSQL.transaction(db) {
            let storeID = try RecallSQL.nativeStore(db)
            guard let video = try SegmentQueries.getByID(db: db, id: frame.videoID),
                  video.source == .native,
                  URL(fileURLWithPath: video.relativePath).deletingPathExtension().lastPathComponent == originalVideoPathID.stringValue else {
                throw PipelineSQL.failure("Original source does not own the capture archive")
            }
            let id = try FrameQueries.insert(db: db, frame: frame)
            try ScreenEvidenceSQL.capture(db, frameID: id, descriptor: frame)
            try OriginalFrameSourceSQL.record(db, storeID: storeID, pathID: originalVideoPathID,
                                              index: frame.frameIndexInSegment, frameID: id)
            return id
        }
    }

    public func lookupOriginalFrame(sourceStoreID: UUID, originalVideoPathID: VideoSegmentID,
                                    sourceIndex: Int) async throws -> OriginalFrameAlias {
        let db = try requireRecallConnection()
        guard sourceStoreID == (try RecallSQL.nativeStore(db)), originalVideoPathID.value > 0,
              sourceIndex >= 0 else { return .unknown }
        return try OriginalFrameSourceSQL.lookup(db, storeID: sourceStoreID,
                                                pathID: originalVideoPathID, index: sourceIndex)
    }

    public func originalStoreID() async throws -> UUID {
        try RecallSQL.nativeStore(requireRecallConnection())
    }

    /// Indexed source hint for retained V24 originals. Legacy frames without an
    /// alias are not adopted, and deleted sources never become reader targets.
    public func originalFrameLocation(frameID: FrameID) async throws -> VideoSegmentID? {
        let db = try requireRecallConnection()
        let storeID = try RecallSQL.nativeStore(db)
        return try PipelineSQL.integers(db, """
            SELECT originalVideoPathID FROM original_frame_source
            WHERE storeID=? AND frameID=? AND deleted=0
              AND EXISTS(SELECT 1 FROM frame WHERE id=original_frame_source.frameID)
            """, [.text(storeID.uuidString), .integer(frameID.value)]).first.map { VideoSegmentID(value: $0) }
    }

    /// Commit an explicit app-filter outcome with queue completion. The caller
    /// supplies the captured app used for its decision; no OCR or text revision
    /// is manufactured. A later processing reset revokes this proof by trigger.
    public func recordOriginalExtractionSkipped(frameID: FrameID, expectedAppBundleID: String?) async throws {
        let db = try requireRecallConnection()
        try PipelineSQL.transaction(db) {
            let storeID = try RecallSQL.nativeStore(db)
            guard let frame = try FrameQueries.getByID(db: db, id: frameID) else {
                throw PipelineSQL.failure("Cannot skip extraction of an absent frame")
            }
            let snapshot = try ScreenEvidenceSQL.current(db, frameID: frameID, storeID: storeID)
            if let snapshot {
                guard snapshot.ref.source == .native, snapshot.ref.storeID == storeID,
                      snapshot.ref.frameID == frameID,
                      Schema.dateToTimestamp(snapshot.frame.timestamp) == Schema.dateToTimestamp(frame.timestamp),
                      snapshot.frame.metadata.appBundleID == expectedAppBundleID else {
                    throw PipelineSQL.failure("App-filter decision conflicts with captured identity")
                }
            } else {
                // Old, unattributed frames retain their previous skip behaviour,
                // but cannot authorise release of attributed original pixels.
                guard frame.metadata.appBundleID == expectedAppBundleID,
                      try PipelineSQL.integers(db,
                        "SELECT 1 FROM original_frame_source WHERE storeID=? AND frameID=? LIMIT 1",
                        [.text(storeID.uuidString), .integer(frameID.value)]).isEmpty else {
                    throw PipelineSQL.failure("Original skip has no immutable capture identity")
                }
            }
            try PipelineSQL.execute(db, "UPDATE frame SET processingStatus=2,processedAt=? WHERE id=?",
                [.integer(Schema.currentTimestamp()), .integer(frameID.value)])
            try PipelineSQL.execute(db, "DELETE FROM processing_queue WHERE frameId=?", [.integer(frameID.value)])
            if let snapshot {
                try PipelineSQL.execute(db, """
                    INSERT INTO original_frame_extraction_skip
                      (frameID,storeID,observationID,captureTimestamp,reason,recordedAt)
                    VALUES(?,?,?,?,'app_excluded',?)
                    ON CONFLICT(frameID) DO UPDATE SET storeID=excluded.storeID,
                      observationID=excluded.observationID,captureTimestamp=excluded.captureTimestamp,
                      reason=excluded.reason,recordedAt=excluded.recordedAt
                    """, [.integer(frameID.value), .text(storeID.uuidString),
                           .text(snapshot.ref.observationID.uuidString),
                           .integer(Schema.dateToTimestamp(snapshot.frame.timestamp)),
                           .integer(Schema.currentTimestamp())])
            }
        }
    }

    /// Read all cleanup prerequisites in one writer transaction. Queue status
    /// alone is insufficient: exclusion skips and blank OCR both use status 2.
    public func originalFrameDisposition(frameID: FrameID) async throws -> OriginalFrameDisposition {
        let db = try requireRecallConnection()
        return try PipelineSQL.transaction(db) {
            let storeID = try RecallSQL.nativeStore(db)
            guard let current = try FrameQueries.getByIDWithVideoInfo(db: db, id: frameID) else {
                let deleted = try PipelineSQL.integers(db,
                    "SELECT 1 FROM screen_deleted WHERE storeID=? AND frameID=? LIMIT 1",
                    [.text(storeID.uuidString), .integer(frameID.value)])
                // An unrelated/empty database cannot authorize destruction.
                return deleted.isEmpty ? .pending : .deleted(storeID: storeID)
            }
            guard current.processingStatus == 2, current.videoInfo?.isVideoFinalized == true,
                  let archive = try SegmentQueries.getByID(db: db, id: current.frame.videoID),
                  let snapshot = try ScreenEvidenceSQL.current(db, frameID: frameID, storeID: storeID),
                  snapshot.ref.source == .native, snapshot.ref.frameID == frameID,
                  Schema.dateToTimestamp(snapshot.frame.timestamp) == Schema.dateToTimestamp(current.frame.timestamp),
                  snapshot.width == archive.width, snapshot.height == archive.height else { return .pending }
            let original = try originalFrameForProcessing(current.frame)
            if snapshot.text != nil, snapshot.observation.provenance.origin == .ocr {
                return .extracted(storeID: storeID, frame: original, archive: archive)
            }
            let skipped = try PipelineSQL.integers(db, """
                SELECT 1 FROM original_frame_extraction_skip
                WHERE frameID=? AND storeID=? AND observationID=? AND captureTimestamp=? AND reason='app_excluded'
                """, [.integer(frameID.value), .text(storeID.uuidString),
                       .text(snapshot.ref.observationID.uuidString),
                       .integer(Schema.dateToTimestamp(current.frame.timestamp))])
            return skipped.isEmpty ? .pending : .skippedByAppFilter(storeID: storeID, frame: original, archive: archive)
        }
    }

    /// Use immutable capture metadata while retaining the current archive mapping.
    /// The legacy frame table does not contain display ID or captured window identity.
    public func originalFrameForProcessing(_ frame: FrameReference) throws -> FrameReference {
        let db = try requireRecallConnection()
        let storeID = try RecallSQL.nativeStore(db)
        guard let saved = try ScreenEvidenceSQL.current(db, frameID: frame.id, storeID: storeID) else { return frame }
        guard saved.ref.source == frame.source, saved.ref.frameID == frame.id,
              Schema.dateToTimestamp(saved.frame.timestamp) == Schema.dateToTimestamp(frame.timestamp) else {
            throw PipelineSQL.failure("Conflicting original frame metadata")
        }
        return FrameReference(id: frame.id, timestamp: frame.timestamp, segmentID: frame.segmentID,
            videoID: frame.videoID, frameIndexInSegment: frame.frameIndexInSegment,
            encodingStatus: frame.encodingStatus, metadata: saved.frame.metadata, source: frame.source)
    }

    /// Return an interrupted/deferred claim and its retry metadata in one transaction.
    /// A cancellation arriving after OCR commits must not reopen completed evidence.
    public func releaseFrameProcessingClaim(
        frameID: Int64, priority: Int, retryCount: Int, errorMessage: String? = nil
    ) async throws {
        guard let db = getConnection() else { throw DatabaseError.connectionFailed(underlying: "Database not initialized") }
        try PipelineSQL.transaction(db) {
            guard try PipelineSQL.integers(db, "SELECT processingStatus FROM frame WHERE id=?", [.integer(frameID)]).first == 1 else { return }
            try PipelineSQL.execute(db, "UPDATE frame SET processingStatus=0 WHERE id=?", [.integer(frameID)])
            try PipelineSQL.enqueue(db, frameID: frameID, priority: priority, retryCount: retryCount, error: errorMessage)
        }
    }

    public func commitFrameOCR(
        frameID: FrameID,
        text: ExtractedText,
        frameWidth: Int,
        frameHeight: Int
    ) async throws -> Int64 {
        guard let db = getConnection() else { throw DatabaseError.connectionFailed(underlying: "Database not initialized") }
        guard frameWidth > 0, frameHeight > 0 else { throw PipelineSQL.failure("Invalid OCR frame dimensions") }
        return try PipelineSQL.transaction(db) {
            try PipelineSQL.publishOCR(db, frameID: frameID, text: text,
                frameWidth: frameWidth, frameHeight: frameHeight)
        }
    }

    public func commitRecoveredFrames(
        video: VideoSegment,
        originalVideoPathID: VideoSegmentID,
        originalFrameIndices: [Int],
        frames: [FrameReference]
    ) async throws -> [Int64] {
        guard let db = getConnection() else { throw DatabaseError.connectionFailed(underlying: "Database not initialized") }
        guard !frames.isEmpty, frames.count <= 150, frames.count == originalFrameIndices.count,
              video.frameCount == frames.count, video.width > 0, video.height > 0,
              video.fileSizeBytes > 0, !video.relativePath.hasPrefix("/"),
              !video.relativePath.split(separator: "/").contains(".."),
              Set(originalFrameIndices).count == frames.count, originalFrameIndices.allSatisfy({ $0 >= 0 }),
              frames.enumerated().allSatisfy({ $0.element.frameIndexInSegment == $0.offset }),
              Set(frames.filter { $0.id.value > 0 }.map(\.id)).count == frames.filter({ $0.id.value > 0 }).count else {
            throw PipelineSQL.failure("Invalid recovered chunk descriptors")
        }
        return try PipelineSQL.transaction(db) {
            let storeID = try RecallSQL.nativeStore(db)
            let existingVideoIDs = try PipelineSQL.integers(db, "SELECT id FROM video WHERE path=?", [.text(video.relativePath)])
            guard existingVideoIDs.count <= 1 else { throw PipelineSQL.failure("Ambiguous recovery output path") }
            let videoID = try existingVideoIDs.first ?? SegmentQueries.insert(db: db, segment: video)
            let sourceIDs = try PipelineSQL.query(db, "SELECT id,path FROM video WHERE path LIKE ?", [.text("%\(originalVideoPathID.value)%")]) { statement -> Int64? in
                guard let value = sqlite3_column_text(statement, 1) else { return nil }
                let component = URL(fileURLWithPath: String(cString: value)).deletingPathExtension().lastPathComponent
                return component == originalVideoPathID.stringValue ? sqlite3_column_int64(statement, 0) : nil
            }.compactMap { $0 }
            var recoveredIDs: [Int64] = []
            // Only group newly created, contiguous app context. Reused frame segments
            // retain their original identity and duration; retries do not create groups.
            var newGroup: (id: Int64, metadata: FrameMetadata, lastTimestamp: Date)?
            for (index, descriptor) in frames.enumerated() {
                let alias = try OriginalFrameSourceSQL.lookup(db, storeID: storeID,
                    pathID: originalVideoPathID, index: originalFrameIndices[index])
                let aliasID: Int64?
                switch alias {
                case .unknown: aliasID = nil
                case .retained(let id): aliasID = id.value
                case .deleted: throw PipelineSQL.failure("Original frame was deleted")
                }
                let targetIDs = try PipelineSQL.integers(db, "SELECT id FROM frame WHERE videoId=? AND videoFrameIndex=?", [.integer(videoID), .integer(Int64(index))])
                var originalIDs: [Int64] = []
                for sourceID in sourceIDs where sourceID != videoID {
                    originalIDs += try PipelineSQL.integers(db, "SELECT id FROM frame WHERE videoId=? AND videoFrameIndex=?", [.integer(sourceID), .integer(Int64(originalFrameIndices[index]))])
                }
                guard targetIDs.count <= 1, originalIDs.count <= 1 else { throw PipelineSQL.failure("Ambiguous recovered frame identity") }
                let mappedID = descriptor.id.value > 0 ? descriptor.id.value : nil
                let candidates = Set(([mappedID, aliasID, targetIDs.first, originalIDs.first]).compactMap { $0 })
                guard candidates.count <= 1 else { throw PipelineSQL.failure("Conflicting recovered frame identities") }
                let frameID: Int64
                if let existingID = candidates.first {
                    newGroup = nil
                    guard let existing = try FrameQueries.getByID(db: db, id: FrameID(value: existingID)),
                          Schema.dateToTimestamp(existing.timestamp) == Schema.dateToTimestamp(descriptor.timestamp),
                          existing.metadata.appBundleID == descriptor.metadata.appBundleID || descriptor.metadata.appBundleID == nil,
                          aliasID == existingID || (
                            (existing.videoID.value == 0 || sourceIDs.contains(existing.videoID.value) || existing.videoID.value == videoID) &&
                            existing.frameIndexInSegment == (existing.videoID.value == videoID ? index : originalFrameIndices[index])
                          ) else {
                        throw PipelineSQL.failure("Recovered frame mapping does not match its source")
                    }
                    frameID = existingID
                    try FrameQueries.updateVideoLink(db: db, frameId: frameID, videoId: videoID, videoFrameIndex: index)
                } else {
                    let appSegmentID: Int64
                    if let group = newGroup,
                       group.metadata.appBundleID == descriptor.metadata.appBundleID,
                       group.metadata.windowName == descriptor.metadata.windowName,
                       group.metadata.browserURL == descriptor.metadata.browserURL,
                       descriptor.timestamp >= group.lastTimestamp {
                        appSegmentID = group.id
                        try AppSegmentQueries.updateEndDate(db: db, id: appSegmentID, endDate: descriptor.timestamp)
                    } else {
                        appSegmentID = try AppSegmentQueries.insert(
                            db: db, bundleID: descriptor.metadata.appBundleID ?? "unknown",
                            startDate: descriptor.timestamp, endDate: descriptor.timestamp,
                            windowName: descriptor.metadata.windowName, browserUrl: descriptor.metadata.browserURL
                        )
                    }
                    newGroup = (appSegmentID, descriptor.metadata, descriptor.timestamp)
                    let capturedDescriptor = FrameReference(
                        id: FrameID(value: 0), timestamp: descriptor.timestamp,
                        segmentID: AppSegmentID(value: appSegmentID), videoID: VideoSegmentID(value: videoID),
                        frameIndexInSegment: index, metadata: descriptor.metadata, source: .native
                    )
                    frameID = try FrameQueries.insert(db: db, frame: capturedDescriptor)
                    try ScreenEvidenceSQL.capture(db, frameID: frameID, descriptor: capturedDescriptor)
                }
                // Existing completed OCR remains valid for exactly the same recovered pixels.
                try OriginalFrameSourceSQL.record(db, storeID: storeID, pathID: originalVideoPathID,
                                                  index: originalFrameIndices[index], frameID: frameID)
                try PipelineSQL.execute(db, "UPDATE frame SET processingStatus=CASE WHEN processingStatus=2 THEN 2 ELSE 0 END WHERE id=?", [.integer(frameID)])
                recoveredIDs.append(frameID)
            }
            try SegmentQueries.markFinalized(db: db, id: videoID, frameCount: frames.count, fileSize: video.fileSizeBytes)
            return recoveredIDs
        }
    }
}

/// Synchronous helpers called only while DatabaseManager owns its connection.
/// No suspension is permitted inside a transaction.
private enum OriginalFrameSourceSQL {
    static func lookup(_ db: OpaquePointer, storeID: UUID, pathID: VideoSegmentID,
                       index: Int) throws -> OriginalFrameAlias {
        try PipelineSQL.query(db,
            "SELECT frameID,deleted FROM original_frame_source WHERE storeID=? AND originalVideoPathID=? AND sourceIndex=?",
            [.text(storeID.uuidString), .integer(pathID.value), .integer(Int64(index))]) { statement in
                let id = FrameID(value: sqlite3_column_int64(statement, 0))
                return sqlite3_column_int(statement, 1) == 1
                    ? OriginalFrameAlias.deleted(frameID: id) : .retained(frameID: id)
            }.first ?? .unknown
    }

    static func record(_ db: OpaquePointer, storeID: UUID, pathID: VideoSegmentID,
                       index: Int, frameID: Int64) throws {
        switch try lookup(db, storeID: storeID, pathID: pathID, index: index) {
        case .unknown:
            try PipelineSQL.execute(db,
                "INSERT INTO original_frame_source(storeID,originalVideoPathID,sourceIndex,frameID) VALUES(?,?,?,?)",
                [.text(storeID.uuidString), .integer(pathID.value), .integer(Int64(index)), .integer(frameID)])
        case .retained(let existing) where existing.value == frameID: return
        default: throw PipelineSQL.failure("Conflicting or deleted original frame identity")
        }
    }
}

/// Synchronous helpers called only while DatabaseManager owns its connection.
/// No suspension is permitted inside a transaction.
enum PipelineSQL {
    enum Value { case integer(Int64), real(Double), text(String), blob(Data) }

    /// Call only inside the canonical writer transaction after the caller's admission checks.
    static func publishOCR(_ db: OpaquePointer, frameID: FrameID, text: ExtractedText,
                           frameWidth: Int, frameHeight: Int) throws -> Int64 {
        guard let frame = try FrameQueries.getByID(db: db, id: frameID) else {
            throw PipelineSQL.failure("OCR frame no longer exists")
        }
        let canonicalText = try ScreenEvidenceSQL.commitOCR(db, frame: frame, text: text, width: frameWidth, height: frameHeight)
        try PipelineSQL.deleteFrameText(db, frameID: frameID.value)
        try NodeQueries.deleteByFrameID(db: db, frameID: frameID)
        var docid: Int64 = 0
        if !text.fullText.isEmpty || !text.chromeText.isEmpty {
            docid = try FTSQueries.indexFrame(
                db: db, mainText: text.fullText,
                chromeText: text.chromeText.isEmpty ? nil : text.chromeText,
                windowTitle: canonicalText.metadata.windowName,
                segmentId: frame.segmentID.value, frameId: frameID.value
            )
            var nodes: [(textOffset: Int, textLength: Int, text: String?, bounds: CGRect, windowIndex: Int?)] = []
            var offset = 0
            for region in text.regions {
                nodes.append((offset, region.text.count, region.text, region.bounds, nil))
                offset += region.text.count + 1
            }
            offset = text.fullText.count
            for region in text.chromeRegions {
                nodes.append((offset, region.text.count, region.text, region.bounds, nil))
                offset += region.text.count + 1
            }
            try NodeQueries.insertBatch(db: db, frameID: frameID, nodes: nodes, frameWidth: frameWidth, frameHeight: frameHeight)
        }
        try PipelineSQL.execute(db, "UPDATE frame SET processingStatus=2, processedAt=? WHERE id=?", [.integer(Schema.currentTimestamp()), .integer(frameID.value)])
        try PipelineSQL.execute(db, "DELETE FROM processing_queue WHERE frameId=?", [.integer(frameID.value)])
        return docid
    }

    static func failure(_ message: String) -> DatabaseError {
        .queryFailed(query: "frame pipeline transaction", underlying: message)
    }

    static func transaction<T>(_ db: OpaquePointer, _ operation: () throws -> T) throws -> T {
        try execute(db, "BEGIN IMMEDIATE TRANSACTION")
        do {
            let result = try operation()
            try execute(db, "COMMIT")
            return result
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    static func execute(_ db: OpaquePointer, _ sql: String, _ values: [Value] = []) throws {
        try statement(db, sql, values) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(String(cString: sqlite3_errmsg(db))) }
        }
    }

    static func query<T>(_ db: OpaquePointer, _ sql: String, _ values: [Value] = [], map: (OpaquePointer) throws -> T) throws -> [T] {
        try statement(db, sql, values) { statement in
            var result: [T] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW: result.append(try map(statement))
                case SQLITE_DONE: return result
                default: throw failure(String(cString: sqlite3_errmsg(db)))
                }
            }
        }
    }

    static func integers(_ db: OpaquePointer, _ sql: String, _ values: [Value] = []) throws -> [Int64] {
        try query(db, sql, values) { sqlite3_column_int64($0, 0) }
    }

    private static func statement<T>(_ db: OpaquePointer, _ sql: String, _ values: [Value], _ body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        defer { sqlite3_finalize(pointer) }
        guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .integer(let number): result = sqlite3_bind_int64(pointer, index, number)
            case .real(let number): result = sqlite3_bind_double(pointer, index, number)
            case .text(let text): result = sqlite3_bind_text(pointer, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .blob(let data):
                guard data.count <= Int(Int32.max) else { throw failure("Bound blob exceeds SQLite size limit") }
                if data.isEmpty {
                    result = sqlite3_bind_zeroblob(pointer, index, 0)
                } else {
                    result = data.withUnsafeBytes {
                        sqlite3_bind_blob(pointer, index, $0.baseAddress, Int32(data.count),
                                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                }
            }
            guard result == SQLITE_OK else { throw failure("Could not bind frame pipeline query") }
        }
        return try body(pointer)
    }

    static func deleteFrameText(_ db: OpaquePointer, frameID: Int64) throws {
        let docids = try integers(db, "SELECT DISTINCT docid FROM doc_segment WHERE frameId=?", [.integer(frameID)])
        try execute(db, "DELETE FROM doc_segment WHERE frameId=?", [.integer(frameID)])
        for docid in docids {
            try execute(db, "DELETE FROM searchRanking WHERE rowid=? AND NOT EXISTS(SELECT 1 FROM doc_segment WHERE docid=?)", [.integer(docid), .integer(docid)])
        }
    }

    @discardableResult
    static func enqueue(_ db: OpaquePointer, frameID: Int64, priority: Int, retryCount: Int = 0, error: String? = nil) throws -> Bool {
        guard try integers(db, "SELECT processingStatus FROM frame WHERE id=?", [.integer(frameID)]).first == 0 else {
            // WAL publication, fragment flush and finalization may each enqueue
            // the same frame. An existing claim/completed result stays untouched.
            return false
        }
        let rows = try integers(db, "SELECT id FROM processing_queue WHERE frameId=? ORDER BY id", [.integer(frameID)])
        if let keeper = rows.first {
            try execute(db, """
                UPDATE processing_queue SET
                  priority=MAX(?,(SELECT MAX(priority) FROM processing_queue WHERE frameId=?)),
                  retryCount=MAX(?,(SELECT MAX(retryCount) FROM processing_queue WHERE frameId=?)),
                  enqueuedAt=(SELECT MIN(enqueuedAt) FROM processing_queue WHERE frameId=?)
                WHERE id=?
                """, [.integer(Int64(priority)), .integer(frameID), .integer(Int64(retryCount)), .integer(frameID), .integer(frameID), .integer(keeper)])
            if let error { try execute(db, "UPDATE processing_queue SET lastError=? WHERE id=?", [.text(error), .integer(keeper)]) }
            try execute(db, "DELETE FROM processing_queue WHERE frameId=? AND id<>?", [.integer(frameID), .integer(keeper)])
        } else {
            try execute(db, "INSERT INTO processing_queue(frameId,enqueuedAt,priority,retryCount) VALUES(?,?,?,?)", [.integer(frameID), .real(Date().timeIntervalSince1970), .integer(Int64(priority)), .integer(Int64(retryCount))])
            if let error { try execute(db, "UPDATE processing_queue SET lastError=? WHERE frameId=?", [.text(error), .integer(frameID)]) }
        }
        return rows.isEmpty
    }
}
