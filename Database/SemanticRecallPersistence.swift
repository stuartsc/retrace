import CryptoKit
import Foundation
import SQLCipher
import Shared

extension DatabaseManager: SemanticRecallStoreProtocol {
    public func beginSemanticRecall(transformation: SemanticRecallTransformation,
                                    leaseDuration: TimeInterval) async throws -> SemanticRecallCursor {
        try SemanticRecallSQL.begin(requireAdmissionConnection(), capability: &screenEvidenceAdmissionCapability,
                                    transformation: transformation, leaseDuration: leaseDuration)
    }
    public func claimSemanticRecallWork(cursor: SemanticRecallCursor, maximumInspected: Int,
                                        executionDuration: TimeInterval) async throws -> SemanticRecallWorkPage {
        try SemanticRecallSQL.claim(requireAdmissionConnection(), capability: &screenEvidenceAdmissionCapability,
                                    cursor: cursor, maximumInspected: maximumInspected, executionDuration: executionDuration)
    }
    public func publishSemanticRecall(claim: SemanticRecallClaim,
                                      windows: [SemanticRecallVectorWindow]) async throws -> SemanticRecallPublication {
        try SemanticRecallSQL.publish(requireAdmissionConnection(), capability: &screenEvidenceAdmissionCapability,
                                      claim: claim, windows: windows)
    }
    public func cancelSemanticRecall(claim: SemanticRecallClaim) async throws {
        try SemanticRecallSQL.cancel(requireAdmissionConnection(), capability: &screenEvidenceAdmissionCapability, claim: claim)
    }
    public func semanticRecallCoverage(cursor: SemanticRecallCursor) async throws -> SemanticRecallCoverage {
        try SemanticRecallSQL.coverage(requireAdmissionConnection(), capability: &screenEvidenceAdmissionCapability, cursor: cursor)
    }
    public func readSemanticRecallVectors(request: SemanticRecallVectorReadRequest) async throws -> SemanticRecallVectorPage {
        try SemanticRecallSQL.read(requireAdmissionConnection(), capability: &screenEvidenceAdmissionCapability, request: request)
    }
    public func revalidateSemanticRecallRead(stamp: SemanticRecallReadStamp) async throws {
        try SemanticRecallSQL.revalidate(requireAdmissionConnection(), capability: &screenEvidenceAdmissionCapability, stamp: stamp)
    }
}

/// The actor writer and private SQLCipher regressions share this engine. No
/// transaction awaits inference, another actor, a callback, or a clock sleep.
/// The App owner records categorical metrics after these operations complete.
enum SemanticRecallSQL {
    private static let pageBytes = 4096
    private static let pageFragments = 64
    private static let maximumLease: TimeInterval = 7 * 24 * 60 * 60

    static func begin(_ db: OpaquePointer, capability: inout ScreenEvidenceAdmissionCapability,
                      transformation: SemanticRecallTransformation, leaseDuration: TimeInterval,
                      clock: ScreenEvidenceAdmissionClock? = nil) throws -> SemanticRecallCursor {
        try Task.checkCancellation()
        try validate(transformation)
        guard leaseDuration.isFinite, leaseDuration > 0, leaseDuration <= maximumLease else {
            throw SemanticRecallError.invalidLimits
        }
        return try PipelineSQL.transaction(db) {
            let now = try instant(clock).date
            let state = try ScreenEvidenceAdmissionSQL.requireActive(db, capability: capability)
            let policy = try transition(state)
            if let old = try index(db, hash: transformation.fingerprintSHA256) {
                try validate(old, state: state)
                if old.writerID == policy.session.writerID, old.expiresAt > now { return old.cursor }
                let cursor = SemanticRecallCursor(indexID: old.cursor.indexID, feedID: state.feed.feedID,
                                                   storeID: state.feed.storeID, leaseID: UUID())
                // Only attempts need a fresh incarnation. Completed vectors and
                // fixed historical/fresh checkpoints retain their content identity.
                try PipelineSQL.execute(db, "DELETE FROM semantic_recall_attempt WHERE indexID=? AND status='claimed'",
                                        [.text(cursor.indexID.uuidString)])
                try PipelineSQL.execute(db, """
                    UPDATE semantic_recall_index SET writerID=?,leaseID=?,expiresAt=? WHERE indexID=?
                    """, [.text(policy.session.writerID.uuidString), .text(cursor.leaseID.uuidString),
                            .real(now.addingTimeInterval(leaseDuration).timeIntervalSince1970), .text(cursor.indexID.uuidString)])
                try Task.checkCancellation()
                return cursor
            }
            let cursor = SemanticRecallCursor(indexID: UUID(), feedID: state.feed.feedID,
                                               storeID: state.feed.storeID, leaseID: UUID())
            let maximum = try maximumFrameID(db, storeID: state.feed.storeID)
            try PipelineSQL.execute(db, """
                INSERT INTO semantic_recall_index(indexID,feedID,storeID,transformSHA256,transformPayload,policySHA256,
                  writerID,leaseID,expiresAt,boundarySequence,freshSequence,maximumFrameID,lastFrameID,backfillComplete)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,0,?)
                """, [.text(cursor.indexID.uuidString), .text(cursor.feedID.uuidString), .text(cursor.storeID.uuidString),
                    .text(transformation.fingerprintSHA256), .text(try json(transformation, limit: 4096)),
                    .text(policy.policySHA256), .text(policy.session.writerID.uuidString), .text(cursor.leaseID.uuidString),
                    .real(now.addingTimeInterval(leaseDuration).timeIntervalSince1970),
                    .integer(state.feed.latestSequence), .integer(state.feed.latestSequence), .integer(maximum),
                    .integer(maximum == 0 ? 1 : 0)])
            try Task.checkCancellation()
            return cursor
        }
    }

    static func claim(_ db: OpaquePointer, capability: inout ScreenEvidenceAdmissionCapability,
                      cursor: SemanticRecallCursor, maximumInspected: Int, executionDuration: TimeInterval,
                      clock: ScreenEvidenceAdmissionClock? = nil) throws -> SemanticRecallWorkPage {
        try Task.checkCancellation()
        guard (1...200).contains(maximumInspected), executionDuration.isFinite,
              executionDuration > 0, executionDuration <= 30 else { throw SemanticRecallError.invalidLimits }
        return try PipelineSQL.transaction(db) {
            let started = try instant(clock)
            let state = try ScreenEvidenceAdmissionSQL.requireActive(db, capability: capability)
            let owner = try requireIndex(db, cursor: cursor, state: state, now: started.date)
            try pruneAttempts(db, owner: owner, state: state, now: started)
            let pendingAttempts = try PipelineSQL.integers(db,
                "SELECT COUNT(*) FROM semantic_recall_attempt WHERE indexID=? AND status='claimed'", [.text(cursor.indexID.uuidString)])
            guard pendingAttempts.first == 0 else { throw SemanticRecallError.attemptInProgress }
            var inspected = 0

            func result(_ input: SemanticRecallInput? = nil) throws -> SemanticRecallWorkPage {
                let attempt = try input.map { try requireAttempt(db, claim: $0.claim) }
                let currentCoverage = try coverageRow(db, owner: cursor, state: state)
                let finished = try instant(clock)
                guard owner.expiresAt > finished.date else { throw SemanticRecallError.cursorExpired }
                if let input, let attempt {
                    try validateExecution(input.claim, uptimeDeadline: attempt.uptimeDeadline, owner: owner,
                                          clock: .init(sample: { finished }))
                }
                try Task.checkCancellation()
                return .init(input: input, inspectedCount: inspected, coverage: currentCoverage)
            }
            func acquire(_ document: Document) throws -> SemanticRecallInput? {
                try makeClaim(db, owner: owner, state: state, document: document, started: started,
                              executionDuration: executionDuration, clock: clock)
            }

            // Coalesced source state is durable beyond raw feed compaction. Its
            // latestSequence is monotonically assigned by the V22 publication
            // trigger; deleted/unavailable changes advance this cursor as well.
            let fresh = try sourceTail(db, state: state, after: owner.freshSequence, limit: maximumInspected)
            for source in fresh {
                try Task.checkCancellation()
                inspected += 1
                try PipelineSQL.execute(db, "UPDATE semantic_recall_index SET freshSequence=? WHERE indexID=?",
                                        [.integer(source.sequence), .text(cursor.indexID.uuidString)])
                let document = try queue(db, owner: owner, source: source, lane: .fresh)
                if document.status == "pending", let input = try acquire(document) { return try result(input) }
            }
            if inspected == maximumInspected { return try result() }

            // A newer source event always gets its first page before a prior
            // partial observation resumes. Historical progress is never inferred
            // from the absence of eligible fresh input.
            for lane in [SemanticRecallLane.fresh, .backfill] {
                while inspected < maximumInspected, let document = try nextPending(db, indexID: cursor.indexID, lane: lane) {
                    inspected += 1
                    if let input = try acquire(document) { return try result(input) }
                }
            }
            if inspected == maximumInspected { return try result() }
            let current = try requireIndex(db, cursor: cursor, state: state, now: started.date)
            if !current.backfillComplete {
                let available = maximumInspected - inspected
                let history = try historical(db, state: state, after: current.lastFrameID,
                                             through: current.maximumFrameID, limit: available)
                if history.isEmpty {
                    try PipelineSQL.execute(db, "UPDATE semantic_recall_index SET lastFrameID=maximumFrameID,backfillComplete=1 WHERE indexID=?",
                                            [.text(cursor.indexID.uuidString)])
                }
                for (offset, source) in history.enumerated() {
                    try Task.checkCancellation()
                    inspected += 1
                    let finished = source.reference.frameID.value == current.maximumFrameID ||
                        (offset == history.count - 1 && history.count < available)
                    try PipelineSQL.execute(db, "UPDATE semantic_recall_index SET lastFrameID=?,backfillComplete=? WHERE indexID=?",
                        [.integer(source.reference.frameID.value), .integer(finished ? 1 : 0), .text(cursor.indexID.uuidString)])
                    let document = try queue(db, owner: owner, source: source, lane: .backfill)
                    if document.status == "pending", let input = try acquire(document) { return try result(input) }
                }
            }
            return try result()
        }
    }

    static func publish(_ db: OpaquePointer, capability: inout ScreenEvidenceAdmissionCapability,
                        claim: SemanticRecallClaim, windows: [SemanticRecallVectorWindow],
                        clock: ScreenEvidenceAdmissionClock? = nil) throws -> SemanticRecallPublication {
        try Task.checkCancellation()
        guard windows.count <= 32 else { throw SemanticRecallError.invalidLimits }
        return try PipelineSQL.transaction(db) {
            let state = try ScreenEvidenceAdmissionSQL.requireActive(db, capability: capability, expected: claim.policy)
            let owner = try requireIndex(db, cursor: claim.cursor, state: state, now: instant(clock).date)
            let attempt = try requireAttempt(db, claim: claim)
            if attempt.status == "cancelled" { throw SemanticRecallError.claimCancelled }
            let document = try requireDocument(db, claim: claim)
            let projection = try ScreenEvidenceAdmissionSQL.projectInput(db, expansion: claim.expansion, state: state,
                retainedSourceSequence: claim.sourceSequence, retainedMetadataEpoch: claim.metadataEpoch)
            guard projection.hash == claim.inputSHA256, projection.nextCursor == claim.nextExpansion,
                  owner.transformation == claim.transformation else { throw SemanticRecallError.sourceChanged }
            let input = compose(claim: claim, page: projection.page)
            let encoded = try validate(windows: windows, input: input)
            let digest = sha256(Data(try json(windows, limit: 2_097_152).utf8))
            if attempt.status == "published" {
                guard attempt.resultHash == digest, let receipt = attempt.result else { throw SemanticRecallError.conflictingResult }
                try Task.checkCancellation()
                return receipt
            }
            guard document.status == "pending", document.pageCount == claim.pageOrdinal,
                  document.nextCursor == claim.expansion.cursor else { throw SemanticRecallError.sourceChanged }
            try validateExecution(claim, uptimeDeadline: attempt.uptimeDeadline, owner: owner, clock: clock)
            try PipelineSQL.execute(db, """
                INSERT INTO semantic_recall_page(indexID,observationID,pageOrdinal,expansionPayload,inputSHA256,windowCount)
                VALUES(?,?,?,?,?,?)
                """, [.text(claim.cursor.indexID.uuidString), .text(claim.reference.observationID.uuidString),
                    .integer(Int64(claim.pageOrdinal)), .text(try json(claim.expansion)),
                    .text(claim.inputSHA256), .integer(Int64(windows.count))])
            for (ordinal, window) in windows.enumerated() {
                try PipelineSQL.execute(db, """
                    INSERT INTO semantic_recall_window(indexID,observationID,pageOrdinal,windowOrdinal,tokenStart,tokenEnd,
                      inputLocation,inputLength,spansPayload,vector,vectorSHA256) VALUES(?,?,?,?,?,?,?,?,?,?,?)
                    """, [.text(claim.cursor.indexID.uuidString), .text(claim.reference.observationID.uuidString),
                        .integer(Int64(claim.pageOrdinal)), .integer(Int64(ordinal)), .integer(Int64(window.tokenStart)),
                        .integer(Int64(window.tokenEnd)), .integer(Int64(window.inputUTF16Range.location)),
                        .integer(Int64(window.inputUTF16Range.length)), .text(try json(window.spans)),
                        .blob(encoded[ordinal]), .text(sha256(encoded[ordinal]))])
            }
            let complete = claim.nextExpansion == nil
            let total = try PipelineSQL.integers(db,
                "SELECT COUNT(*) FROM semantic_recall_window WHERE indexID=? AND observationID=?",
                [.text(claim.cursor.indexID.uuidString), .text(claim.reference.observationID.uuidString)]).first ?? 0
            let status = complete ? (total == 0 ? "empty" : "complete") : "pending"
            let nextPayload = try claim.nextExpansion.map { try json($0) } ?? ""
            try PipelineSQL.execute(db, """
                UPDATE semantic_recall_document SET pageCount=pageCount+1,nextCursor=NULLIF(?,''),status=? WHERE indexID=? AND observationID=?
                """, [.text(nextPayload),
                    .text(status), .text(claim.cursor.indexID.uuidString), .text(claim.reference.observationID.uuidString)])
            let receipt = SemanticRecallPublication(reference: claim.reference, pageOrdinal: claim.pageOrdinal,
                                                     windowCount: windows.count, observationComplete: complete)
            try PipelineSQL.execute(db, """
                UPDATE semantic_recall_attempt SET status='published',resultSHA256=?,resultPayload=? WHERE attemptID=?
                """, [.text(digest), .text(try json(receipt)), .text(claim.attemptID.uuidString)])
            try PipelineSQL.execute(db, "UPDATE semantic_recall_index SET generation=generation+1 WHERE indexID=?",
                                    [.text(claim.cursor.indexID.uuidString)])
            try validateExecution(claim, uptimeDeadline: attempt.uptimeDeadline, owner: owner, clock: clock)
            try Task.checkCancellation()
            return receipt
        }
    }

    static func cancel(_ db: OpaquePointer, capability: inout ScreenEvidenceAdmissionCapability,
                       claim: SemanticRecallClaim) throws {
        // Cancellation drains even if its task was cancelled. A no-op succeeds
        // only when canonical SQLite proves absence or exact retired identity;
        // a stale writer still cannot cancel any active replacement attempt.
        try PipelineSQL.transaction(db) {
            let rows = try PipelineSQL.query(db, "SELECT \(attemptColumns) FROM semantic_recall_attempt WHERE attemptID=?",
                                            [.text(claim.attemptID.uuidString)], map: decodeAttempt)
            guard let attempt = rows.first else { return }
            guard rows.count == 1, attempt.claim == claim else { throw SemanticRecallError.invalidClaim }
            guard attempt.status == "claimed" else { return }
            guard capability.session == claim.policy.session else { throw ScreenEvidenceAdmissionError.staleSession }
            try PipelineSQL.execute(db, "UPDATE semantic_recall_attempt SET status='cancelled' WHERE attemptID=? AND status='claimed'",
                                    [.text(claim.attemptID.uuidString)])
        }
    }

    static func coverage(_ db: OpaquePointer, capability: inout ScreenEvidenceAdmissionCapability,
                         cursor: SemanticRecallCursor, clock: ScreenEvidenceAdmissionClock? = nil) throws -> SemanticRecallCoverage {
        try Task.checkCancellation()
        return try PipelineSQL.transaction(db) {
            let state = try ScreenEvidenceAdmissionSQL.requireActive(db, capability: capability)
            _ = try requireIndex(db, cursor: cursor, state: state, now: instant(clock).date)
            return try coverageRow(db, owner: cursor, state: state)
        }
    }

    static func revalidate(_ db: OpaquePointer, capability: inout ScreenEvidenceAdmissionCapability,
                           stamp: SemanticRecallReadStamp) throws {
        try Task.checkCancellation()
        try PipelineSQL.transaction(db) {
            let state = try ScreenEvidenceAdmissionSQL.requireActive(db, capability: capability)
            guard let owner = try index(db, id: stamp.indexID) else { throw SemanticRecallError.staleRead }
            try validate(owner, state: state)
            guard try readStamp(owner, state: state) == stamp else { throw SemanticRecallError.staleRead }
            try Task.checkCancellation()
        }
    }

    static func read(_ db: OpaquePointer, capability: inout ScreenEvidenceAdmissionCapability,
                     request: SemanticRecallVectorReadRequest,
                     clock: ScreenEvidenceAdmissionClock? = nil) throws -> SemanticRecallVectorPage {
        try Task.checkCancellation()
        try validate(request.transformation)
        try validateFilter(request.filter)
        guard (1...256).contains(request.maximumWindows), (1...512).contains(request.maximumInspected),
              request.cursor.map({ $0.afterRowID >= 0 && $0.filter == request.filter }) ?? true else {
            throw SemanticRecallError.invalidLimits
        }
        return try PipelineSQL.transaction(db) {
            _ = try instant(clock)
            let state = try ScreenEvidenceAdmissionSQL.requireActive(db, capability: capability)
            guard let owner = try index(db, hash: request.transformation.fingerprintSHA256) else { throw SemanticRecallError.invalidCursor }
            try validate(owner, state: state)
            let stamp = try readStamp(owner, state: state)
            if let cursor = request.cursor, cursor.stamp != stamp { throw SemanticRecallError.staleRead }
            var conditions = ["w.indexID=?", "w.rowID>?", "d.status='complete'", "d.policySHA256=?"]
            var values: [PipelineSQL.Value] = [.text(owner.cursor.indexID.uuidString),
                .integer(request.cursor?.afterRowID ?? 0), .text(owner.policyHash)]
            if let from = request.filter.from { conditions.append("f.createdAt>=?"); values.append(.integer(Schema.dateToTimestamp(from))) }
            if let through = request.filter.through { conditions.append("f.createdAt<=?"); values.append(.integer(Schema.dateToTimestamp(through))) }
            if !request.filter.appBundleIDs.isEmpty {
                conditions.append("g.bundleID IN (\(Array(repeating: "?", count: request.filter.appBundleIDs.count).joined(separator: ",")))")
                values += request.filter.appBundleIDs.map(PipelineSQL.Value.text)
            }
            if !request.filter.excludedAppBundleIDs.isEmpty {
                conditions.append("COALESCE(g.bundleID,'') NOT IN (\(Array(repeating: "?", count: request.filter.excludedAppBundleIDs.count).joined(separator: ",")))")
                values += request.filter.excludedAppBundleIDs.map(PipelineSQL.Value.text)
            }
            // These are current user visibility filters, not embedding policy.
            // Apply them before both inspection and candidate budgets. Tag
            // mutations invalidate the generation stamp without re-embedding.
            let hidden = """
                EXISTS (SELECT 1 FROM segment_tag st JOIN tag t ON t.id=st.tagId
                  WHERE st.segmentId=f.segmentId AND t.name='hidden')
                """
            switch request.filter.hiddenFilter {
            case .hide: conditions.append("NOT (\(hidden))")
            case .onlyHidden: conditions.append(hidden)
            case .showAll: break
            }
            values.append(.integer(Int64(request.maximumInspected + 1)))
            let rows = try PipelineSQL.query(db, """
                SELECT w.rowID,d.referencePayload,d.sourceSequence,w.pageOrdinal,w.windowOrdinal,w.tokenStart,w.tokenEnd,
                  w.inputLocation,w.inputLength,w.spansPayload,w.vector,w.vectorSHA256,p.expansionPayload,p.inputSHA256
                FROM semantic_recall_window w
                JOIN semantic_recall_document d ON d.indexID=w.indexID AND d.observationID=w.observationID
                JOIN semantic_recall_page p ON p.indexID=w.indexID AND p.observationID=w.observationID AND p.pageOrdinal=w.pageOrdinal
                JOIN frame f ON f.id=d.frameID LEFT JOIN segment g ON g.id=f.segmentId
                WHERE \(conditions.joined(separator: " AND ")) ORDER BY w.rowID LIMIT ?
                """, values, map: decodeCandidate)
            var candidates: [SemanticRecallVectorCandidate] = []
            var inspected = 0
            var after = request.cursor?.afterRowID ?? 0
            // Page cache is bounded by this read's inspection limit. It contains
            // no live history beyond the currently authorised transaction.
            var pages: [String: ScreenEvidenceAdmissionSQL.Input] = [:]
            for row in rows.prefix(request.maximumInspected) {
                try Task.checkCancellation()
                inspected += 1; after = row.rowID
                let key = "\(row.reference.observationID.uuidString):\(row.pageOrdinal)"
                let projection: ScreenEvidenceAdmissionSQL.Input
                do {
                    if let cached = pages[key] { projection = cached }
                    else {
                        projection = try ScreenEvidenceAdmissionSQL.projectInput(db, expansion: row.expansion, state: state,
                                                                               retainedSourceSequence: row.sourceSequence)
                        pages[key] = projection
                    }
                } catch let error as ScreenEvidenceAdmissionError {
                    if error == .notPermitted || error == .sourceChanged || error == .invalidReference { continue }
                    throw error
                }
                guard projection.hash == row.inputHash else { throw SemanticRecallError.integrityFailure }
                let content = composeContent(page: projection.page)
                guard try SemanticRecallInput.spans(in: content.text, fragments: content.spans,
                                                    for: row.window.inputUTF16Range) == row.window.spans else {
                    throw SemanticRecallError.integrityFailure
                }
                candidates.append(.init(rowID: row.rowID, reference: row.reference,
                    captureTimestamp: projection.page.captureTimestamp, pageOrdinal: row.pageOrdinal,
                    windowOrdinal: row.windowOrdinal, window: row.window))
                if candidates.count == request.maximumWindows { break }
            }
            let more = inspected < rows.count
            let next = more ? SemanticRecallVectorCursor(stamp: stamp, filter: request.filter, afterRowID: after) : nil
            try Task.checkCancellation()
            return .init(stamp: stamp, candidates: candidates, inspectedCount: inspected, nextCursor: next)
        }
    }

    private struct Index {
        let cursor: SemanticRecallCursor
        let transformation: SemanticRecallTransformation
        let policyHash: String
        let writerID: UUID
        let expiresAt: Date
        let boundarySequence: Int64
        let freshSequence: Int64
        let maximumFrameID: Int64
        let lastFrameID: Int64
        let backfillComplete: Bool
        let generation: Int64
        let completed: Int
        let empty: Int
        let pending: Int
        let skipped: Int
        let windows: Int
    }

    private static let indexColumns = """
        indexID,feedID,storeID,leaseID,transformSHA256,transformPayload,policySHA256,writerID,expiresAt,
        boundarySequence,freshSequence,maximumFrameID,lastFrameID,backfillComplete,generation,
        completedCount,emptyCount,pendingCount,skippedCount,windowCount
        """

    private static func index(_ db: OpaquePointer, id: UUID) throws -> Index? {
        try PipelineSQL.query(db, "SELECT \(indexColumns) FROM semantic_recall_index WHERE indexID=?",
                              [.text(id.uuidString)], map: decodeIndex).first
    }
    private static func index(_ db: OpaquePointer, hash: String) throws -> Index? {
        try PipelineSQL.query(db, "SELECT \(indexColumns) FROM semantic_recall_index WHERE transformSHA256=?",
                              [.text(hash)], map: decodeIndex).first
    }
    private static func decodeIndex(_ row: OpaquePointer) throws -> Index {
        let cursor = SemanticRecallCursor(indexID: try uuid(row, 0), feedID: try uuid(row, 1),
                                          storeID: try uuid(row, 2), leaseID: try uuid(row, 3))
        let transformation = try decode(SemanticRecallTransformation.self, row, 5, limit: 4096)
        try validate(transformation)
        guard transformation.fingerprintSHA256 == RecallSQL.string(row, 4) else { throw SemanticRecallError.integrityFailure }
        let expiry = Date(timeIntervalSince1970: sqlite3_column_double(row, 8))
        let boundary = sqlite3_column_int64(row, 9), fresh = sqlite3_column_int64(row, 10)
        let maximum = sqlite3_column_int64(row, 11), last = sqlite3_column_int64(row, 12)
        let finished = sqlite3_column_int(row, 13), generation = sqlite3_column_int64(row, 14)
        guard expiry.timeIntervalSince1970.isFinite, boundary >= 0, fresh >= boundary,
              maximum >= 0, last >= 0, last <= maximum, finished == 0 || finished == 1, generation >= 0 else {
            throw SemanticRecallError.integrityFailure
        }
        let counts = (15...19).map { Int(sqlite3_column_int64(row, Int32($0))) }
        guard counts.allSatisfy({ $0 >= 0 }) else { throw SemanticRecallError.integrityFailure }
        return Index(cursor: cursor, transformation: transformation, policyHash: RecallSQL.string(row, 6),
            writerID: try uuid(row, 7), expiresAt: expiry, boundarySequence: boundary, freshSequence: fresh,
            maximumFrameID: maximum, lastFrameID: last, backfillComplete: finished == 1, generation: generation,
            completed: counts[0], empty: counts[1], pending: counts[2], skipped: counts[3], windows: counts[4])
    }
    private static func validate(_ owner: Index, state: ScreenEvidenceAdmissionSQL.State) throws {
        guard owner.cursor.feedID == state.feed.feedID, owner.cursor.storeID == state.feed.storeID,
              owner.policyHash == state.transition?.policySHA256, owner.freshSequence <= state.feed.latestSequence else {
            throw SemanticRecallError.integrityFailure
        }
    }
    private static func requireIndex(_ db: OpaquePointer, cursor: SemanticRecallCursor,
                                     state: ScreenEvidenceAdmissionSQL.State, now: Date) throws -> Index {
        guard let owner = try index(db, id: cursor.indexID), owner.cursor == cursor,
              owner.writerID == state.session?.writerID else { throw SemanticRecallError.invalidCursor }
        try validate(owner, state: state)
        guard owner.expiresAt > now else { throw SemanticRecallError.cursorExpired }
        return owner
    }
    private static func coverageRow(_ db: OpaquePointer, owner cursor: SemanticRecallCursor,
                                    state: ScreenEvidenceAdmissionSQL.State) throws -> SemanticRecallCoverage {
        guard let owner = try index(db, id: cursor.indexID) else { throw SemanticRecallError.invalidCursor }
        try validate(owner, state: state)
        return .init(cursor: owner.cursor, transformation: owner.transformation,
            boundarySequence: owner.boundarySequence, freshSequence: owner.freshSequence, latestSequence: state.feed.latestSequence,
            maximumBackfillFrameID: owner.maximumFrameID, lastBackfillFrameID: owner.lastFrameID,
            backfillComplete: owner.backfillComplete, completedObservations: owner.completed, emptyObservations: owner.empty,
            pendingObservations: owner.pending, skippedObservations: owner.skipped, publishedWindows: owner.windows)
    }
    private static func maximumFrameID(_ db: OpaquePointer, storeID: UUID) throws -> Int64 {
        try PipelineSQL.integers(db, "SELECT COALESCE(MAX(frameID),0) FROM screen_observation WHERE storeID=? AND source='native'",
                                 [.text(storeID.uuidString)]).first ?? 0
    }

    private struct Source {
        let reference: ScreenEvidenceRef
        let sequence: Int64
        let unavailable: Bool
    }
    private static func sourceTail(_ db: OpaquePointer, state: ScreenEvidenceAdmissionSQL.State,
                                   after sequence: Int64, limit: Int) throws -> [Source] {
        try PipelineSQL.query(db, """
            SELECT observationID,frameID,extractionRevision,latestSequence,
              deleted OR redacted OR mediaUnavailableReason IS NOT NULL
            FROM screen_evidence_source_state WHERE storeID=? AND latestSequence>? ORDER BY latestSequence LIMIT ?
            """, [.text(state.feed.storeID.uuidString), .integer(sequence), .integer(Int64(limit))]) {
                try decodeSource($0, state: state)
            }
    }
    private static func historical(_ db: OpaquePointer, state: ScreenEvidenceAdmissionSQL.State,
                                   after frameID: Int64, through maximum: Int64, limit: Int) throws -> [Source] {
        try PipelineSQL.query(db, """
            SELECT o.observationID,o.frameID,o.preferredRevision,COALESCE(s.latestSequence,0),
              COALESCE(s.deleted,0) OR f.id IS NULL OR f.redactionReason IS NOT NULL OR m.frameID IS NOT NULL
            FROM screen_observation o LEFT JOIN screen_evidence_source_state s
              ON s.storeID=o.storeID AND s.observationID=o.observationID
            LEFT JOIN frame f ON f.id=o.nativeFrameID LEFT JOIN frame_media_unavailable m ON m.frameID=f.id
            WHERE o.storeID=? AND o.source='native' AND o.frameID>? AND o.frameID<=? ORDER BY o.frameID LIMIT ?
            """, [.text(state.feed.storeID.uuidString), .integer(frameID), .integer(maximum), .integer(Int64(limit))]) {
                try decodeSource($0, state: state)
            }
    }
    private static func decodeSource(_ row: OpaquePointer, state: ScreenEvidenceAdmissionSQL.State) throws -> Source {
        let frameID = sqlite3_column_int64(row, 1), revision = sqlite3_column_int64(row, 2), sequence = sqlite3_column_int64(row, 3)
        guard frameID > 0, revision >= 0, sequence >= 0, sequence <= state.feed.latestSequence else {
            throw SemanticRecallError.integrityFailure
        }
        return Source(reference: .init(storeID: state.feed.storeID, source: .native, observationID: try uuid(row, 0),
                                       frameID: .init(value: frameID), extractionRevision: revision),
                      sequence: sequence, unavailable: sqlite3_column_int(row, 4) != 0)
    }

    private struct Document {
        let reference: ScreenEvidenceRef
        let sourceSequence: Int64
        let lane: SemanticRecallLane
        let status: String
        let pageCount: Int
        let nextCursor: ScreenEvidenceExpansionCursor?
    }
    private static let documentColumns = "referencePayload,sourceSequence,lane,status,pageCount,nextCursor"
    private static func decodeDocument(_ row: OpaquePointer) throws -> Document {
        let reference = try decode(ScreenEvidenceRef.self, row, 0)
        let sequence = sqlite3_column_int64(row, 1), page = sqlite3_column_int64(row, 4)
        let status = RecallSQL.string(row, 3)
        guard reference.source == .native, reference.frameID.value > 0, reference.extractionRevision >= 0,
              reference.blockIDs.isEmpty, sequence >= 0, (0...4096).contains(page),
              ["pending", "complete", "empty", "skipped"].contains(status),
              let lane = SemanticRecallLane(rawValue: RecallSQL.string(row, 2)) else { throw SemanticRecallError.integrityFailure }
        let next = sqlite3_column_type(row, 5) == SQLITE_NULL ? nil : try decode(ScreenEvidenceExpansionCursor.self, row, 5)
        return Document(reference: reference, sourceSequence: sequence, lane: lane, status: status,
                        pageCount: Int(page), nextCursor: next)
    }
    private static func document(_ db: OpaquePointer, indexID: UUID, observationID: UUID) throws -> Document? {
        try PipelineSQL.query(db, "SELECT \(documentColumns) FROM semantic_recall_document WHERE indexID=? AND observationID=?",
                              [.text(indexID.uuidString), .text(observationID.uuidString)], map: decodeDocument).first
    }
    private static func requireDocument(_ db: OpaquePointer, claim: SemanticRecallClaim) throws -> Document {
        guard let result = try document(db, indexID: claim.cursor.indexID, observationID: claim.reference.observationID),
              result.reference == claim.reference, result.sourceSequence == claim.sourceSequence else {
            throw SemanticRecallError.sourceChanged
        }
        return result
    }
    private static func nextPending(_ db: OpaquePointer, indexID: UUID, lane: SemanticRecallLane) throws -> Document? {
        try PipelineSQL.query(db, """
            SELECT \(documentColumns) FROM semantic_recall_document WHERE indexID=? AND status='pending' AND lane=?
            ORDER BY sourceSequence DESC,frameID LIMIT 1
            """, [.text(indexID.uuidString), .text(lane.rawValue)], map: decodeDocument).first
    }
    private static func queue(_ db: OpaquePointer, owner: Index, source: Source, lane: SemanticRecallLane) throws -> Document {
        let keys: [PipelineSQL.Value] = [.text(owner.cursor.indexID.uuidString), .text(source.reference.observationID.uuidString)]
        if let previous = try document(db, indexID: owner.cursor.indexID, observationID: source.reference.observationID) {
            if previous.reference == source.reference, previous.sourceSequence == source.sequence { return previous }
            try PipelineSQL.execute(db, "DELETE FROM semantic_recall_document WHERE indexID=? AND observationID=?", keys)
        }
        let status = source.unavailable ? "skipped" : "pending"
        try PipelineSQL.execute(db, """
            INSERT INTO semantic_recall_document(indexID,observationID,storeID,frameID,extractionRevision,sourceSequence,
              referencePayload,policySHA256,lane,status) VALUES(?,?,?,?,?,?,?,?,?,?)
            """, keys + [.text(source.reference.storeID.uuidString), .integer(source.reference.frameID.value),
                .integer(source.reference.extractionRevision), .integer(source.sequence), .text(try json(source.reference)),
                .text(owner.policyHash), .text(lane.rawValue), .text(status)])
        return Document(reference: source.reference, sourceSequence: source.sequence, lane: lane,
                        status: status, pageCount: 0, nextCursor: nil)
    }
    private static func skip(_ db: OpaquePointer, owner: Index, document: Document) throws {
        let keys: [PipelineSQL.Value] = [.text(owner.cursor.indexID.uuidString), .text(document.reference.observationID.uuidString)]
        try PipelineSQL.execute(db, "DELETE FROM semantic_recall_page WHERE indexID=? AND observationID=?", keys)
        try PipelineSQL.execute(db, "DELETE FROM semantic_recall_attempt WHERE indexID=? AND observationID=?", keys)
        try PipelineSQL.execute(db, "UPDATE semantic_recall_document SET status='skipped',pageCount=0,nextCursor=NULL WHERE indexID=? AND observationID=?", keys)
    }

    private static func makeClaim(_ db: OpaquePointer, owner: Index, state: ScreenEvidenceAdmissionSQL.State,
                                  document: Document, started: ScreenEvidenceAdmissionClock.Instant,
                                  executionDuration: TimeInterval, clock: ScreenEvidenceAdmissionClock?) throws -> SemanticRecallInput? {
        guard document.pageCount < 4096 else { throw SemanticRecallError.capacityExceeded }
        let expansion = ScreenEvidenceExpansionRequest(reference: document.reference, blockLimit: pageFragments,
                                                         maximumUTF8Bytes: pageBytes, cursor: document.nextCursor)
        let projection: ScreenEvidenceAdmissionSQL.Input
        do {
            projection = try ScreenEvidenceAdmissionSQL.projectInput(db, expansion: expansion, state: state,
                                                                     retainedSourceSequence: document.sourceSequence)
        } catch let error as ScreenEvidenceAdmissionError {
            switch error {
            case .notPermitted, .sourceChanged, .invalidReference, .integrityFailure:
                // A bad or excluded observation does not claim coverage and does
                // not prevent unrelated fresh material from progressing.
                try skip(db, owner: owner, document: document)
                return nil
            default: throw error
            }
        }
        guard projection.hasExtractionText else {
            try skip(db, owner: owner, document: document)
            return nil
        }
        let deadline = min(started.date.addingTimeInterval(executionDuration), owner.expiresAt)
        let claim = SemanticRecallClaim(attemptID: UUID(), cursor: owner.cursor, transformation: owner.transformation,
            policy: try transition(state), reference: document.reference, lane: document.lane,
            sourceSequence: document.sourceSequence, metadataEpoch: state.metadataEpoch, inputSHA256: projection.hash,
            expansion: expansion, nextExpansion: projection.nextCursor, pageOrdinal: document.pageCount,
            issuedAt: started.date, deadline: deadline)
        let uptimeDeadline = started.uptime + deadline.timeIntervalSince(started.date)
        try validateExecution(claim, uptimeDeadline: uptimeDeadline, owner: owner, clock: clock)
        try PipelineSQL.execute(db, """
            INSERT INTO semantic_recall_attempt(attemptID,indexID,observationID,claimPayload,status,deadline,deadlineUptime)
            VALUES(?,?,?,?,'claimed',?,?)
            """, [.text(claim.attemptID.uuidString), .text(owner.cursor.indexID.uuidString),
                .text(document.reference.observationID.uuidString), .text(try json(claim)),
                .real(deadline.timeIntervalSince1970), .real(uptimeDeadline)])
        try validateExecution(claim, uptimeDeadline: uptimeDeadline, owner: owner, clock: clock)
        return compose(claim: claim, page: projection.page)
    }
    private static func compose(claim: SemanticRecallClaim, page: ScreenEvidenceExpansionPage) -> SemanticRecallInput {
        let content = composeContent(page: page)
        return .init(claim: claim, text: content.text, fragments: content.spans)
    }
    private static func composeContent(page: ScreenEvidenceExpansionPage) -> (text: String, spans: [SemanticRecallSpan]) {
        var text = "", spans: [SemanticRecallSpan] = []
        for (index, fragment) in page.fragments.enumerated() {
            if index > 0 { text.append("\n") }
            let offset = text.utf16.count
            text.append(fragment.text)
            spans.append(.init(fragmentID: fragment.id, sourceUTF16Range: fragment.utf16Range,
                               inputUTF16Range: .init(location: offset, length: fragment.text.utf16.count)))
        }
        return (text, spans)
    }

    private struct Attempt {
        let claim: SemanticRecallClaim
        let status: String
        let uptimeDeadline: TimeInterval
        let resultHash: String?
        let result: SemanticRecallPublication?
    }
    private static let attemptColumns = "attemptID,indexID,observationID,claimPayload,status,deadline,deadlineUptime,resultSHA256,resultPayload"
    private static func decodeAttempt(_ row: OpaquePointer) throws -> Attempt {
        let claim = try decode(SemanticRecallClaim.self, row, 3)
        let status = RecallSQL.string(row, 4), uptimeDeadline = sqlite3_column_double(row, 6)
        guard try uuid(row, 0) == claim.attemptID, try uuid(row, 1) == claim.cursor.indexID,
              try uuid(row, 2) == claim.reference.observationID, claim.reference == claim.expansion.reference,
              claim.reference.source == .native, claim.reference.blockIDs.isEmpty,
              claim.transformation == .miniLMNativeV1, (0..<4096).contains(claim.pageOrdinal),
              claim.sourceSequence >= 0, claim.metadataEpoch >= 0, validSHA(claim.inputSHA256),
              claim.expansion.blockLimit == pageFragments, claim.expansion.maximumUTF8Bytes == pageBytes,
              claim.issuedAt.timeIntervalSince1970.isFinite, claim.deadline > claim.issuedAt,
              claim.deadline.timeIntervalSince(claim.issuedAt) <= 30,
              sqlite3_column_double(row, 5) == claim.deadline.timeIntervalSince1970,
              uptimeDeadline.isFinite, uptimeDeadline >= 0, ["claimed", "published", "cancelled"].contains(status) else {
            throw SemanticRecallError.integrityFailure
        }
        let hash = sqlite3_column_type(row, 7) == SQLITE_NULL ? nil : RecallSQL.string(row, 7)
        let result = sqlite3_column_type(row, 8) == SQLITE_NULL ? nil : try decode(SemanticRecallPublication.self, row, 8)
        guard status == "published" ? (hash.map(validSHA) == true && result != nil) : (hash == nil && result == nil) else {
            throw SemanticRecallError.integrityFailure
        }
        return Attempt(claim: claim, status: status, uptimeDeadline: uptimeDeadline, resultHash: hash, result: result)
    }
    private static func requireAttempt(_ db: OpaquePointer, claim: SemanticRecallClaim) throws -> Attempt {
        let rows = try PipelineSQL.query(db, "SELECT \(attemptColumns) FROM semantic_recall_attempt WHERE attemptID=?",
                                        [.text(claim.attemptID.uuidString)], map: decodeAttempt)
        guard rows.count == 1, let result = rows.first, result.claim == claim else { throw SemanticRecallError.invalidClaim }
        return result
    }
    private static func pruneAttempts(_ db: OpaquePointer, owner: Index, state: ScreenEvidenceAdmissionSQL.State,
                                      now: ScreenEvidenceAdmissionClock.Instant) throws {
        let rows = try PipelineSQL.query(db, "SELECT \(attemptColumns) FROM semantic_recall_attempt ORDER BY deadline,attemptID LIMIT 65", map: decodeAttempt)
        guard rows.count <= 64 else { throw SemanticRecallError.integrityFailure }
        for row in rows where row.status == "claimed" && (row.claim.deadline <= now.date || row.uptimeDeadline <= now.uptime ||
            row.claim.policy != state.transition || row.claim.metadataEpoch != state.metadataEpoch) {
            try PipelineSQL.execute(db, "DELETE FROM semantic_recall_attempt WHERE attemptID=?", [.text(row.claim.attemptID.uuidString)])
        }
        // Preserve bounded completed receipts for idempotent retries. Reclaim
        // only the oldest terminal receipts when capacity requires it.
        if rows.count >= 64 {
            try PipelineSQL.execute(db, """
                DELETE FROM semantic_recall_attempt WHERE attemptID IN (
                  SELECT attemptID FROM semantic_recall_attempt WHERE status<>'claimed' ORDER BY deadline,attemptID LIMIT 16)
                """)
        }
        let count = try PipelineSQL.integers(db, "SELECT COUNT(*) FROM semantic_recall_attempt").first ?? 64
        guard count < 64 else { throw SemanticRecallError.capacityExceeded }
    }

    private static func validateExecution(_ claim: SemanticRecallClaim, uptimeDeadline: TimeInterval,
                                          owner: Index, clock: ScreenEvidenceAdmissionClock?) throws {
        let current = try instant(clock)
        guard current.date >= claim.issuedAt, current.date < claim.deadline, current.date < owner.expiresAt,
              current.uptime < uptimeDeadline,
              current.uptime >= uptimeDeadline - claim.deadline.timeIntervalSince(claim.issuedAt) else {
            throw SemanticRecallError.claimExpired
        }
    }
    private static func instant(_ clock: ScreenEvidenceAdmissionClock?) throws -> ScreenEvidenceAdmissionClock.Instant {
        let value = clock?.sample() ?? .init(date: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        guard value.date.timeIntervalSince1970.isFinite, value.uptime.isFinite, value.uptime >= 0 else {
            throw SemanticRecallError.integrityFailure
        }
        return value
    }
    private static func transition(_ state: ScreenEvidenceAdmissionSQL.State) throws -> ScreenEvidencePolicyTransition {
        guard let result = state.transition else { throw ScreenEvidenceAdmissionError.inactive }
        return result
    }
    private static func readStamp(_ owner: Index, state: ScreenEvidenceAdmissionSQL.State) throws -> SemanticRecallReadStamp {
        .init(indexID: owner.cursor.indexID, policy: try transition(state), generation: owner.generation, metadataEpoch: state.metadataEpoch)
    }

    private static func validate(_ transformation: SemanticRecallTransformation) throws {
        guard transformation == .miniLMNativeV1 else { throw SemanticRecallError.unsupportedTransformation }
    }
    private static func validateFilter(_ filter: SemanticRecallFilter) throws {
        guard filter.appBundleIDs.count <= 64, Set(filter.appBundleIDs).count == filter.appBundleIDs.count,
              filter.appBundleIDs == filter.appBundleIDs.sorted(),
              filter.appBundleIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }),
              filter.excludedAppBundleIDs.count <= 64,
              Set(filter.excludedAppBundleIDs).count == filter.excludedAppBundleIDs.count,
              filter.excludedAppBundleIDs == filter.excludedAppBundleIDs.sorted(),
              filter.excludedAppBundleIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }),
              [filter.from, filter.through].compactMap({ $0 }).allSatisfy({
                  let milliseconds = $0.timeIntervalSince1970 * 1000
                  return milliseconds.isFinite && milliseconds > Double(Int64.min) && milliseconds < Double(Int64.max)
              }), filter.from == nil || filter.through == nil || filter.from! <= filter.through! else {
            throw SemanticRecallError.invalidLimits
        }
    }
    private static func validate(windows: [SemanticRecallVectorWindow], input: SemanticRecallInput) throws -> [Data] {
        if windows.isEmpty {
            guard inert(input.text) else { throw SemanticRecallError.incompleteWindows }
            return []
        }
        guard windows.count <= 32, windows.first?.tokenStart == 0 else { throw SemanticRecallError.incompleteWindows }
        var previous: SemanticRecallVectorWindow?
        var bytes: [Data] = []
        for (index, window) in windows.enumerated() {
            guard window.tokenStart >= 0, window.tokenEnd > window.tokenStart,
                  window.tokenEnd - window.tokenStart <= 224,
                  index == windows.count - 1 || window.tokenEnd - window.tokenStart >= 176 else {
                throw SemanticRecallError.incompleteWindows
            }
            guard try input.spans(for: window.inputUTF16Range) == window.spans else { throw SemanticRecallError.invalidSpan }
            if let previous {
                let previousEnd = previous.inputUTF16Range.location + previous.inputUTF16Range.length
                guard window.tokenStart == previous.tokenEnd - 32, window.tokenEnd > previous.tokenEnd,
                      window.inputUTF16Range.location >= previous.inputUTF16Range.location,
                      window.inputUTF16Range.location <= previousEnd,
                      window.inputUTF16Range.location + window.inputUTF16Range.length > previousEnd else {
                    throw SemanticRecallError.incompleteWindows
                }
            }
            bytes.append(try vectorData(window.vector))
            previous = window
        }
        guard let first = windows.first, let last = windows.last else { throw SemanticRecallError.incompleteWindows }
        let end = last.inputUTF16Range.location + last.inputUTF16Range.length
        // The pinned producer includes all original outer padding in its first
        // and last window. DB validates declared coverage; tokenizer/inference
        // correspondence is established by the separately pinned native runtime.
        guard first.inputUTF16Range.location == 0, end == input.text.utf16.count else {
            throw SemanticRecallError.incompleteWindows
        }
        return bytes
    }

    /// The pinned Bert normalizer discards these scalars. This permits an empty
    /// extraction or harmless outer padding, never omitted substantive text.
    private static func inert(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy {
            $0.value == 0 || $0.value == 0xFFFD || $0.properties.isWhitespace ||
            $0.properties.generalCategory == .control || $0.properties.generalCategory == .format ||
            $0.properties.generalCategory == .nonspacingMark
        }
    }
    private static func vectorData(_ vector: [Float]) throws -> Data {
        guard vector.count == 384, vector.allSatisfy(\.isFinite) else { throw SemanticRecallError.invalidVector }
        let norm = vector.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard norm.isFinite, abs(norm - 1) <= 0.0002 else { throw SemanticRecallError.invalidVector }
        var data = Data(capacity: 1536)
        for value in vector {
            var word = value.bitPattern.littleEndian
            withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
        }
        return data
    }
    private static func decodeVector(_ row: OpaquePointer, column: Int32, hashColumn: Int32) throws -> [Float] {
        guard sqlite3_column_type(row, column) == SQLITE_BLOB, sqlite3_column_bytes(row, column) == 1536,
              let pointer = sqlite3_column_blob(row, column) else { throw SemanticRecallError.integrityFailure }
        let data = Data(bytes: pointer, count: 1536)
        guard sha256(data) == RecallSQL.string(row, hashColumn) else { throw SemanticRecallError.integrityFailure }
        let vector = data.withUnsafeBytes { raw -> [Float] in
            (0..<384).map { Float(bitPattern: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian) }
        }
        do { _ = try vectorData(vector) } catch { throw SemanticRecallError.integrityFailure }
        return vector
    }

    private struct Candidate {
        let rowID: Int64
        let reference: ScreenEvidenceRef
        let sourceSequence: Int64
        let pageOrdinal: Int
        let windowOrdinal: Int
        let window: SemanticRecallVectorWindow
        let expansion: ScreenEvidenceExpansionRequest
        let inputHash: String
    }
    private static func decodeCandidate(_ row: OpaquePointer) throws -> Candidate {
        let id = sqlite3_column_int64(row, 0), sequence = sqlite3_column_int64(row, 2)
        let reference = try decode(ScreenEvidenceRef.self, row, 1)
        let page = sqlite3_column_int64(row, 3), ordinal = sqlite3_column_int64(row, 4)
        let tokenStart = sqlite3_column_int64(row, 5), tokenEnd = sqlite3_column_int64(row, 6)
        let location = sqlite3_column_int64(row, 7), length = sqlite3_column_int64(row, 8)
        let spans = try decode([SemanticRecallSpan].self, row, 9)
        let expansion = try decode(ScreenEvidenceExpansionRequest.self, row, 12)
        let hash = RecallSQL.string(row, 13)
        guard id > 0, sequence >= 0, reference.source == .native, reference.blockIDs.isEmpty,
              page >= 0, page <= Int64(Int.max), (0...31).contains(ordinal), tokenStart >= 0,
              tokenEnd > tokenStart, tokenEnd - tokenStart <= 224, tokenEnd <= Int64(Int.max),
              location >= 0, length > 0, location <= 4159, length <= 4159 - location,
              expansion.reference == reference, expansion.blockLimit == pageFragments,
              expansion.maximumUTF8Bytes == pageBytes, validSHA(hash) else { throw SemanticRecallError.integrityFailure }
        let window = SemanticRecallVectorWindow(tokenStart: Int(tokenStart), tokenEnd: Int(tokenEnd),
            inputUTF16Range: .init(location: Int(location), length: Int(length)), spans: spans,
            vector: try decodeVector(row, column: 10, hashColumn: 11))
        return Candidate(rowID: id, reference: reference, sourceSequence: sequence,
            pageOrdinal: Int(page), windowOrdinal: Int(ordinal), window: window, expansion: expansion, inputHash: hash)
    }
    private static func uuid(_ row: OpaquePointer, _ column: Int32) throws -> UUID {
        guard let value = UUID(uuidString: RecallSQL.string(row, column)) else { throw SemanticRecallError.integrityFailure }
        return value
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ row: OpaquePointer, _ column: Int32,
                                            limit: Int = 65_536) throws -> T {
        guard sqlite3_column_type(row, column) == SQLITE_TEXT,
              sqlite3_column_bytes(row, column) <= limit else { throw SemanticRecallError.integrityFailure }
        do { return try RecallSQL.decode(type, RecallSQL.string(row, column)) }
        catch { throw SemanticRecallError.integrityFailure }
    }
    private static func json<T: Encodable>(_ value: T, limit: Int = 65_536) throws -> String {
        let text = try RecallSQL.encode(value)
        guard text.utf8.count <= limit else { throw SemanticRecallError.invalidLimits }
        return text
    }
    private static func validSHA(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
