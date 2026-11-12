import Darwin
import Database
import Foundation
import Shared

/// Reads only atomically published immutable objects. It never acquires the delivery writer
/// lease, creates a directory, changes receipts, configures transport or starts inference.
struct CompanionSpeakerCatalog: Sendable {
    let spool: CompanionSpool
    let reader: CompanionEvidenceReader

    struct IndexedPage: Sendable { let jobIDs: [String]; let nextCursor: String? }
    private struct IndexedCursor: Codable { let version: Int; let catalog: CompanionDeliveryCursor }

    /// A bounded fixed-receipt keyset page. A missing/unpublished database falls back
    /// to the bounded legacy catalog; a ready database is always authoritative.
    func indexedPage(from: Date, to: Date, before: String?, limit: Int) async throws -> IndexedPage? {
        guard let index = try await openIndex() else { return nil }
        do {
            let cursor: CompanionDeliveryCursor?
            if let before {
                guard before.utf8.count <= 4096, let bytes = Data(base64Encoded: before),
                      let value = try? CompanionWire.decode(IndexedCursor.self, data: bytes, limit: 3072),
                      value.version == 1 else { throw CompanionError.staleEvidence }
                cursor = value.catalog
            } else { cursor = nil }
            let page = try await index.speakerPage(from: from, to: to, before: cursor, limit: limit)
            let next = try page.nextCursor.map { try CompanionWire.encode(IndexedCursor(version: 1, catalog: $0)).base64EncodedString() }
            try await index.close()
            return .init(jobIDs: page.records.map(\.jobID), nextCursor: next)
        } catch { try? await index.close(); throw error }
    }

    func requests() throws -> [(String, CompanionJobRequest)] {
        guard try available() else { return [] }
        let files = try spool.entries("requests")
        guard files.count <= 256 else { throw CompanionError.capacityExceeded }
        return try files.compactMap { file -> (String, CompanionJobRequest)? in
            guard file.pathExtension == "json" else { throw CompanionError.unsafeStorage }
            let id = file.deletingPathExtension().lastPathComponent
            if try invalidated(id) { return nil }
            let request = try loadRequest(id)
            guard request.speaker != nil else { return nil }
            return (id, request)
        }.sorted { $0.1.observedAt == $1.1.observedAt ? $0.0 < $1.0 : $0.1.observedAt > $1.1.observedAt }
    }

    func retained(_ id: String) async throws -> (CompanionJobRequest, CompanionResult, resultSHA256: String)? {
        try CompanionBounds.digest(id)
        if let index = try await openIndex() {
            do {
                guard let record = try await index.record(jobID: id),
                      [.imported, .acknowledged].contains(record.stage), let bytes = record.resultPayload else {
                    try await index.close(); return nil
                }
                let request = try CompanionWire.decode(CompanionJobRequest.self, data: record.requestPayload, limit: 768 * 1024)
                try request.validate()
                guard request.sourceStoreID == spool.nativeStoreID else { throw CompanionError.nativeStoreMismatch }
                guard request.speaker != nil else { try await index.close(); return nil }
                let result = try CompanionWire.decode(CompanionResult.self, data: bytes, limit: 2 * 1024 * 1024)
                try CompanionWire.validate(result, request: request, id: id)
                try await reader.revalidate(request)
                guard try available(), let current = try await index.record(jobID: id),
                      [.imported, .acknowledged].contains(current.stage),
                      current.requestPayload == record.requestPayload, current.resultPayload == bytes else { throw CompanionError.staleEvidence }
                try Task.checkCancellation(); try await index.close()
                return (request, result, CompanionWire.digest(bytes))
            } catch { try? await index.close(); throw error }
        }
        guard try available(), try invalidated(id) == false else { return nil }
        let imported = try spool.path("receipts", id, suffix: ".imported")
        guard spool.exists(imported) else { return nil }
        let request = try loadRequest(id)
        guard request.speaker != nil else { return nil }
        let bytes = try spool.read(spool.path("results", id), limit: 2 * 1024 * 1024)
        let digest = Data(CompanionWire.digest(bytes).utf8)
        guard try spool.read(imported, limit: 64) == digest else { throw CompanionError.conflictingPublication }
        let result = try CompanionWire.decode(CompanionResult.self, data: bytes, limit: 2 * 1024 * 1024)
        try CompanionWire.validate(result, request: request, id: id)
        try await reader.revalidate(request)
        guard try available(), try invalidated(id) == false, try spool.read(imported, limit: 64) == digest else { throw CompanionError.staleEvidence }
        try Task.checkCancellation()
        return (request, result, CompanionWire.digest(bytes))
    }

    private func openIndex() async throws -> CompanionDeliveryDatabase? {
        guard try available() else { return nil }
        let path = spool.root.appendingPathComponent("delivery.db").path
        var info = stat()
        guard lstat(path, &info) == 0 else {
            guard errno == ENOENT else { throw CompanionError.unsafeStorage }
            return nil
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0 else { throw CompanionError.unsafeStorage }
        // The writer creates its private empty file before publishing SQLite metadata.
        if info.st_size == 0 { return nil }
        let index = CompanionDeliveryDatabase(databasePath: path,
            nativeStoreID: spool.nativeStoreID, readOnly: true)
        do {
            try await index.initialize()
            guard try await index.migrationComplete() else { try await index.close(); return nil }
            return index
        } catch CompanionDeliveryDatabaseError.unpublished {
            try? await index.close(); return nil
        } catch { try? await index.close(); throw error }
    }

    private func loadRequest(_ id: String) throws -> CompanionJobRequest {
        let data = try spool.read(spool.path("requests", id), limit: 768 * 1024)
        guard CompanionWire.digest(data) == id else { throw CompanionError.conflictingPublication }
        let request = try CompanionWire.decode(CompanionJobRequest.self, data: data, limit: 768 * 1024)
        try request.validate()
        guard request.sourceStoreID == spool.nativeStoreID else { throw CompanionError.nativeStoreMismatch }
        return request
    }
    private func invalidated(_ id: String) throws -> Bool {
        let path = try spool.path("receipts", id, suffix: ".invalidated")
        guard spool.exists(path) else { return false }
        guard try spool.read(path, limit: 64) == Data(id.utf8) else { throw CompanionError.conflictingPublication }
        return true
    }
    private func available() throws -> Bool {
        var info = stat()
        guard lstat(spool.root.path, &info) == 0 else {
            guard errno == ENOENT else { throw CompanionError.unsafeStorage }
            return false
        }
        for path in [spool.root, spool.root.appendingPathComponent("requests"), spool.root.appendingPathComponent("results"), spool.root.appendingPathComponent("receipts")] {
            // The writer publishes these directories and its store binding in
            // order. An offline read can race that first initialization; absent
            // components mean no published catalog yet, not corrupt ownership.
            guard lstat(path.path, &info) == 0 else {
                guard errno == ENOENT else { throw CompanionError.unsafeStorage }
                return false
            }
            guard info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw CompanionError.unsafeStorage }
        }
        let binding = spool.root.appendingPathComponent("native-store")
        guard lstat(binding.path, &info) == 0 else {
            guard errno == ENOENT else { throw CompanionError.unsafeStorage }
            return false
        }
        guard try spool.read(binding, limit: 64) == Data(spool.nativeStoreID.uuidString.utf8) else { throw CompanionError.nativeStoreMismatch }
        return true
    }
}
