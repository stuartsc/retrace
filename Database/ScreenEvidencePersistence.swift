import Foundation
import CryptoKit
import SQLCipher
import Shared

extension DatabaseManager: EvidenceStoreProtocol {
    public func evidenceStoreID(source: FrameSource, identity: String) async throws -> UUID {
        let db = try requireRecallConnection()
        if source == .native { return try RecallSQL.nativeStore(db) }
        guard source != .unknown, !identity.isEmpty, identity.utf8.count <= 4096 else { throw RecallSQL.failure("Invalid imported store identity") }
        // Persist the registry without copying a potentially sensitive source path.
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return try PipelineSQL.transaction(db) {
            if let raw = try PipelineSQL.query(db, "SELECT storeID FROM evidence_store WHERE source=? AND identity=?", [.text(source.rawValue), .text(key)], map: { RecallSQL.string($0, 0) }).first,
               let id = UUID(uuidString: raw) { return id }
            let id = UUID()
            try PipelineSQL.execute(db, "INSERT INTO evidence_store(storeID,source,identity) VALUES(?,?,?)", [.text(id.uuidString), .text(source.rawValue), .text(key)])
            return id
        }
    }

    public func materializeScreenEvidence(frame: FrameReference, storeID: UUID, width: Int, height: Int,
                                          text: ExtractedText?) async throws -> ScreenEvidenceSnapshot {
        let db = try requireRecallConnection()
        guard frame.id.value > 0, (1...32_768).contains(width), (1...32_768).contains(height),
              frame.frameIndexInSegment >= 0, frame.timestamp.timeIntervalSince1970.isFinite,
              text == nil || text?.frameID == frame.id else { throw RecallSQL.failure("Invalid screen materialization") }
        return try PipelineSQL.transaction(db) {
            guard try ScreenEvidenceSQL.source(db, storeID: storeID) == frame.source else { throw RecallSQL.failure("Store source mismatch") }
            guard try PipelineSQL.integers(db, "SELECT 1 FROM screen_deleted WHERE storeID=? AND frameID=? LIMIT 1", [.text(storeID.uuidString), .integer(frame.id.value)]).isEmpty else {
                throw RecallSQL.failure("Deleted screen evidence cannot be recreated")
            }
            if frame.source == .native {
                guard let live = try FrameQueries.getByID(db: db, id: frame.id),
                      Schema.dateToTimestamp(live.timestamp) == Schema.dateToTimestamp(frame.timestamp) else {
                    throw RecallSQL.failure("Native frame is absent or has conflicting capture time")
                }
            }
            if let existing = try ScreenEvidenceSQL.current(db, frameID: frame.id, storeID: storeID) {
                guard Schema.dateToTimestamp(existing.frame.timestamp) == Schema.dateToTimestamp(frame.timestamp),
                      (existing.width == 0 || existing.width == width), (existing.height == 0 || existing.height == height) else {
                    throw RecallSQL.failure("Existing observation dimensions or capture identity conflict")
                }
                // Imported stores are read-only, but their OCR may be corrected
                // externally. Preserve the captured attribution and old extraction
                // while appending the newly validated flat text in our own registry.
                let importedText = frame.source != .native ? text.map {
                    ExtractedText(frameID: existing.frame.id, timestamp: existing.frame.timestamp, regions: [],
                        fullText: $0.fullText, chromeText: $0.chromeText, metadata: existing.frame.metadata)
                } : nil
                let importedTextChanged = importedText != nil &&
                    (importedText?.fullText != existing.text?.fullText || importedText?.chromeText != existing.text?.chromeText)
                if existing.width > 0 && existing.height > 0 {
                    guard importedTextChanged else { return existing }
                    return try ScreenEvidenceSQL.append(db, frame: existing.frame, storeID: storeID,
                        observationID: existing.ref.observationID, revision: existing.ref.extractionRevision + 1,
                        width: width, height: height, text: importedText, legacy: true)
                }
                try PipelineSQL.execute(db, "UPDATE screen_observation SET width=?,height=? WHERE observationID=?", [.integer(Int64(width)), .integer(Int64(height)), .text(existing.ref.observationID.uuidString)])
                return try ScreenEvidenceSQL.append(db, frame: existing.frame, storeID: storeID,
                    observationID: existing.ref.observationID, revision: existing.ref.extractionRevision + 1,
                    width: width, height: height, text: importedText ?? existing.text, legacy: existing.legacyContext)
            }
            let observationID = UUID()
            try ScreenEvidenceSQL.insertObservation(db, frame: frame, storeID: storeID, observationID: observationID,
                                                    width: width, height: height, legacy: true)
            return try ScreenEvidenceSQL.append(db, frame: frame, storeID: storeID, observationID: observationID,
                                                 revision: 0, width: width, height: height, text: text, legacy: true)
        }
    }

    public func screenEvidence(_ ref: ScreenEvidenceRef) async throws -> ScreenEvidenceSnapshot? {
        let db = try requireRecallConnection()
        guard ref.frameID.value > 0, ref.extractionRevision >= 0, ref.blockIDs.count <= 500,
              Set(ref.blockIDs).count == ref.blockIDs.count,
              try ScreenEvidenceSQL.source(db, storeID: ref.storeID) == ref.source else { return nil }
        let snapshot = try PipelineSQL.query(db, """
            SELECT e.payload FROM screen_extraction e JOIN screen_observation o ON o.observationID=e.observationID
            WHERE o.storeID=? AND o.source=? AND o.frameID=? AND o.observationID=? AND e.revision=?
            """, [.text(ref.storeID.uuidString), .text(ref.source.rawValue), .integer(ref.frameID.value),
                     .text(ref.observationID.uuidString), .integer(ref.extractionRevision)]) {
            try ScreenEvidenceSQL.decodeSnapshot(RecallSQL.string($0, 0))
        }.first
        guard let snapshot, snapshot.ref.storeID == ref.storeID, snapshot.ref.source == ref.source,
              snapshot.ref.frameID == ref.frameID, snapshot.ref.observationID == ref.observationID,
              snapshot.ref.extractionRevision == ref.extractionRevision else { return nil }
        if !ref.blockIDs.isEmpty {
            let count = (snapshot.text?.regions.count ?? 0) + (snapshot.text?.chromeRegions.count ?? 0)
            guard snapshot.highlightsVerified, ref.blockIDs.allSatisfy({ $0 >= 0 && $0 < count }) else { return nil }
        }
        return snapshot
    }

    public func currentScreenEvidence(frameID: FrameID, storeID: UUID) async throws -> ScreenEvidenceSnapshot? {
        try ScreenEvidenceSQL.current(requireRecallConnection(), frameID: frameID, storeID: storeID)
    }

    public func recordFrameMediaUnavailable(frameID: FrameID, reason: EvidenceUnavailableReason) async throws {
        guard [.recordingMissing, .integrityFailure, .frameFinalising].contains(reason) else { throw RecallSQL.failure("Invalid retained media outcome") }
        let db = try requireRecallConnection()
        try PipelineSQL.transaction(db) {
            guard try FrameQueries.getByID(db: db, id: frameID) != nil else { return }
            try PipelineSQL.execute(db, "INSERT INTO frame_media_unavailable(frameID,reason,observedAt) VALUES(?,?,?) ON CONFLICT(frameID) DO UPDATE SET reason=excluded.reason,observedAt=excluded.observedAt", [
                .integer(frameID.value), .text(reason.rawValue), .real(Date().timeIntervalSince1970)
            ])
            try PipelineSQL.execute(db, "UPDATE frame SET processingStatus=3 WHERE id=?", [.integer(frameID.value)])
            try PipelineSQL.execute(db, "DELETE FROM processing_queue WHERE frameId=?", [.integer(frameID.value)])
            try DailyMetricsQueries.recordEvent(db: db, metricType: .screenEvidenceOutcome, metadata: "{\"outcome\":\"\(reason.rawValue)\"}")
        }
    }

    public func frameMediaUnavailable(frameID: FrameID) async throws -> EvidenceUnavailableReason? {
        try PipelineSQL.query(requireRecallConnection(), "SELECT reason FROM frame_media_unavailable WHERE frameID=?", [.integer(frameID.value)]) {
            EvidenceUnavailableReason(rawValue: RecallSQL.string($0, 0))
        }.first ?? nil
    }
}

enum ScreenEvidenceSQL {
    /// Compatibility text writers cannot reuse an OCR revision or its geometry.
    /// The caller owns the same transaction as the FTS mutation.
    @discardableResult
    static func commitLegacyText(_ db: OpaquePointer, frameID: FrameID, mainText: String,
                                 chromeText: String?) throws -> FrameReference {
        guard let live = try FrameQueries.getByID(db: db, id: frameID) else {
            throw RecallSQL.failure("Cannot index text without its retained frame")
        }
        let storeID = try RecallSQL.nativeStore(db)
        let existing = try current(db, frameID: frameID, storeID: storeID)
        let original = existing?.frame ?? live
        let observationID = existing?.ref.observationID ?? UUID()
        let width = existing?.width ?? 0, height = existing?.height ?? 0
        if existing == nil {
            try insertObservation(db, frame: original, storeID: storeID, observationID: observationID,
                                  width: width, height: height, legacy: true)
        }
        let text = ExtractedText(frameID: frameID, timestamp: original.timestamp, regions: [],
            fullText: mainText, chromeText: chromeText ?? "", metadata: original.metadata)
        _ = try append(db, frame: original, storeID: storeID, observationID: observationID,
            revision: (existing?.ref.extractionRevision ?? -1) + 1, width: width, height: height,
            text: text, legacy: existing?.legacyContext ?? true)
        return original
    }

    static func source(_ db: OpaquePointer, storeID: UUID) throws -> FrameSource? {
        try PipelineSQL.query(db, "SELECT source FROM evidence_store WHERE storeID=?", [.text(storeID.uuidString)]) {
            FrameSource(rawValue: RecallSQL.string($0, 0))
        }.first ?? nil
    }

    static func capture(_ db: OpaquePointer, frameID: Int64, descriptor: FrameReference) throws {
        let storeID = try RecallSQL.nativeStore(db)
        let frame = FrameReference(id: FrameID(value: frameID), timestamp: descriptor.timestamp, segmentID: descriptor.segmentID,
            videoID: descriptor.videoID, frameIndexInSegment: descriptor.frameIndexInSegment,
            encodingStatus: descriptor.encodingStatus, metadata: descriptor.metadata, source: .native)
        let video = descriptor.videoID.value > 0 ? try SegmentQueries.getByID(db: db, id: descriptor.videoID) : nil
        let width = video?.width ?? 0, height = video?.height ?? 0
        let observationID = UUID()
        try insertObservation(db, frame: frame, storeID: storeID, observationID: observationID, width: width, height: height, legacy: false)
        _ = try append(db, frame: frame, storeID: storeID, observationID: observationID, revision: 0,
                       width: width, height: height, text: nil, legacy: false)
    }

    static func insertObservation(_ db: OpaquePointer, frame: FrameReference, storeID: UUID, observationID: UUID,
                                  width: Int, height: Int, legacy: Bool) throws {
        // Native FK and trigger invalidation protect every deletion path, including retention and video cascades.
        let nativeColumn = frame.source == .native ? "?" : "NULL"
        var values: [PipelineSQL.Value] = [.text(observationID.uuidString), .text(storeID.uuidString), .text(frame.source.rawValue), .integer(frame.id.value)]
        if frame.source == .native { values.append(.integer(frame.id.value)) }
        values += [.text(try RecallSQL.encode(frame)), .integer(Int64(width)), .integer(Int64(height)), .integer(legacy ? 1 : 0)]
        try PipelineSQL.execute(db, "INSERT INTO screen_observation(observationID,storeID,source,frameID,nativeFrameID,framePayload,width,height,legacy) VALUES(?,?,?,?,\(nativeColumn),?,?,?,?)", values)
    }

    static func current(_ db: OpaquePointer, frameID: FrameID, storeID: UUID) throws -> ScreenEvidenceSnapshot? {
        try PipelineSQL.query(db, "SELECT e.payload FROM screen_observation o JOIN screen_extraction e ON e.observationID=o.observationID AND e.revision=o.preferredRevision WHERE o.storeID=? AND o.frameID=?", [.text(storeID.uuidString), .integer(frameID.value)]) {
            try decodeSnapshot(RecallSQL.string($0, 0))
        }.first
    }

    /// Earlier payloads may have used canonical String equality for an offset proof.
    /// Revalidate on read without rewriting the retained extraction or upgrading its provenance.
    static func decodeSnapshot(_ payload: String) throws -> ScreenEvidenceSnapshot {
        let saved = try RecallSQL.decode(ScreenEvidenceSnapshot.self, payload)
        guard saved.highlightsVerified,
              saved.legacyContext || !coherent(saved.text, frameID: saved.frame.id, width: saved.width, height: saved.height) else {
            return saved
        }
        return ScreenEvidenceSnapshot(ref: saved.ref, frame: saved.frame, width: saved.width, height: saved.height,
            text: saved.text, legacyContext: saved.legacyContext, highlightsVerified: false,
            structuredObservation: saved.structuredObservation)
    }

    static func commitOCR(_ db: OpaquePointer, frame: FrameReference, text: ExtractedText, width: Int, height: Int) throws -> ExtractedText {
        guard text.frameID.value == 0 || text.frameID == frame.id,
              (text.regions + text.chromeRegions).allSatisfy({ $0.frameID.value == 0 || $0.frameID == frame.id }),
              (1...32_768).contains(width), (1...32_768).contains(height) else { throw RecallSQL.failure("OCR frame identity or dimensions conflict") }
        let storeID = try RecallSQL.nativeStore(db)
        let existing = try current(db, frameID: frame.id, storeID: storeID)
        let observationID = existing?.ref.observationID ?? UUID()
        let original = existing?.frame ?? frame
        guard (existing?.width ?? 0) == 0 || existing?.width == width,
              (existing?.height ?? 0) == 0 || existing?.height == height else { throw RecallSQL.failure("OCR dimensions differ from retained pixels") }
        if existing == nil {
            try insertObservation(db, frame: original, storeID: storeID, observationID: observationID, width: width, height: height, legacy: true)
        } else {
            try PipelineSQL.execute(db, "UPDATE screen_observation SET width=?,height=? WHERE observationID=?", [.integer(Int64(width)), .integer(Int64(height)), .text(observationID.uuidString)])
        }
        // Text provenance cannot replace capture metadata with mutable segment context.
        // ProcessingProtocol accepts CapturedFrame without a database ID and returns
        // zero placeholders. The durable queue supplies the already validated frame ID.
        // Conflicting assigned IDs were rejected above rather than silently reassigned.
        func bind(_ regions: [TextRegion]) -> [TextRegion] {
            regions.map { TextRegion(id: $0.databaseID, frameID: frame.id, text: $0.text, bounds: $0.bounds,
                                     confidence: $0.confidence, createdAt: $0.createdAt) }
        }
        let canonical = ExtractedText(frameID: frame.id, timestamp: original.timestamp, regions: bind(text.regions),
            chromeRegions: bind(text.chromeRegions), fullText: text.fullText, chromeText: text.chromeText, metadata: original.metadata)
        _ = try append(db, frame: original, storeID: storeID, observationID: observationID,
            revision: (existing?.ref.extractionRevision ?? -1) + 1, width: width, height: height,
            text: canonical, legacy: existing?.legacyContext ?? true, provenance: .init(origin: .ocr))
        try PipelineSQL.execute(db, "DELETE FROM frame_media_unavailable WHERE frameID=?", [.integer(frame.id.value)])
        return canonical
    }

    static func append(_ db: OpaquePointer, frame: FrameReference, storeID: UUID, observationID: UUID, revision: Int64,
                       width: Int, height: Int, text: ExtractedText?, legacy: Bool,
                       provenance: EvidenceExtractionProvenance? = nil) throws -> ScreenEvidenceSnapshot {
        let ref = ScreenEvidenceRef(storeID: storeID, source: frame.source, observationID: observationID,
                                    frameID: frame.id, extractionRevision: revision)
        let verified = !legacy && coherent(text, frameID: frame.id, width: width, height: height)
        let observation = StructuredScreenObservation.project(text: text, width: width, height: height,
            provenance: provenance ?? .init(origin: legacy ? .legacyUnknown : .unknown), geometryVerified: verified)
        let snapshot = ScreenEvidenceSnapshot(ref: ref, frame: frame, width: width, height: height,
            text: text, legacyContext: legacy, highlightsVerified: verified, structuredObservation: observation)
        let payload = try RecallSQL.encode(snapshot)
        guard payload.utf8.count <= 8_388_608 else { throw RecallSQL.failure("Extraction snapshot exceeds size bound") }
        try PipelineSQL.execute(db, "INSERT INTO screen_extraction(observationID,revision,payload) VALUES(?,?,?)", [.text(observationID.uuidString), .integer(revision), .text(payload)])
        try PipelineSQL.execute(db, "UPDATE screen_observation SET preferredRevision=? WHERE observationID=?", [.integer(revision), .text(observationID.uuidString)])
        return snapshot
    }

    static func coherent(_ text: ExtractedText?, frameID: FrameID, width: Int, height: Int) -> Bool {
        guard let text, width > 0, height > 0,
              text.fullText.utf8.elementsEqual(text.regions.map(\.text).joined(separator: " ").utf8),
              text.chromeText.utf8.elementsEqual(text.chromeRegions.map(\.text).joined(separator: " ").utf8) else { return false }
        let regions = text.regions + text.chromeRegions
        guard !regions.isEmpty else { return false }
        return regions.allSatisfy {
            let box = $0.bounds
            return $0.frameID == frameID && !box.isNull && !box.isInfinite && box.minX.isFinite && box.minY.isFinite
                && box.width.isFinite && box.height.isFinite && box.width > 0 && box.height > 0
                && box.minX >= 0 && box.minY >= 0 && box.maxX <= CGFloat(width) && box.maxY <= CGFloat(height)
        }
    }
}
