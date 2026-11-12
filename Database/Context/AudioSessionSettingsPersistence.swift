import CryptoKit
import Foundation
import SQLCipher
import Shared

extension ContextDatabase {
    static let audioSessionSettingsSchema = """
        CREATE TABLE audio_session_settings(singleton INTEGER PRIMARY KEY CHECK(singleton=1), payload BLOB NOT NULL);
        CREATE TABLE audio_session_settings_commands(
            client_id TEXT NOT NULL, request_id TEXT NOT NULL, payload_digest BLOB NOT NULL, outcome BLOB NOT NULL,
            PRIMARY KEY(client_id,request_id));
        """

    public func initializeAudioSessionSettings(microphoneEnabled: Bool, systemAudioEnabled: Bool) throws -> AudioSessionSettings {
        try requireInitialized()
        return try transaction {
            if let existing = try readOne(AudioSessionSettings.self,
                sql: "SELECT payload FROM audio_session_settings WHERE singleton=1", bindings: []) { return existing }
            let settings = AudioSessionSettings(microphoneEnabled: microphoneEnabled, systemAudioEnabled: systemAudioEnabled)
            try run("INSERT INTO audio_session_settings(singleton,payload) VALUES(1,?)", [.blob(try encode(settings))])
            return settings
        }
    }

    public func audioSessionSettings() throws -> AudioSessionSettings {
        try requireInitialized()
        guard let settings = try readOne(AudioSessionSettings.self,
            sql: "SELECT payload FROM audio_session_settings WHERE singleton=1", bindings: []) else {
            throw ContextStoreError.notInitialized
        }
        return settings
    }

    public func applyAudioSessionSettings(_ command: AudioSessionSettingsCommand,
                                         fences: [NativeMutationFence] = []) throws -> AudioSessionSettingsReceipt {
        try requireInitialized()
        guard !command.clientID.isEmpty, command.clientID.utf8.count <= 128,
              !command.clientID.contains("\0"), fences.count <= 3,
              Set(fences.map(ObjectIdentifier.init)).count == fences.count else { throw ContextStoreError.invalidInput }
        let digest = Data(SHA256.hash(data: try encode(command)))
        return try withAudioSettingsAdmission(fences, index: 0) {
            try transaction {
                // Separate finalized reads avoid retaining a live statement over writes/COMMIT.
                if let retained = try audioSettingsReceipt(clientID: command.clientID, requestID: command.requestID) {
                    guard retained.0 == digest else { throw ContextStoreError.requestConflict }
                    return retained.1
                }
                let current = try audioSessionSettings()
                guard current.revision == command.expectedRevision else { throw ContextStoreError.revisionConflict }
                let changed = AudioSessionSettings(microphoneEnabled: command.microphoneEnabled,
                    systemAudioEnabled: command.systemAudioEnabled)
                let receipt = AudioSessionSettingsReceipt(requestID: command.requestID, settings: changed)
                try run("UPDATE audio_session_settings SET payload=? WHERE singleton=1", [.blob(try encode(changed))])
                try run("INSERT INTO audio_session_settings_commands(client_id,request_id,payload_digest,outcome) VALUES(?,?,?,?)",
                    [.text(command.clientID), .text(command.requestID.uuidString), .blob(digest), .blob(try encode(receipt))])
                for fence in fences { try fence.checkDeadline() }
                return receipt
            }
        }
    }

    private func withAudioSettingsAdmission<T>(_ fences: [NativeMutationFence], index: Int, body: () throws -> T) throws -> T {
        if index == fences.count { return try body() }
        return try fences[index].withAdmission { try withAudioSettingsAdmission(fences, index: index + 1, body: body) }
    }

    private func audioSettingsReceipt(clientID: String, requestID: UUID) throws -> (Data, AudioSessionSettingsReceipt)? {
        // Existing bounded decode helpers reject corrupt/oversized receipts.
        let statement = try prepare("SELECT payload_digest,outcome FROM audio_session_settings_commands WHERE client_id=? AND request_id=?",
            [.text(clientID), .text(requestID.uuidString)])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw ContextStoreError.incompatibleDatabase }
        return (try blobColumn(statement, 0, limit: 32), try decode(AudioSessionSettingsReceipt.self, data: blobColumn(statement, 1)))
    }
}
