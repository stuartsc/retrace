import Foundation
import SQLCipher
import Shared

extension ContextDatabase {
    static let companionCandidateSchema = """
        CREATE TABLE companion_enrollments(id TEXT PRIMARY KEY,active INTEGER NOT NULL,payload BLOB NOT NULL);
        CREATE UNIQUE INDEX companion_active_enrollment ON companion_enrollments(active) WHERE active=1;
        CREATE TABLE companion_batch_candidates(sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            manifest_id TEXT NOT NULL UNIQUE REFERENCES audio_media_manifests(id), enrollment_id TEXT NOT NULL,
            revision TEXT NOT NULL,state TEXT NOT NULL,retry_after REAL NOT NULL DEFAULT 0,group_id TEXT,attempts INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX companion_candidate_due ON companion_batch_candidates(enrollment_id,state,retry_after,sequence DESC);
        """
    public func companionEnrollment() async throws -> CompanionEnrollment? {
        try requireInitialized()
        return try activeCompanionEnrollment()
    }
    private func activeCompanionEnrollment() throws -> CompanionEnrollment? {
        try readOne(CompanionEnrollment.self, sql: "SELECT payload FROM companion_enrollments WHERE active=1", bindings: [])
    }
    public func setCompanionEnrollment(enabled: Bool) async throws -> CompanionEnrollment? {
        try requireInitialized()
        return try transaction {
            let current = try activeCompanionEnrollment()
            if enabled {
                if let current { return current }
                let enrollment = CompanionEnrollment(id: UUID(), active: true, startedAt: Date())
                try run("INSERT INTO companion_enrollments(id,active,payload) VALUES(?,1,?)", [.text(enrollment.id.uuidString), .blob(try encode(enrollment))])
                return enrollment
            }
            if let current {
                let closed = CompanionEnrollment(id: current.id, active: false, startedAt: current.startedAt)
                try run("UPDATE companion_enrollments SET active=0,payload=? WHERE id=?", [.blob(try encode(closed)), .text(current.id.uuidString)])
                return closed
            }
            return nil
        }
    }
    /// Called inside the NEW manifest's registration transaction. Never enroll old retries.
    func enrollCompanionManifest(_ manifest: AudioMediaManifest) throws {
        guard manifest.source == .microphone, let current = try activeCompanionEnrollment() else { return }
        try run("INSERT INTO companion_batch_candidates(manifest_id,enrollment_id,revision,state) VALUES(?,?,?,'waiting')",
            [.text(manifest.id.uuidString), .text(current.id.uuidString), .text(UUID().uuidString)])
    }
    public func companionBatchCandidate(manifestID: UUID) async throws -> CompanionBatchCandidate? {
        try requireInitialized()
        return try candidates("AND c.manifest_id=?", [.text(manifestID.uuidString)], limit: 1).first
    }
    public func companionBatchCandidates(now: Date, limit: Int) async throws -> [CompanionBatchCandidate] {
        try requireInitialized(); try CompanionBounds.date(now)
        guard (1...32).contains(limit) else { throw ContextStoreError.invalidInput }
        return try candidates("AND c.state='waiting' AND c.retry_after<=?", [.real(now.timeIntervalSince1970)], limit: limit)
    }
    private func candidates(_ predicate: String, _ bindings: [Binding], limit: Int) throws -> [CompanionBatchCandidate] {
        let statement = try prepare("""
            SELECT c.sequence,c.enrollment_id,c.revision,m.payload FROM companion_batch_candidates c
            JOIN companion_enrollments e ON e.id=c.enrollment_id AND e.active=1
            JOIN audio_media_manifests m ON m.id=c.manifest_id WHERE 1=1 \(predicate)
            ORDER BY c.retry_after,c.sequence DESC LIMIT ?
            """, bindings + [.integer(limit)])
        defer { sqlite3_finalize(statement) }
        var values: [CompanionBatchCandidate] = []
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { try Task.checkCancellation(); return values }
            guard status == SQLITE_ROW, let enrollment = UUID(uuidString: try textColumn(statement, 1)),
                  let revision = UUID(uuidString: try textColumn(statement, 2)) else { throw ContextStoreError.incompatibleDatabase }
            values.append(.init(sequence: sqlite3_column_int64(statement, 0), enrollmentID: enrollment,
                manifest: try decode(AudioMediaManifest.self, data: blobColumn(statement, 3)), revision: revision))
        }
    }
    public func finishCompanionBatch(_ candidate: CompanionBatchCandidate, disposition: CompanionBatchDisposition,
                                    groupID: String?, retryAfter: Date?) async throws {
        try requireInitialized()
        guard candidate.manifest.nativeStoreID == nativeStoreID else { throw ContextStoreError.nativeStoreMismatch }
        if let groupID { try CompanionBounds.digest(groupID) }
        if let retryAfter { try CompanionBounds.date(retryAfter) }
        guard (disposition == .published) == (groupID != nil), (disposition == .waiting) == (retryAfter != nil) else { throw ContextStoreError.invalidInput }
        try transaction {
            guard try scalar("SELECT count(*) FROM companion_batch_candidates WHERE sequence=? AND manifest_id=? AND enrollment_id=? AND revision=?",
                [.int64(candidate.sequence), .text(candidate.manifest.id.uuidString), .text(candidate.enrollmentID.uuidString), .text(candidate.revision.uuidString)]) == 1 else { throw ContextStoreError.revisionConflict }
            try run("UPDATE companion_batch_candidates SET revision=?,state=?,retry_after=?,group_id=?,attempts=attempts+1 WHERE sequence=?",
                [.text(UUID().uuidString), .text(disposition.rawValue), .real(retryAfter?.timeIntervalSince1970 ?? 0), groupID.map(Binding.text) ?? .null, .int64(candidate.sequence)])
        }
    }
}
