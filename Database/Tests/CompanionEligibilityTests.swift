import Foundation
import Shared
import XCTest
@testable import Database

final class CompanionEligibilityTests: XCTestCase {
    func testEnrollmentOnlyAdmitsNewRegistrationsAndRestartRetainsPendingCandidate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = UUID(), path = root.appendingPathComponent("context.db").path
        let db = ContextDatabase(databasePath: path, nativeStoreID: native)
        try await db.initialize()
        let old = manifest(native)
        _ = try await db.registerAudioManifest(old)
        let enrollment = try await db.setCompanionEnrollment(enabled: true)
        _ = try await db.registerAudioManifest(old)
        let fresh = manifest(native)
        _ = try await db.registerAudioManifest(fresh)
        let eligible = try await db.companionBatchCandidates(now: Date(), limit: 8)
        XCTAssertEqual(eligible.map(\.manifest.id), [fresh.id])
        XCTAssertEqual(eligible.first?.enrollmentID, enrollment?.id)
        try await db.close()
        let reopened = ContextDatabase(databasePath: path, nativeStoreID: native)
        try await reopened.initialize()
        let resumed = try await reopened.setCompanionEnrollment(enabled: true)
        XCTAssertEqual(resumed, enrollment)
        let pending = try await reopened.companionBatchCandidates(now: Date(), limit: 8)
        XCTAssertEqual(pending.map(\.manifest.id), [fresh.id])
        _ = try await reopened.setCompanionEnrollment(enabled: false)
        let disabled = manifest(native); _ = try await reopened.registerAudioManifest(disabled)
        let next = try await reopened.setCompanionEnrollment(enabled: true)
        XCTAssertNotEqual(next?.id, enrollment?.id)
        let noBackfill = try await reopened.companionBatchCandidates(now: Date(), limit: 8)
        XCTAssertTrue(noBackfill.isEmpty)
        try await reopened.close()
    }
    private func manifest(_ native: UUID) -> AudioMediaManifest {
        let id = UUID()
        return .init(id: id, nativeStoreID: native, relativePath: "audio/" + id.uuidString + ".m4a",
            sha256: String(repeating: "a", count: 64), frameCount: 16000,
            sourceRanges: [.init(source: .init(recordingGeneration: UUID(), continuityID: UUID(), startSample: 0,
                sampleCount: 16000, sampleRate: 16000, approximateOrigin: Date(timeIntervalSince1970: 1_800_000_000)), batchStartSample: 0)])
    }
}
