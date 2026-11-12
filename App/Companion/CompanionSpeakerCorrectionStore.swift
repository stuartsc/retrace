import Darwin
import Foundation
import Shared

/// Independent manual overrides for an exact inference cluster. Never trains or edits Outlook.
actor CompanionSpeakerCorrectionStore {
    private struct Payload: Codable { let command: CompanionSpeakerCorrectionCommand; let nativeStoreID: UUID; let sourceIdentity: LiveAudioSampleIdentity }
    private struct Record: Codable { let sequence: Int; let payload: Payload; let digest: String; let correction: CompanionSpeakerCorrection }
    private let spool: CompanionSpool
    private var lease: Int32?
    private var ready = false
    private var terminal = false
    private var receipts: [String: Record] = [:]
    private var current: [String: CompanionSpeakerCorrection] = [:]
    init(root: URL, nativeStoreID: UUID) { spool = .init(root: root, nativeStoreID: nativeStoreID) }
    func list(speakerIDs: Set<String>, sourceIdentity: LiveAudioSampleIdentity) throws -> [CompanionSpeakerCorrection] {
        let sourceIdentity = try canonicalSource(sourceIdentity)
        try initialize()
        return speakerIDs.compactMap { current[$0] }.filter { $0.sourceIdentity == sourceIdentity }.sorted { $0.speakerID < $1.speakerID }
    }
    func apply(_ command: CompanionSpeakerCorrectionCommand, sourceIdentity: LiveAudioSampleIdentity,
               admission: @Sendable () throws -> Void = {}) throws -> CompanionSpeakerCorrection {
        try admission()
        let sourceIdentity = try canonicalSource(sourceIdentity)
        try CompanionBounds.text(command.clientID, max: 128)
        try CompanionBounds.digest(command.jobID); try CompanionBounds.text(command.speakerID, max: 160)
        guard sourceIdentity.isValid, command.displayName != nil || command.personID == nil else { throw CompanionError.invalidPayload }
        if let label = command.displayName { try CompanionBounds.text(label, max: 256) }
        if let person = command.personID { try CompanionBounds.text(person, max: 128) }
        try initialize()
        let payload = Payload(command: command, nativeStoreID: spool.nativeStoreID, sourceIdentity: sourceIdentity)
        let digest = CompanionWire.digest(try CompanionWire.encode(payload))
        let key = CompanionWire.digest(try CompanionWire.encode([command.clientID, command.requestID.uuidString]))
        if let receipt = receipts[key] {
            guard receipt.digest == digest else { throw CompanionError.conflictingPublication }
            try admission()
            return current[command.speakerID] ?? receipt.correction
        }
        let old = current[command.speakerID]
        guard old?.revision == command.expectedRevision else { throw ContextStoreError.revisionConflict }
        guard old == nil || old?.sourceIdentity == sourceIdentity else { throw CompanionError.staleEvidence }
        guard receipts.count < 1024 else { throw CompanionError.capacityExceeded }
        let correction = CompanionSpeakerCorrection(nativeStoreID: spool.nativeStoreID, speakerID: command.speakerID,
            sourceIdentity: sourceIdentity, revision: UUID(), displayName: command.displayName, personID: command.personID, updatedAt: Date())
        let data = try CompanionWire.encode(Record(sequence: receipts.count + 1, payload: payload, digest: digest, correction: correction))
        // Return the persisted representation on the first write as well as replay.
        // Date's epoch conversion can otherwise move the approximate wall clock by
        // one floating-point unit, while UUIDs and PCM sample offsets stay exact.
        let record = try CompanionWire.decode(Record.self, data: data, limit: 16_384)
        try admission()
        do { try spool.publish(data, to: spool.path("requests", key)) }
        catch { ready = false; throw error }
        receipts[key] = record; current[command.speakerID] = record.correction
        return record.correction
    }
    private func canonicalSource(_ value: LiveAudioSampleIdentity) throws -> LiveAudioSampleIdentity {
        try CompanionWire.decode(LiveAudioSampleIdentity.self, data: CompanionWire.encode(value), limit: 4_096)
    }
    private func initialize() throws {
        guard !terminal else { throw CompanionError.closed }; try Task.checkCancellation()
        if ready { return }
        if lease == nil {
            let descriptor = try spool.acquire()
            do { try spool.initialize(); lease = descriptor }
            catch { Darwin.close(descriptor); throw error }
        }
        let paths = try spool.entries("requests")
        guard paths.count <= 1024 else { throw CompanionError.capacityExceeded }
        let loaded = try paths.map { path -> (String, Record) in
            let key = path.deletingPathExtension().lastPathComponent
            let record = try CompanionWire.decode(Record.self, data: spool.read(path, limit: 16_384), limit: 16_384)
            guard CompanionWire.digest(try CompanionWire.encode([record.payload.command.clientID, record.payload.command.requestID.uuidString])) == key,
                  record.digest == CompanionWire.digest(try CompanionWire.encode(record.payload)),
                  record.payload.nativeStoreID == spool.nativeStoreID,
                  record.correction.nativeStoreID == spool.nativeStoreID,
                  record.correction.sourceIdentity == record.payload.sourceIdentity,
                  record.correction.speakerID == record.payload.command.speakerID,
                  record.correction.displayName == record.payload.command.displayName,
                  record.correction.personID == record.payload.command.personID else { throw CompanionError.conflictingPublication }
            return (key, record)
        }.sorted { $0.1.sequence < $1.1.sequence }
        receipts = [:]; current = [:]
        for (key, record) in loaded {
            guard record.sequence == receipts.count + 1,
                  current[record.correction.speakerID]?.revision == record.payload.command.expectedRevision else { throw CompanionError.conflictingPublication }
            receipts[key] = record; current[record.correction.speakerID] = record.correction
        }
        ready = true
    }
    func close() { terminal = true; if let lease { Darwin.close(lease); self.lease = nil } }
}
