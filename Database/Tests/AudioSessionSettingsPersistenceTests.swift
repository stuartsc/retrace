import Foundation
import Shared
import SQLCipher
import XCTest
@testable import Database

final class AudioSessionSettingsPersistenceTests: XCTestCase {
    private var directory: URL!
    private var database: ContextDatabase!
    private let nativeID = UUID()
    private var path: String { directory.appendingPathComponent("context.db").path }
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("audio-settings-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        database = ContextDatabase(databasePath: path, nativeStoreID: nativeID)
        try await database.initialize()
    }
    override func tearDown() async throws {
        try await database.close()
        try FileManager.default.removeItem(at: directory)
    }

    func testSeedCASAndHistoricalRetrySurviveReopenWithoutRestoringOldSettings() async throws {
        let original = try await database.initializeAudioSessionSettings(microphoneEnabled: true, systemAudioEnabled: false)
        let unchanged = try await database.initializeAudioSessionSettings(microphoneEnabled: false, systemAudioEnabled: true)
        XCTAssertEqual(original, unchanged)
        let command = AudioSessionSettingsCommand(expectedRevision: original.revision, microphoneEnabled: false, systemAudioEnabled: false)
        let disabled = try await database.applyAudioSessionSettings(command)
        let enabled = try await database.applyAudioSessionSettings(.init(expectedRevision: disabled.settings.revision,
            microphoneEnabled: true, systemAudioEnabled: false))
        try await database.close()
        database = ContextDatabase(databasePath: path, nativeStoreID: nativeID)
        try await database.initialize()
        let retry = try await database.applyAudioSessionSettings(command)
        XCTAssertEqual(retry, disabled)
        let current = try await database.audioSessionSettings()
        XCTAssertEqual(current, enabled.settings)
        do {
            _ = try await database.applyAudioSessionSettings(.init(expectedRevision: original.revision,
                microphoneEnabled: false, systemAudioEnabled: false))
            XCTFail("A stale revision cannot change recording settings")
        } catch ContextStoreError.revisionConflict { }
        do {
            _ = try await database.applyAudioSessionSettings(.init(clientID: command.clientID, requestID: command.requestID,
                expectedRevision: command.expectedRevision, microphoneEnabled: true, systemAudioEnabled: false))
            XCTFail("A request cannot change its meaning")
        } catch ContextStoreError.requestConflict { }
    }

    func testFailedReceiptRevokedGrantAndExpiredAdmissionLeaveSettingsUnchanged() async throws {
        let original = try await database.initializeAudioSessionSettings(microphoneEnabled: true, systemAudioEnabled: false)
        let command = AudioSessionSettingsCommand(expectedRevision: original.revision, microphoneEnabled: false, systemAudioEnabled: false)
        try sql("CREATE TRIGGER reject_audio_receipt BEFORE INSERT ON audio_session_settings_commands BEGIN SELECT RAISE(ABORT,'injected'); END")
        do { _ = try await database.applyAudioSessionSettings(command); XCTFail("Receipt failure must roll back settings") }
        catch { }
        let afterFailure = try await database.audioSessionSettings()
        XCTAssertEqual(afterFailure, original)
        try sql("DROP TRIGGER reject_audio_receipt")
        let revoked = NativeMutationFence(); revoked.invalidate()
        for fence in [revoked, NativeMutationFence(expiresAt: .distantPast)] {
            do { _ = try await database.applyAudioSessionSettings(command, fences: [fence]); XCTFail("Denied admission cannot commit") }
            catch is CancellationError { }
        }
        let afterDenied = try await database.audioSessionSettings()
        XCTAssertEqual(afterDenied, original)
    }

    func testIndependentWriterCASAndMalformedSettingsFailClosed() async throws {
        let original = try await database.initializeAudioSessionSettings(microphoneEnabled: true, systemAudioEnabled: false)
        let second = ContextDatabase(databasePath: path, nativeStoreID: nativeID)
        try await second.initialize()
        _ = try await second.applyAudioSessionSettings(.init(expectedRevision: original.revision,
            microphoneEnabled: false, systemAudioEnabled: false))
        do { _ = try await database.applyAudioSessionSettings(.init(expectedRevision: original.revision,
            microphoneEnabled: true, systemAudioEnabled: true)); XCTFail("Independent writer invalidates revision") }
        catch ContextStoreError.revisionConflict { }
        try await second.close()
        try sql("UPDATE audio_session_settings SET payload=X'7B7D'")
        do { _ = try await database.initializeAudioSessionSettings(microphoneEnabled: true, systemAudioEnabled: false)
            XCTFail("Malformed persisted settings cannot silently enable a microphone") }
        catch { }
    }

    func testVersionFourMigrationAddsOnlyContextTablesAndRetainsMarker() async throws {
        let marker = try await database.createManualMarker(.init(anchoredAt: Date(), title: "Authored migration marker"))
        try await database.close()
        try sql("DROP TABLE audio_session_settings; DROP TABLE audio_session_settings_commands; PRAGMA user_version=4")
        database = ContextDatabase(databasePath: path, nativeStoreID: nativeID)
        try await database.initialize()
        let retained = try await database.marker(id: marker.id, includeDeleted: false)
        XCTAssertEqual(retained, marker)
        let settings = try await database.initializeAudioSessionSettings(microphoneEnabled: false, systemAudioEnabled: false)
        XCTAssertFalse(settings.microphoneEnabled)
        XCTAssertFalse(settings.systemAudioEnabled)
    }

    private func sql(_ query: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else { throw ContextStoreError.notInitialized }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, query, nil, nil, nil) == SQLITE_OK else { throw ContextStoreError.incompatibleDatabase }
    }
}
