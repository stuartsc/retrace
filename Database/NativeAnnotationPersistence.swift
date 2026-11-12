import CryptoKit
import Foundation
import SQLCipher
import Shared

extension DatabaseManager {
    /// Connection-local revision hooks do not change the installed V23 schema.
    public func nativeAnnotations(references: [ScreenEvidenceRef], policy: ScreenEvidenceAccessPolicy) throws -> NativeAnnotationSnapshot {
        let db = try requireRecallConnection()
        try AnnotationSQL.install(db)
        return try AnnotationSQL.readTransaction(db) { try AnnotationSQL.snapshot(db, references, policy) }
    }

    public func nativeAnnotationImpact(expected: NativeAnnotationSnapshot, mutation: NativeAnnotationMutation,
                                       policy: ScreenEvidenceAccessPolicy) throws -> Int {
        let db = try requireRecallConnection()
        try AnnotationSQL.install(db)
        return try AnnotationSQL.readTransaction(db) {
            guard try AnnotationSQL.snapshot(db, expected.segments.map(\.reference), policy) == expected else { throw NativeAnnotationError.staleSelection }
            switch mutation {
            case .removeTag(let id), .deleteTag(let id):
                let selected = expected.segments.filter { $0.tags.contains(where: { $0.id == id && !$0.isHidden }) }
                guard !selected.isEmpty else { throw NativeAnnotationError.staleSelection }
                if case .deleteTag = mutation {
                    let links = try PipelineSQL.integers(db, "SELECT segmentId FROM segment_tag WHERE tagId=? ORDER BY segmentId LIMIT 17", [.integer(id.value)])
                    guard Set(links).isSubset(of: Set(expected.segments.map { $0.id.value })) else { throw NativeAnnotationError.notPermitted }
                }
                return selected.count
            case .unlinkComment(let id), .deleteComment(let id):
                let all: Bool
                if case .deleteComment = mutation { all = true } else { all = false }
                _ = try AnnotationSQL.selectedComment(db, id, expected, requireAllLinks: all)
                return expected.segments.filter { $0.comments.contains(where: { $0.id == id }) }.count
            default: throw NativeAnnotationError.invalidArguments
            }
        }
    }

    /// Native UI adapter only. Commands never supply bare segment/frame IDs.
    public func nativeAnnotationReferences(segmentIDs: [SegmentID], anchor: FrameID?, policy: ScreenEvidenceAccessPolicy) throws -> [ScreenEvidenceRef] {
        let db = try requireRecallConnection()
        guard (1...16).contains(segmentIDs.count), Set(segmentIDs).count == segmentIDs.count else { throw NativeAnnotationError.invalidArguments }
        return try AnnotationSQL.readTransaction(db) {
            let store = try AnnotationSQL.nativeStore(db)
            return try segmentIDs.sorted(by: { $0.value < $1.value }).map { segment in
                let frame: Int64?
                if let anchor, try PipelineSQL.integers(db, "SELECT segmentId FROM frame WHERE id=?", [.integer(anchor.value)]).first == segment.value {
                    frame = anchor.value
                } else {
                    frame = try PipelineSQL.integers(db, "SELECT id FROM frame WHERE segmentId=? ORDER BY createdAt,id LIMIT 1", [.integer(segment.value)]).first
                }
                guard let frame, let current = try ScreenEvidenceSQL.current(db, frameID: .init(value: frame), storeID: store) else { throw NativeAnnotationError.unavailable }
                _ = try AnnotationSQL.target(db, current.ref, policy)
                return current.ref
            }
        }
    }

    /// Compare the complete bounded selection and revision in the native mutation
    /// transaction, while the App policy and command grants remain admitted.
    public func mutateNativeAnnotations(expected: NativeAnnotationSnapshot, mutation: NativeAnnotationMutation,
                                        policy: ScreenEvidenceAccessPolicy, fences: [NativeMutationFence]) throws -> NativeAnnotationReceipt {
        guard (1...3).contains(fences.count), Set(fences.map(ObjectIdentifier.init)).count == fences.count else { throw NativeAnnotationError.invalidArguments }
        let db = try requireRecallConnection()
        try AnnotationSQL.install(db)
        try PipelineSQL.execute(db, "BEGIN IMMEDIATE")
        do {
            func admitted<T>(_ index: Int, _ operation: () throws -> T) throws -> T {
                if index == fences.count { return try operation() }
                return try fences[index].withAdmission { try admitted(index + 1, operation) }
            }
            return try admitted(0) {
                let current = try AnnotationSQL.snapshot(db, expected.segments.map(\.reference), policy)
                guard current == expected else { throw NativeAnnotationError.staleSelection }
                let result = try AnnotationSQL.mutate(db, current, mutation, policy)
                // A valid input must not commit an unreadable result. This repeats
                // the same bounded reader over every selected segment, including
                // each comment's complete global link set and aggregate payload.
                _ = try AnnotationSQL.snapshot(db, expected.segments.map(\.reference), policy)
                try Task.checkCancellation()
                for fence in fences { try fence.checkDeadline() }
                try PipelineSQL.execute(db, "COMMIT")
                return result
            }
        } catch { try? PipelineSQL.execute(db, "ROLLBACK"); throw error }
    }
}

private enum AnnotationSQL {
    struct Target: Encodable {
        let reference: ScreenEvidenceRef
        let segmentID: Int64
        let start: Int64
        let type: Int64
        let bundle: String
        let window: String?
        let url: String?
        let sourceSequence: Int64
        let metadataEpoch: Int64
    }
    struct RetainedComment: Encodable {
        let comment: NativeAnnotationComment
        let attachmentsJSON: String
        let frameID: Int64?
        let links: [Int64]
    }
    struct Fingerprint: Encodable {
        let targets: [Target]
        let segments: [NativeAnnotationSegment]
        let comments: [RetainedComment]
    }

    static func install(_ db: OpaquePointer) throws {
        try PipelineSQL.execute(db, "CREATE TEMP TABLE IF NOT EXISTS native_annotation_epoch(id INTEGER PRIMARY KEY CHECK(id=1),connectionID TEXT NOT NULL,sequence INTEGER NOT NULL)")
        try PipelineSQL.execute(db, "INSERT OR IGNORE INTO temp.native_annotation_epoch VALUES(1,?,0)", [.text(UUID().uuidString)])
        for table in ["tag", "segment_tag", "segment_comment", "segment_comment_link"] {
            for action in ["INSERT", "UPDATE", "DELETE"] {
                try PipelineSQL.execute(db, """
                    CREATE TEMP TRIGGER IF NOT EXISTS native_annotation_\(table)_\(action)
                    AFTER \(action) ON main.\(table) BEGIN
                      UPDATE native_annotation_epoch SET sequence=sequence+1 WHERE id=1;
                    END
                    """)
            }
        }
    }

    static func revision(_ db: OpaquePointer) throws -> NativeAnnotationRevision {
        guard let pair = try PipelineSQL.query(db, "SELECT connectionID,sequence FROM temp.native_annotation_epoch WHERE id=1", map: { row -> (UUID, Int64) in
            guard let id = UUID(uuidString: RecallSQL.string(row, 0)) else { throw NativeAnnotationError.unavailable }
            return (id, sqlite3_column_int64(row, 1))
        }).first, let external = try PipelineSQL.integers(db, "PRAGMA main.data_version").first else { throw NativeAnnotationError.unavailable }
        return .init(connectionID: pair.0, sequence: pair.1, externalVersion: external)
    }

    static func nativeStore(_ db: OpaquePointer) throws -> UUID {
        guard let id = try PipelineSQL.query(db, "SELECT storeID FROM evidence_store WHERE source='native' AND identity='native' LIMIT 1", map: { UUID(uuidString: RecallSQL.string($0, 0)) }).first ?? nil else { throw NativeAnnotationError.unavailable }
        return id
    }

    static func target(_ db: OpaquePointer, _ ref: ScreenEvidenceRef, _ policy: ScreenEvidenceAccessPolicy) throws -> Target {
        guard ref.source == .native, ref.frameID.value > 0, ref.blockIDs.isEmpty, ref.extractionRevision >= 0,
              ref.storeID == (try nativeStore(db)) else { throw NativeAnnotationError.notPermitted }
        let targets = try PipelineSQL.query(db, """
            SELECT CASE WHEN length(CAST(e.payload AS BLOB))<=8388608 THEN e.payload END,
                   s.id,s.startDate,s.type,s.bundleID,s.windowName,s.browserUrl,f.createdAt,COALESCE(ss.latestSequence,0),a.metadataEpoch
            FROM screen_observation o JOIN screen_extraction e ON e.observationID=o.observationID AND e.revision=o.preferredRevision
            JOIN frame f ON f.id=o.nativeFrameID AND f.id=o.frameID JOIN segment s ON s.id=f.segmentId
            LEFT JOIN screen_evidence_source_state ss ON ss.storeID=o.storeID AND ss.observationID=o.observationID
            JOIN screen_evidence_admission_state a ON a.id=1 AND a.storeID=o.storeID
            WHERE o.storeID=? AND o.source='native' AND o.observationID=? AND o.frameID=? AND o.preferredRevision=?
              AND f.redactionReason IS NULL
              AND NOT EXISTS(SELECT 1 FROM segment_tag st JOIN tag t ON t.id=st.tagId WHERE st.segmentId=s.id AND t.name='hidden')
            LIMIT 1
            """, [.text(ref.storeID.uuidString), .text(ref.observationID.uuidString), .integer(ref.frameID.value), .integer(ref.extractionRevision)]) { row -> Target in
            guard sqlite3_column_type(row, 0) != SQLITE_NULL else { throw NativeAnnotationError.tooLarge }
            let retained = try ScreenEvidenceSQL.decodeSnapshot(RecallSQL.string(row, 0))
            let bundle = RecallSQL.string(row, 4), window = optional(row, 5), url = optional(row, 6)
            guard retained.ref == ref, retained.frame.source == .native,
                  Schema.dateToTimestamp(retained.frame.timestamp) == sqlite3_column_int64(row, 7),
                  policy.permitsLocalPresentation(retained.frame.metadata),
                  policy.permitsLocalPresentation(.init(appBundleID: bundle, windowName: window, browserURL: url)) else { throw NativeAnnotationError.notPermitted }
            return Target(reference: ref, segmentID: sqlite3_column_int64(row, 1), start: sqlite3_column_int64(row, 2),
                          type: sqlite3_column_int64(row, 3), bundle: bundle, window: window, url: url,
                          sourceSequence: sqlite3_column_int64(row, 8), metadataEpoch: sqlite3_column_int64(row, 9))
        }
        guard let target = targets.first else { throw NativeAnnotationError.staleSelection }
        return target
    }

    static func snapshot(_ db: OpaquePointer, _ references: [ScreenEvidenceRef], _ policy: ScreenEvidenceAccessPolicy) throws -> NativeAnnotationSnapshot {
        try Task.checkCancellation()
        guard (1...16).contains(references.count) else { throw NativeAnnotationError.invalidArguments }
        let stamp = try revision(db), storeID = try nativeStore(db)
        let targets = try references.map { try target(db, $0, policy) }.sorted { $0.segmentID < $1.segmentID }
        guard Set(targets.map(\.segmentID)).count == targets.count else { throw NativeAnnotationError.invalidArguments }
        var segments: [NativeAnnotationSegment] = [], retained: [Int64: RetainedComment] = [:]
        for item in targets {
            let tags = try PipelineSQL.query(db, """
                SELECT t.id,CASE WHEN length(CAST(t.name AS BLOB))<=256 THEN t.name END
                FROM segment_tag st JOIN tag t ON t.id=st.tagId WHERE st.segmentId=? ORDER BY t.id LIMIT 129
                """, [.integer(item.segmentID)]) { row -> Tag in
                    guard sqlite3_column_type(row, 1) != SQLITE_NULL else { throw NativeAnnotationError.tooLarge }
                    return Tag(id: .init(value: sqlite3_column_int64(row, 0)), name: RecallSQL.string(row, 1))
                }
            guard tags.count <= 128, tags.allSatisfy({ $0.name.utf8.count <= 256 && !$0.isHidden }) else { throw NativeAnnotationError.tooLarge }
            let commentIDs = try PipelineSQL.integers(db, "SELECT commentId FROM segment_comment_link WHERE segmentId=? ORDER BY commentId LIMIT 65", [.integer(item.segmentID)])
            guard commentIDs.count <= 64 else { throw NativeAnnotationError.tooLarge }
            var comments: [NativeAnnotationComment] = []
            for id in commentIDs {
                let saved: RetainedComment
                if let existing = retained[id] { saved = existing }
                else { saved = try comment(db, id); retained[id] = saved }
                comments.append(saved.comment)
            }
            segments.append(.init(id: .init(value: item.segmentID), reference: item.reference, tags: tags, comments: comments))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(Fingerprint(targets: targets, segments: segments, comments: retained.keys.sorted().compactMap { retained[$0] }))
        guard bytes.count <= 262_144 else { throw NativeAnnotationError.tooLarge }
        try Task.checkCancellation()
        return .init(nativeStoreID: storeID, revision: stamp,
                     fingerprint: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), segments: segments)
    }

    static func comment(_ db: OpaquePointer, _ id: Int64) throws -> RetainedComment {
        let rows = try PipelineSQL.query(db, """
            SELECT CASE WHEN length(CAST(body AS BLOB))<=16384 THEN body END,
                   CASE WHEN length(CAST(author AS BLOB))<=256 THEN author END,
                   CASE WHEN length(CAST(attachmentsJson AS BLOB))<=65536 THEN attachmentsJson END,
                   frameId,createdAt,updatedAt FROM segment_comment WHERE id=?
            """, [.integer(id)]) { row -> RetainedComment in
            guard (0...2).allSatisfy({ sqlite3_column_type(row, Int32($0)) != SQLITE_NULL }) else { throw NativeAnnotationError.tooLarge }
            let raw = RecallSQL.string(row, 2)
            let attachments = try JSONDecoder().decode([SegmentCommentAttachment].self, from: Data(raw.utf8))
            guard attachments.count <= 32 else { throw NativeAnnotationError.tooLarge }
            let links = try PipelineSQL.integers(db, "SELECT segmentId FROM segment_comment_link WHERE commentId=? ORDER BY segmentId LIMIT 65", [.integer(id)])
            guard links.count <= 64 else { throw NativeAnnotationError.tooLarge }
            let value = NativeAnnotationComment(id: .init(value: id), body: RecallSQL.string(row, 0), author: RecallSQL.string(row, 1),
                attachmentCount: attachments.count, createdAt: Schema.timestampToDate(sqlite3_column_int64(row, 4)),
                updatedAt: Schema.timestampToDate(sqlite3_column_int64(row, 5)))
            return .init(comment: value, attachmentsJSON: raw, frameID: sqlite3_column_type(row, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(row, 3), links: links)
        }
        guard let value = rows.first else { throw NativeAnnotationError.staleSelection }
        return value
    }

    static func mutate(_ db: OpaquePointer, _ expected: NativeAnnotationSnapshot, _ mutation: NativeAnnotationMutation,
                       _ policy: ScreenEvidenceAccessPolicy) throws -> NativeAnnotationReceipt {
        let segments = expected.segments.map { $0.id.value }
        switch mutation {
        case .addTag(let input):
            let name = try text(input, maximum: 256)
            guard name.lowercased() != Tag.hiddenTagName else { throw NativeAnnotationError.notPermitted }
            try PipelineSQL.execute(db, "INSERT OR IGNORE INTO tag(name) VALUES(?)", [.text(name)])
            guard let id = try PipelineSQL.integers(db, "SELECT id FROM tag WHERE name=?", [.text(name)]).first else { throw NativeAnnotationError.unavailable }
            for segment in segments { try PipelineSQL.execute(db, "INSERT OR IGNORE INTO segment_tag(segmentId,tagId) VALUES(?,?)", [.integer(segment), .integer(id)]) }
            return .init(nativeStoreID: expected.nativeStoreID, affectedSegments: segments.count, tagID: .init(value: id))
        case .removeTag(let id):
            guard expected.segments.contains(where: { $0.tags.contains(where: { $0.id == id && !$0.isHidden }) }) else { throw NativeAnnotationError.staleSelection }
            for segment in segments { try PipelineSQL.execute(db, "DELETE FROM segment_tag WHERE segmentId=? AND tagId=?", [.integer(segment), .integer(id.value)]) }
            let count = expected.segments.filter { $0.tags.contains(where: { $0.id == id }) }.count
            return .init(nativeStoreID: expected.nativeStoreID, affectedSegments: count, tagID: id)
        case .deleteTag(let id):
            guard expected.segments.contains(where: { $0.tags.contains(where: { $0.id == id && !$0.isHidden }) }) else { throw NativeAnnotationError.staleSelection }
            let links = try PipelineSQL.integers(db, "SELECT segmentId FROM segment_tag WHERE tagId=? ORDER BY segmentId LIMIT 17", [.integer(id.value)])
            guard Set(links).isSubset(of: Set(segments)) else { throw NativeAnnotationError.notPermitted }
            try PipelineSQL.execute(db, "DELETE FROM segment_tag WHERE tagId=?", [.integer(id.value)])
            try PipelineSQL.execute(db, "DELETE FROM tag WHERE id=? AND name<>'hidden'", [.integer(id.value)])
            return .init(nativeStoreID: expected.nativeStoreID, affectedSegments: links.count, tagID: id)
        case .createComment(let input, let inputAuthor, let attachments, let anchor):
            let body = try text(input, maximum: 16_384), author = try text(inputAuthor, maximum: 256)
            guard attachments.count <= 32, anchor == nil || expected.segments.contains(where: { $0.reference.frameID == anchor }) else { throw NativeAnnotationError.invalidArguments }
            let data = try JSONEncoder().encode(attachments)
            guard data.count <= 65_536, let raw = String(data: data, encoding: .utf8) else { throw NativeAnnotationError.tooLarge }
            let now = Schema.currentTimestamp()
            var values: [PipelineSQL.Value] = [.text(body), .text(author), .text(raw)]
            if let anchor { values.append(.integer(anchor.value)) }
            values.append(contentsOf: [.integer(now), .integer(now)])
            try PipelineSQL.execute(db, "INSERT INTO segment_comment(body,author,attachmentsJson,frameId,createdAt,updatedAt) VALUES(?,?,?,\(anchor == nil ? "NULL" : "?"),?,?)", values)
            let id = sqlite3_last_insert_rowid(db)
            for segment in segments { try PipelineSQL.execute(db, "INSERT INTO segment_comment_link(commentId,segmentId) VALUES(?,?)", [.integer(id), .integer(segment)]) }
            return .init(nativeStoreID: expected.nativeStoreID, affectedSegments: segments.count, commentID: .init(value: id))
        case .updateComment(let id, let input):
            let retained = try selectedComment(db, id, expected, requireAllLinks: true)
            try PipelineSQL.execute(db, "UPDATE segment_comment SET body=?,updatedAt=? WHERE id=?", [.text(try text(input, maximum: 16_384)), .integer(Schema.currentTimestamp()), .integer(id.value)])
            return .init(nativeStoreID: expected.nativeStoreID, affectedSegments: retained.links.count, commentID: id)
        case .linkComment(let id):
            // Adding a link changes the retained fingerprint at every existing
            // linked segment. Keep all of those sources in the bounded selection
            // so the post-mutation reader can prove no affected view overflows.
            _ = try selectedComment(db, id, expected, requireAllLinks: true)
            for segment in segments { try PipelineSQL.execute(db, "INSERT OR IGNORE INTO segment_comment_link(commentId,segmentId) VALUES(?,?)", [.integer(id.value), .integer(segment)]) }
            return .init(nativeStoreID: expected.nativeStoreID, affectedSegments: segments.count, commentID: id)
        case .unlinkComment(let id):
            _ = try selectedComment(db, id, expected, requireAllLinks: false)
            for segment in segments { try PipelineSQL.execute(db, "DELETE FROM segment_comment_link WHERE segmentId=? AND commentId=?", [.integer(segment), .integer(id.value)]) }
            // Files remain retained; this transaction never interprets attachment paths.
            try PipelineSQL.execute(db, "DELETE FROM segment_comment WHERE id=? AND NOT EXISTS(SELECT 1 FROM segment_comment_link WHERE commentId=?)", [.integer(id.value), .integer(id.value)])
            let count = expected.segments.filter { $0.comments.contains(where: { $0.id == id }) }.count
            return .init(nativeStoreID: expected.nativeStoreID, affectedSegments: count, commentID: id)
        case .deleteComment(let id):
            let retained = try selectedComment(db, id, expected, requireAllLinks: true)
            try PipelineSQL.execute(db, "DELETE FROM segment_comment_link WHERE commentId=?", [.integer(id.value)])
            try PipelineSQL.execute(db, "DELETE FROM segment_comment WHERE id=?", [.integer(id.value)])
            return .init(nativeStoreID: expected.nativeStoreID, affectedSegments: retained.links.count, commentID: id)
        }
    }

    static func selectedComment(_ db: OpaquePointer, _ id: SegmentCommentID, _ expected: NativeAnnotationSnapshot, requireAllLinks: Bool) throws -> RetainedComment {
        guard expected.segments.contains(where: { $0.comments.contains(where: { $0.id == id }) }) else { throw NativeAnnotationError.staleSelection }
        let value = try comment(db, id.value)
        if requireAllLinks, !Set(value.links).isSubset(of: Set(expected.segments.map { $0.id.value })) { throw NativeAnnotationError.notPermitted }
        return value
    }
    static func text(_ input: String, maximum: Int) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= maximum, !value.contains("\0") else { throw NativeAnnotationError.invalidArguments }
        return value
    }
    static func optional(_ row: OpaquePointer, _ column: Int32) -> String? { sqlite3_column_type(row, column) == SQLITE_NULL ? nil : RecallSQL.string(row, column) }
    static func readTransaction<T>(_ db: OpaquePointer, _ operation: () throws -> T) throws -> T {
        try Task.checkCancellation()
        try PipelineSQL.execute(db, "BEGIN DEFERRED")
        do { let result = try operation(); try Task.checkCancellation(); try PipelineSQL.execute(db, "COMMIT"); return result }
        catch { try? PipelineSQL.execute(db, "ROLLBACK"); throw error }
    }
}
