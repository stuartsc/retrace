import Foundation
import Database
import SQLCipher
import Shared

/// Separate V23 reader. It performs bounded indexed candidate paging and revalidates
/// exact rows; it neither migrates recording storage nor starts a historical scanner.
public actor CompanionEvidenceReader {
    private let databasePath: String
    private let nativeStoreID: UUID
    private let adapter: DataAdapter
    private let recall: ProgressiveRecallService
    private let admission: @Sendable () async throws -> Void
    private let validateSpeaker: @Sendable (CompanionSpeakerRequest, [AudioTranscription]) async throws -> Void
    private var connection: SQLiteConnection?
    private var queries: AudioTranscriptionQueries?
    private var active = 0
    private var closed = false
    private var drained: [CheckedContinuation<Void, Never>] = []
    public init(databasePath: String, nativeStoreID: UUID, adapter: DataAdapter, recall: ProgressiveRecallService,
                admission: @escaping @Sendable () async throws -> Void,
                validateSpeaker: @escaping @Sendable (CompanionSpeakerRequest, [AudioTranscription]) async throws -> Void) {
        self.databasePath = databasePath; self.nativeStoreID = nativeStoreID; self.adapter = adapter; self.recall = recall
        self.admission = admission; self.validateSpeaker = validateSpeaker
    }
    /// Exact indexed batch lookup used only for explicitly enrolled manifests. An empty
    /// first-pass set remains pending; it never manufactures a transcript from AAC.
    public func firstPassRecords(manifest: AudioMediaManifest) async throws -> [AudioTranscription] {
        try begin(); defer { end() }; try await checkSource()
        guard manifest.nativeStoreID == nativeStoreID, manifest.source == .microphone else { throw CompanionError.nativeStoreMismatch }
        let query = try reader()
        let records = try await query.getContextBatchEntries(batchAudioPath: manifest.relativePath)
        if !records.isEmpty { _ = try CompanionTranscriptSnapshot.firstPassReferences(for: records, nativeStoreID: nativeStoreID) }
        try await checkSource(); return records
    }
    public func resolve(_ reference: V23TranscriptReference) async throws -> AudioTranscription {
        try begin(); defer { end() }
        return try await resolveOwned(reference)
    }
    private func resolveOwned(_ reference: V23TranscriptReference) async throws -> AudioTranscription {
        try await checkSource()
        let queries = try reader()
        guard let record = try await queries.getContextEntry(id: reference.rowID),
              try CompanionTranscriptSnapshot.matches(reference, record: record, nativeStoreID: nativeStoreID) else { throw CompanionError.staleEvidence }
        try await checkSource(); return record
    }
    public func revalidate(_ request: CompanionJobRequest) async throws {
        try begin(); defer { end() }
        try request.validate(); try await checkSource()
        guard request.sourceStoreID == nativeStoreID else { throw CompanionError.nativeStoreMismatch }
        if let speaker = request.speaker {
            let records = try await firstPass(speaker)
            try await validateSpeaker(speaker, records)
            _ = try await firstPass(speaker)
        }
        if let context = request.context {
            for item in context.evidence {
                try Task.checkCancellation()
                switch item.reference.kind {
                case .screen:
                    guard let ref = item.reference.screen else { throw CompanionError.invalidPayload }
                    try await recall.validateNativeScreenAction(ref)
                    let page = try await recall.expandScreenEvidence(.init(reference: ref, blockLimit: 64, maximumUTF8Bytes: 4096), for: .localUser)
                    guard CompanionWire.sameWireDate(page.captureTimestamp, item.start), CompanionWire.sameWireDate(item.start, item.end),
                          page.fragments.map(\.text).joined(separator: "\n") == item.text else { throw CompanionError.staleEvidence }
                    try await recall.validateNativeScreenAction(ref)
                case .v23Transcript:
                    guard let ref = item.reference.v23Transcript else { throw CompanionError.invalidPayload }
                    let row = try await resolveOwned(ref)
                    guard CompanionWire.sameWireDate(row.startTime, item.start), CompanionWire.sameWireDate(row.endTime, item.end), row.text.contains(item.text) else { throw CompanionError.staleEvidence }
                case .transcript:
                    // This checkout has V23 mutable rows, never fabricated V30 transcript revisions.
                    throw CompanionError.staleEvidence
                case .media:
                    // Media anchors are admitted by the controller against the current persisted marker.
                    guard item.reference.media?.nativeStoreID == nativeStoreID else { throw CompanionError.nativeStoreMismatch }
                }
            }
        }
        try await checkSource()
    }

    private func firstPass(_ request: CompanionSpeakerRequest) async throws -> [AudioTranscription] {
        guard let first = request.firstPassReferences.first else { throw CompanionError.staleEvidence }
        let query = try reader()
        guard let original = try await query.getRetainedFirstPassEntry(id: first.rowID),
              let path = original.batchAudioPath else { throw CompanionError.staleEvidence }
        let current = try await query.getContextBatchEntries(batchAudioPath: path)
        let references: [V23TranscriptReference]
        do { references = try CompanionTranscriptSnapshot.firstPassReferences(for: current, nativeStoreID: nativeStoreID) }
        catch { throw CompanionError.staleEvidence }
        guard references == request.firstPassReferences,
              current.map(\.text).joined(separator: "\n") == request.firstPassText else { throw CompanionError.staleEvidence }
        try Task.checkCancellation()
        return current
    }

    /// Retrieval is lexical candidate paging over the native index, followed by
    /// bounded companion semantic ranking. The absence of a time filter is deliberate.
    public func contextRequest(marker: TimelineMarker, query: String, verbatimExplanation: String, expectedProposalHead: UUID? = nil) async throws -> CompanionJobRequest {
        try begin(); defer { end() }
        try await checkSource()
        guard marker.nativeStoreID == nativeStoreID, marker.deletedAt == nil else { throw CompanionError.staleMarker }
        try CompanionBounds.text(query, max: 8192)
        try CompanionBounds.text(verbatimExplanation, max: 16384, empty: true)
        let terms = Self.terms(query + " " + verbatimExplanation)
        guard !terms.isEmpty else { throw CompanionError.invalidPayload }
        var items: [CompanionEvidenceItem] = [], seen = Set<String>(), totalBytes = 0, screenPages = 0, audioPages = 0
        // Candidate retrieval and full source coverage remain incomplete by design:
        // a bounded lexical shortlist cannot claim to include every semantic support.
        var incomplete = true
        for term in terms {
            var cursor: SearchPageCursor?
            repeat {
                try await checkSource()
                let page = try await adapter.search(query: .init(text: term, limit: 16, cursor: cursor, mode: .relevant), nativeOnly: true)
                screenPages += 1
                for hit in page.results where items.count < 128 {
                    do {
                    guard hit.source == .native else { throw CompanionError.nativeStoreMismatch }
                    let reference = try await recall.reference(searchResult: hit)
                    try await recall.validateNativeScreenAction(reference)
                    let id = "screen:" + CompanionWire.digest(try CompanionWire.encode(reference))
                    guard seen.insert(id).inserted else { continue }
                    let text = try await recall.expandScreenEvidence(.init(reference: reference, blockLimit: 64, maximumUTF8Bytes: 4096), for: .localUser)
                    try await recall.validateNativeScreenAction(reference)
                    let body = text.fragments.map(\.text).joined(separator: "\n")
                    if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    totalBytes += body.utf8.count
                    if totalBytes > 384 * 1024 { incomplete = true; break }
                    items.append(.init(id: id, reference: .init(screen: reference), start: text.captureTimestamp,
                        end: text.captureTimestamp, text: body, appName: text.context.appName, windowTitle: text.context.windowName))
                    incomplete = incomplete || text.nextCursor != nil
                    } catch let reason as EvidenceUnavailableReason where [.notPermitted, .evidenceDeleted, .extractionUnavailable, .recordingMissing].contains(reason) {
                        // A hidden/deleted individual candidate does not suppress other readable evidence.
                        incomplete = true
                    } catch RetraceCommandError.revisionConflict {
                        incomplete = true
                    }
                }
                cursor = page.nextCursor
            } while cursor != nil && items.count < 128 && totalBytes < 384 * 1024 && screenPages < 16
            if items.count >= 128 || totalBytes >= 384 * 1024 || screenPages >= 16 { break }
        }
        let audio = try reader()
        for term in terms {
            var cursor: AudioContextCursor?
            repeat {
                try await checkSource()
                let page = try await audio.getContextPage(from: Date(timeIntervalSince1970: 0),
                    to: Date(timeIntervalSince1970: 253_402_300_000), limit: 16, before: cursor, query: term)
                audioPages += 1
                // Existing bounded retrieval may continue empty candidate pages;
                // its result must never describe unchecked history as complete.
                incomplete = incomplete || page.scanIncomplete || page.nextCursor != nil
                for row in page.entries where items.count < 256 {
                    guard row.transcriptStatus == "transcribed", !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          row.source == .microphone || row.source == .system else { continue }
                    let reference = try CompanionTranscriptSnapshot.reference(for: row, nativeStoreID: nativeStoreID)
                    let identity = "v23:" + reference.snapshotSHA256
                    guard seen.insert(identity).inserted else { continue }
                    // Select a real contiguous excerpt containing the retrieval term, with an explicit coverage flag.
                    let body = Self.excerpt(row.text, matching: term, maximumBytes: 4096)
                    totalBytes += body.utf8.count
                    if totalBytes > 512 * 1024 { break }
                    items.append(.init(id: identity, reference: .init(v23Transcript: reference), start: row.startTime, end: row.endTime, text: body))
                }
                cursor = page.nextCursor
            } while cursor != nil && items.count < 256 && totalBytes < 512 * 1024 && audioPages < 16
            if items.count >= 256 || totalBytes >= 512 * 1024 || audioPages >= 16 { break }
        }
        let request = CompanionJobRequest(sourceStoreID: nativeStoreID, observedAt: marker.anchoredAt,
            context: .init(markerID: marker.id, markerRevision: marker.revision, snapshotID: UUID(), query: query,
                verbatimExplanation: verbatimExplanation, developing: true, incomplete: incomplete, evidence: items, expectedProposalHead: expectedProposalHead))
        try request.validate()
        // Optimistic across current source reads: never label it an atomic cross-store snapshot.
        try await revalidate(request); return request
    }
    private func reader() throws -> AudioTranscriptionQueries {
        if let queries { return queries }
        guard !closed else { throw CompanionError.closed }; try Task.checkCancellation()
        let opened = try SQLiteConnection(readOnlyDatabasePath: databasePath)
        let statement = try opened.prepare(sql: "SELECT storeID FROM evidence_store WHERE source='native' AND identity='native'")
        defer { opened.finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0),
              UUID(uuidString: String(cString: raw)) == nativeStoreID, let pointer = opened.getConnection() else { throw CompanionError.nativeStoreMismatch }
        connection = opened; let queries = AudioTranscriptionQueries(db: pointer); self.queries = queries; return queries
    }
    private func checkSource() async throws {
        try Task.checkCancellation(); try await admission(); try Task.checkCancellation()
        guard try await adapter.evidenceStoreID(source: .native) == nativeStoreID else { throw CompanionError.nativeStoreMismatch }
        try Task.checkCancellation()
    }
    private func begin() throws { guard !closed else { throw CompanionError.closed }; try Task.checkCancellation(); active += 1 }
    private func end() { active -= 1; if active == 0 { let waiters = drained; drained = []; waiters.forEach { $0.resume() } } }
    public func close() async {
        closed = true
        if active > 0 { await withCheckedContinuation { drained.append($0) } }
        queries = nil; connection = nil
    }
    private static func terms(_ text: String) -> [String] {
        let stop: Set<String> = ["the", "and", "this", "that", "with", "from", "have", "what", "when", "were", "remember", "mark"]
        var seen = Set<String>()
        return text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.utf8.count >= 3 && $0.utf8.count <= 128 && !stop.contains($0) && seen.insert($0).inserted }.prefix(8).map { $0 }
    }
    private static func excerpt(_ text: String, matching term: String, maximumBytes: Int) -> String {
        if text.utf8.count <= maximumBytes { return text }
        let match = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound ?? text.startIndex
        let start = text.index(match, offsetBy: -256, limitedBy: text.startIndex) ?? text.startIndex
        var result = ""
        for character in text[start...] {
            if result.utf8.count + character.utf8.count > maximumBytes { break }
            result.append(character)
        }
        return result
    }
}
