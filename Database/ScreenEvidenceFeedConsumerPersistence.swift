import Foundation
import SQLCipher
import Shared

extension DatabaseManager: ScreenEvidenceFeedStoreProtocol {
    public func beginScreenEvidenceBootstrap(consumerID: UUID, leaseDuration: TimeInterval) async throws
        -> ScreenEvidenceConsumerStatus {
        try ScreenEvidenceConsumerSQL.begin(requireRecallConnection(), consumerID: consumerID,
                                            leaseDuration: leaseDuration)
    }

    public func advanceScreenEvidenceConsumer(cursor: ScreenEvidenceConsumerCursor, limit: Int) async throws
        -> ScreenEvidenceConsumerPage {
        try ScreenEvidenceConsumerSQL.advance(requireRecallConnection(), cursor: cursor, limit: limit)
    }

    public func screenEvidenceConsumerStatus(cursor: ScreenEvidenceConsumerCursor) async throws
        -> ScreenEvidenceConsumerStatus {
        try ScreenEvidenceConsumerSQL.status(requireRecallConnection(), cursor: cursor)
    }

    public func compactScreenEvidenceFeed(limit: Int) async throws -> ScreenEvidenceFeedCompaction {
        try ScreenEvidenceConsumerSQL.compact(requireRecallConnection(), limit: limit)
    }
}

/// The public writer and private disk regressions use this same synchronous engine.
/// No transaction may suspend. The internal clock argument makes lease tests deterministic.
enum ScreenEvidenceConsumerSQL {
    private static let maximumConsumers = 32
    private static let maximumLease: TimeInterval = 7 * 24 * 60 * 60
    private static let consumerColumns = """
        consumerID,feedID,storeID,leaseID,phase,bootstrapBoundary,maxFrameID,lastFrameID,checkpoint,expiresAt
        """

    static func begin(_ db: OpaquePointer, consumerID: UUID, leaseDuration: TimeInterval,
                      now: Date = Date()) throws -> ScreenEvidenceConsumerStatus {
        try Task.checkCancellation()
        guard leaseDuration.isFinite, leaseDuration > 0, leaseDuration <= maximumLease else {
            throw ScreenEvidenceFeedError.invalidLease
        }
        try validateClock(now)
        return try PipelineSQL.transaction(db) {
            let feed = try ScreenEvidenceFeedSQL.status(db)
            if let existing = try readConsumer(db, consumerID: consumerID) {
                try validate(existing, feed: feed)
                if existing.phase != .expired, existing.expiresAt > now, position(existing) >= feed.retainedThrough {
                    return existing
                }
            } else {
                let registered = try PipelineSQL.query(db, "SELECT consumerID FROM screen_evidence_consumer LIMIT ?",
                                                       [.integer(Int64(maximumConsumers + 1))]) { _ in () }
                guard registered.count <= maximumConsumers else { throw ScreenEvidenceFeedError.integrityFailure }
                guard registered.count < maximumConsumers else { throw ScreenEvidenceFeedError.consumerLimitReached }
            }
            let maximum = try PipelineSQL.integers(db, """
                SELECT frameID FROM screen_observation WHERE storeID=? AND source='native'
                ORDER BY frameID DESC LIMIT 1
                """, [.text(feed.storeID.uuidString)]).first ?? 0
            guard maximum >= 0 else { throw ScreenEvidenceFeedError.integrityFailure }
            let expiresAt = now.addingTimeInterval(leaseDuration)
            try validateClock(expiresAt)
            let cursor = ScreenEvidenceConsumerCursor(feedID: feed.feedID, storeID: feed.storeID,
                                                      consumerID: consumerID, leaseID: UUID())
            let state = ScreenEvidenceConsumerStatus(cursor: cursor, phase: .bootstrap,
                boundarySequence: feed.latestSequence, maximumFrameID: maximum, lastFrameID: 0,
                checkpointSequence: feed.latestSequence, expiresAt: expiresAt)
            try PipelineSQL.execute(db, """
                INSERT INTO screen_evidence_consumer(\(consumerColumns)) VALUES(?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(consumerID) DO UPDATE SET feedID=excluded.feedID,storeID=excluded.storeID,
                  leaseID=excluded.leaseID,phase=excluded.phase,bootstrapBoundary=excluded.bootstrapBoundary,
                  maxFrameID=excluded.maxFrameID,lastFrameID=excluded.lastFrameID,
                  checkpoint=excluded.checkpoint,expiresAt=excluded.expiresAt
                """, values(state))
            // Existing work and applied IDs stay on disk. The new lease immediately
            // excludes old work without an unbounded per-consumer deletion.
            try Task.checkCancellation()
            return state
        }
    }

    static func advance(_ db: OpaquePointer, cursor: ScreenEvidenceConsumerCursor, limit: Int,
                        now: Date = Date()) throws -> ScreenEvidenceConsumerPage {
        try Task.checkCancellation()
        guard (1...200).contains(limit) else { throw ScreenEvidenceFeedError.invalidLimits }
        try validateClock(now)
        let result: Result<ScreenEvidenceConsumerPage, ScreenEvidenceFeedError> = try PipelineSQL.transaction(db) {
            let feed = try ScreenEvidenceFeedSQL.status(db)
            let consumer = try requireConsumer(db, cursor: cursor, feed: feed)
            if consumer.phase == .expired || consumer.expiresAt <= now {
                try expire(db, consumer)
                return .failure(.cursorExpired)
            }
            if position(consumer) < feed.retainedThrough {
                try expire(db, consumer)
                return .failure(.feedGap)
            }
            let page: ScreenEvidenceConsumerPage
            if consumer.phase == .bootstrap {
                page = try bootstrap(db, consumer: consumer, feed: feed, limit: limit)
            } else {
                let events = try readEvents(db, after: consumer.checkpointSequence, limit: limit, feed: feed)
                guard contiguous(events.map(\.sequence), after: consumer.checkpointSequence,
                                 through: feed.latestSequence, limit: limit) else {
                    // No applied/work writes have happened. Commit only expiry so
                    // explicit begin can recover even when the retained floor is unchanged.
                    try expire(db, consumer)
                    return .failure(.feedGap)
                }
                page = try replay(db, events: events, consumer: consumer, feed: feed)
            }
            try Task.checkCancellation()
            return .success(page)
        }
        return try result.get()
    }

    static func status(_ db: OpaquePointer, cursor: ScreenEvidenceConsumerCursor,
                       now: Date = Date()) throws -> ScreenEvidenceConsumerStatus {
        try Task.checkCancellation()
        try validateClock(now)
        return try PipelineSQL.transaction(db) {
            let feed = try ScreenEvidenceFeedSQL.status(db)
            let consumer = try requireConsumer(db, cursor: cursor, feed: feed)
            if consumer.phase == .expired || consumer.expiresAt <= now || position(consumer) < feed.retainedThrough {
                try expire(db, consumer)
                return replacing(consumer, phase: .expired)
            }
            return consumer
        }
    }

    static func compact(_ db: OpaquePointer, limit: Int,
                        now: Date = Date()) throws -> ScreenEvidenceFeedCompaction {
        try Task.checkCancellation()
        guard (1...1000).contains(limit) else { throw ScreenEvidenceFeedError.invalidLimits }
        try validateClock(now)
        return try PipelineSQL.transaction(db) {
            let feed = try ScreenEvidenceFeedSQL.status(db)
            let consumers = try PipelineSQL.query(db, """
                SELECT \(consumerColumns) FROM screen_evidence_consumer ORDER BY expiresAt,consumerID LIMIT ?
                """, [.integer(Int64(maximumConsumers + 1))], map: decodeConsumer)
            guard consumers.count <= maximumConsumers else { throw ScreenEvidenceFeedError.integrityFailure }
            for consumer in consumers { try validate(consumer, feed: feed) }
            let expired = consumers.filter {
                $0.phase != .expired && ($0.expiresAt <= now || position($0) < feed.retainedThrough)
            }.prefix(limit)
            for consumer in expired { try expire(db, consumer) }
            let protectedThrough = consumers.filter {
                $0.phase != .expired && $0.expiresAt > now && position($0) >= feed.retainedThrough
            }.map(position).min() ?? feed.latestSequence
            let sequences = try PipelineSQL.integers(db, """
                SELECT sequence FROM screen_evidence_feed WHERE sequence>? AND sequence<=? ORDER BY sequence LIMIT ?
                """, [.integer(feed.retainedThrough), .integer(protectedThrough), .integer(Int64(limit))])
            guard contiguous(sequences, after: feed.retainedThrough, through: protectedThrough, limit: limit) else {
                throw ScreenEvidenceFeedError.feedGap
            }
            if let last = sequences.last {
                try PipelineSQL.execute(db, "DELETE FROM screen_evidence_feed WHERE sequence>? AND sequence<=?",
                                        [.integer(feed.retainedThrough), .integer(last)])
                guard Int(sqlite3_changes(db)) == sequences.count else { throw ScreenEvidenceFeedError.integrityFailure }
                try PipelineSQL.execute(db, "UPDATE screen_evidence_feed_state SET retainedThrough=? WHERE id=1", [.integer(last)])
            }
            try Task.checkCancellation()
            return ScreenEvidenceFeedCompaction(feed: try ScreenEvidenceFeedSQL.status(db),
                deletedEventCount: sequences.count, expiredConsumerCount: expired.count)
        }
    }

    private struct Record {
        let reference: ScreenEvidenceRef
        let sequence: Int64
        let state: ScreenEvidenceWorkState

        var work: ScreenEvidenceWork {
            ScreenEvidenceWork(reference: reference, sourceSequence: sequence, lexicalState: state, vectorState: state)
        }
    }

    private struct Event {
        let sequence: Int64
        let observationID: UUID
        let frameID: Int64
        let revision: Int64
    }

    private static func bootstrap(_ db: OpaquePointer, consumer: ScreenEvidenceConsumerStatus,
                                  feed: ScreenEvidenceFeedStatus, limit: Int) throws -> ScreenEvidenceConsumerPage {
        let records = try PipelineSQL.query(db, """
            \(observationQuery)
            WHERE o.storeID=? AND o.frameID>? AND o.frameID<=? ORDER BY o.frameID LIMIT ?
            """, [.text(feed.storeID.uuidString), .integer(consumer.lastFrameID),
                    .integer(consumer.maximumFrameID), .integer(Int64(limit))]) { try decodeObservation($0, feed: feed) }
        for record in records {
            try Task.checkCancellation()
            try writeWork(db, record: record, consumer: consumer)
        }
        let last = records.last?.reference.frameID.value ?? consumer.lastFrameID
        let finished = records.count < limit || last == consumer.maximumFrameID
        let updated = replacing(consumer, phase: finished ? .replay : .bootstrap, lastFrameID: last)
        try savePosition(db, updated)
        return ScreenEvidenceConsumerPage(status: updated, inspectedCount: records.count,
                                          appliedCount: records.count, work: records.map(\.work))
    }

    private static func replay(_ db: OpaquePointer, events: [Event], consumer: ScreenEvidenceConsumerStatus,
                               feed: ScreenEvidenceFeedStatus) throws -> ScreenEvidenceConsumerPage {
        var work: [ScreenEvidenceWork] = []
        var indices: [UUID: Int] = [:]
        var applied = 0
        for event in events {
            try Task.checkCancellation()
            let record = try currentRecord(db, event: event, feed: feed)
            try PipelineSQL.execute(db, """
                INSERT OR IGNORE INTO screen_evidence_applied(consumerID,eventSequence) VALUES(?,?)
                """, [.text(consumer.cursor.consumerID.uuidString), .integer(event.sequence)])
            applied += Int(sqlite3_changes(db))
            try writeWork(db, record: record, consumer: consumer)
            if let index = indices[event.observationID] {
                work[index] = record.work
            } else {
                indices[event.observationID] = work.count
                work.append(record.work)
            }
        }
        let updated = replacing(consumer, checkpoint: events.last?.sequence ?? consumer.checkpointSequence)
        try savePosition(db, updated)
        return ScreenEvidenceConsumerPage(status: updated, inspectedCount: events.count, appliedCount: applied, work: work)
    }

    private static func readEvents(_ db: OpaquePointer, after checkpoint: Int64, limit: Int,
                                   feed: ScreenEvidenceFeedStatus) throws -> [Event] {
        try PipelineSQL.query(db, """
            SELECT sequence,kind,storeID,source,observationID,frameID,extractionRevision
            FROM screen_evidence_feed WHERE sequence>? ORDER BY sequence LIMIT ?
            """, [.integer(checkpoint), .integer(Int64(limit))]) { row in
            let sequence = sqlite3_column_int64(row, 0)
            let frameID = sqlite3_column_int64(row, 5), revision = sqlite3_column_int64(row, 6)
            guard sequence > 0, sequence <= feed.latestSequence, frameID > 0, revision >= 0,
                  ScreenEvidenceFeedChangeKind(rawValue: RecallSQL.string(row, 1)) != nil,
                  UUID(uuidString: RecallSQL.string(row, 2)) == feed.storeID,
                  RecallSQL.string(row, 3) == FrameSource.native.rawValue,
                  let observationID = UUID(uuidString: RecallSQL.string(row, 4)) else {
                throw ScreenEvidenceFeedError.integrityFailure
            }
            return Event(sequence: sequence, observationID: observationID, frameID: frameID, revision: revision)
        }
    }

    /// All selected columns are identity/state primitives. Immutable extraction
    /// and frame payloads, OCR tables and FTS are deliberately never read here.
    private static let observationQuery = """
        SELECT o.observationID,o.frameID,o.nativeFrameID,o.source,o.preferredRevision,
          f.id,e.revision,f.redactionReason IS NOT NULL,m.frameID IS NOT NULL,
          s.frameID,s.latestSequence,s.extractionRevision,s.deleted,s.redacted,s.mediaUnavailableReason IS NOT NULL
        FROM screen_observation o
        LEFT JOIN frame f ON f.id=o.nativeFrameID
        LEFT JOIN screen_extraction e ON e.observationID=o.observationID AND e.revision=o.preferredRevision
        LEFT JOIN frame_media_unavailable m ON m.frameID=o.nativeFrameID
        LEFT JOIN screen_evidence_source_state s ON s.storeID=o.storeID AND s.observationID=o.observationID
        """

    private static func decodeObservation(_ row: OpaquePointer, feed: ScreenEvidenceFeedStatus) throws -> Record {
        let frameID = sqlite3_column_int64(row, 1), revision = sqlite3_column_int64(row, 4)
        guard let observationID = UUID(uuidString: RecallSQL.string(row, 0)), frameID > 0, revision >= 0,
              sqlite3_column_type(row, 2) != SQLITE_NULL, sqlite3_column_int64(row, 2) == frameID,
              RecallSQL.string(row, 3) == FrameSource.native.rawValue,
              sqlite3_column_type(row, 5) != SQLITE_NULL, sqlite3_column_int64(row, 5) == frameID,
              sqlite3_column_type(row, 6) != SQLITE_NULL, sqlite3_column_int64(row, 6) == revision else {
            throw ScreenEvidenceFeedError.integrityFailure
        }
        let redacted = sqlite3_column_int(row, 7) != 0, unavailable = sqlite3_column_int(row, 8) != 0
        var sequence: Int64 = 0
        if sqlite3_column_type(row, 9) != SQLITE_NULL {
            sequence = sqlite3_column_int64(row, 10)
            guard sqlite3_column_int64(row, 9) == frameID, sequence > 0, sequence <= feed.latestSequence,
                  sqlite3_column_int64(row, 11) == revision, sqlite3_column_int(row, 12) == 0,
                  (sqlite3_column_int(row, 13) != 0) == redacted,
                  (sqlite3_column_int(row, 14) != 0) == unavailable else {
                throw ScreenEvidenceFeedError.integrityFailure
            }
        }
        return Record(reference: ScreenEvidenceRef(storeID: feed.storeID, source: .native,
            observationID: observationID, frameID: .init(value: frameID), extractionRevision: revision),
            sequence: sequence, state: redacted || unavailable ? .invalidated : .blocked)
    }

    private static func currentRecord(_ db: OpaquePointer, event: Event,
                                      feed: ScreenEvidenceFeedStatus) throws -> Record {
        let states = try PipelineSQL.query(db, """
            SELECT frameID,latestSequence,extractionRevision,deleted,
              EXISTS(SELECT 1 FROM screen_deleted d WHERE d.storeID=s.storeID
                AND d.observationID=s.observationID AND d.frameID=s.frameID)
            FROM screen_evidence_source_state s WHERE storeID=? AND observationID=?
            """, [.text(feed.storeID.uuidString), .text(event.observationID.uuidString)]) { row in
            (frame: sqlite3_column_int64(row, 0), sequence: sqlite3_column_int64(row, 1),
             revision: sqlite3_column_int64(row, 2), deleted: sqlite3_column_int(row, 3) != 0,
             tombstone: sqlite3_column_int(row, 4) != 0)
        }
        guard let state = states.first, states.count == 1, state.frame == event.frameID,
              state.sequence >= event.sequence, state.sequence <= feed.latestSequence,
              state.revision >= event.revision else { throw ScreenEvidenceFeedError.integrityFailure }
        if state.deleted {
            guard state.tombstone else { throw ScreenEvidenceFeedError.integrityFailure }
            return Record(reference: ScreenEvidenceRef(storeID: feed.storeID, source: .native,
                observationID: event.observationID, frameID: .init(value: state.frame), extractionRevision: state.revision),
                sequence: state.sequence, state: .deleted)
        }
        guard !state.tombstone else { throw ScreenEvidenceFeedError.integrityFailure }
        let records = try PipelineSQL.query(db, """
            \(observationQuery) WHERE o.storeID=? AND o.observationID=?
            """, [.text(feed.storeID.uuidString), .text(event.observationID.uuidString)]) { try decodeObservation($0, feed: feed) }
        guard let record = records.first, records.count == 1,
              record.reference.frameID.value == state.frame, record.reference.extractionRevision == state.revision,
              record.sequence == state.sequence else { throw ScreenEvidenceFeedError.integrityFailure }
        return record
    }

    private static func writeWork(_ db: OpaquePointer, record: Record,
                                  consumer: ScreenEvidenceConsumerStatus) throws {
        for channel in ["lexical", "vector"] {
            try PipelineSQL.execute(db, """
                INSERT INTO screen_evidence_work(consumerID,storeID,observationID,frameID,leaseID,channel,
                  extractionRevision,sourceSequence,state) VALUES(?,?,?,?,?,?,?,?,?)
                ON CONFLICT(consumerID,storeID,observationID,channel) DO UPDATE SET
                  leaseID=excluded.leaseID,extractionRevision=excluded.extractionRevision,
                  sourceSequence=excluded.sourceSequence,state=excluded.state
                WHERE screen_evidence_work.frameID=excluded.frameID
                  AND screen_evidence_work.extractionRevision<=excluded.extractionRevision
                  AND screen_evidence_work.sourceSequence<=excluded.sourceSequence
                  AND (screen_evidence_work.state<>'deleted' OR excluded.state='deleted')
                """, [.text(consumer.cursor.consumerID.uuidString), .text(record.reference.storeID.uuidString),
                    .text(record.reference.observationID.uuidString), .integer(record.reference.frameID.value),
                    .text(consumer.cursor.leaseID.uuidString), .text(channel),
                    .integer(record.reference.extractionRevision), .integer(record.sequence), .text(record.state.rawValue)])
            guard sqlite3_changes(db) == 1 else { throw ScreenEvidenceFeedError.integrityFailure }
        }
    }

    private static func readConsumer(_ db: OpaquePointer, consumerID: UUID) throws -> ScreenEvidenceConsumerStatus? {
        try PipelineSQL.query(db, "SELECT \(consumerColumns) FROM screen_evidence_consumer WHERE consumerID=?",
                              [.text(consumerID.uuidString)], map: decodeConsumer).first
    }

    private static func requireConsumer(_ db: OpaquePointer, cursor: ScreenEvidenceConsumerCursor,
                                        feed: ScreenEvidenceFeedStatus) throws -> ScreenEvidenceConsumerStatus {
        guard let state = try readConsumer(db, consumerID: cursor.consumerID), state.cursor == cursor else {
            throw ScreenEvidenceFeedError.invalidCursor
        }
        try validate(state, feed: feed)
        return state
    }

    private static func decodeConsumer(_ row: OpaquePointer) throws -> ScreenEvidenceConsumerStatus {
        guard let consumerID = UUID(uuidString: RecallSQL.string(row, 0)),
              let feedID = UUID(uuidString: RecallSQL.string(row, 1)),
              let storeID = UUID(uuidString: RecallSQL.string(row, 2)),
              let leaseID = UUID(uuidString: RecallSQL.string(row, 3)),
              let phase = ScreenEvidenceConsumerPhase(rawValue: RecallSQL.string(row, 4)) else {
            throw ScreenEvidenceFeedError.integrityFailure
        }
        return ScreenEvidenceConsumerStatus(cursor: .init(feedID: feedID, storeID: storeID, consumerID: consumerID, leaseID: leaseID),
            phase: phase, boundarySequence: sqlite3_column_int64(row, 5), maximumFrameID: sqlite3_column_int64(row, 6),
            lastFrameID: sqlite3_column_int64(row, 7), checkpointSequence: sqlite3_column_int64(row, 8),
            expiresAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 9)))
    }

    private static func validate(_ consumer: ScreenEvidenceConsumerStatus, feed: ScreenEvidenceFeedStatus) throws {
        guard consumer.cursor.feedID == feed.feedID, consumer.cursor.storeID == feed.storeID,
              consumer.boundarySequence >= 0, consumer.boundarySequence <= feed.latestSequence,
              consumer.checkpointSequence >= consumer.boundarySequence, consumer.checkpointSequence <= feed.latestSequence,
              consumer.maximumFrameID >= 0, consumer.lastFrameID >= 0, consumer.lastFrameID <= consumer.maximumFrameID,
              consumer.phase != .bootstrap || consumer.checkpointSequence == consumer.boundarySequence,
              consumer.expiresAt.timeIntervalSince1970.isFinite else { throw ScreenEvidenceFeedError.integrityFailure }
    }

    private static func contiguous(_ sequences: [Int64], after lower: Int64, through upper: Int64, limit: Int) -> Bool {
        var previous = lower
        for sequence in sequences {
            guard previous < Int64.max, sequence == previous + 1, sequence <= upper else { return false }
            previous = sequence
        }
        return sequences.count == limit || previous == upper
    }

    private static func position(_ consumer: ScreenEvidenceConsumerStatus) -> Int64 {
        consumer.phase == .bootstrap ? consumer.boundarySequence : consumer.checkpointSequence
    }

    private static func validateClock(_ date: Date) throws {
        guard date.timeIntervalSince1970.isFinite else { throw ScreenEvidenceFeedError.integrityFailure }
    }

    private static func expire(_ db: OpaquePointer, _ consumer: ScreenEvidenceConsumerStatus) throws {
        guard consumer.phase != .expired else { return }
        try PipelineSQL.execute(db, "UPDATE screen_evidence_consumer SET phase='expired' WHERE consumerID=? AND leaseID=?",
                                [.text(consumer.cursor.consumerID.uuidString), .text(consumer.cursor.leaseID.uuidString)])
        guard sqlite3_changes(db) == 1 else { throw ScreenEvidenceFeedError.integrityFailure }
    }

    private static func savePosition(_ db: OpaquePointer, _ consumer: ScreenEvidenceConsumerStatus) throws {
        try PipelineSQL.execute(db, """
            UPDATE screen_evidence_consumer SET phase=?,lastFrameID=?,checkpoint=? WHERE consumerID=? AND leaseID=?
            """, [.text(consumer.phase.rawValue), .integer(consumer.lastFrameID), .integer(consumer.checkpointSequence),
                    .text(consumer.cursor.consumerID.uuidString), .text(consumer.cursor.leaseID.uuidString)])
        guard sqlite3_changes(db) == 1 else { throw ScreenEvidenceFeedError.integrityFailure }
    }

    private static func replacing(_ consumer: ScreenEvidenceConsumerStatus, phase: ScreenEvidenceConsumerPhase? = nil,
                                  lastFrameID: Int64? = nil, checkpoint: Int64? = nil) -> ScreenEvidenceConsumerStatus {
        ScreenEvidenceConsumerStatus(cursor: consumer.cursor, phase: phase ?? consumer.phase,
            boundarySequence: consumer.boundarySequence, maximumFrameID: consumer.maximumFrameID,
            lastFrameID: lastFrameID ?? consumer.lastFrameID, checkpointSequence: checkpoint ?? consumer.checkpointSequence,
            expiresAt: consumer.expiresAt)
    }

    private static func values(_ consumer: ScreenEvidenceConsumerStatus) -> [PipelineSQL.Value] {
        [.text(consumer.cursor.consumerID.uuidString), .text(consumer.cursor.feedID.uuidString),
         .text(consumer.cursor.storeID.uuidString), .text(consumer.cursor.leaseID.uuidString), .text(consumer.phase.rawValue),
         .integer(consumer.boundarySequence), .integer(consumer.maximumFrameID), .integer(consumer.lastFrameID),
         .integer(consumer.checkpointSequence), .real(consumer.expiresAt.timeIntervalSince1970)]
    }
}
