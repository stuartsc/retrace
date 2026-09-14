import Foundation

/// The existing canonical database actor owns all writes; consumers never receive its connection.
public protocol ActivityStoreProtocol: Actor {
    func activityStoreID() async throws -> UUID
    func appendActivity(_ event: ActivityEvent) async throws -> PersistedActivityEvent
    func searchActivity(_ query: ActivityQuery) async throws -> ActivityPage
    func activityEvent(id: UUID) async throws -> PersistedActivityEvent?
    func activityHealth() async throws -> ActivityStoreHealth
    func activityFeed(after sequence: Int64, limit: Int) async throws -> [ActivityFeedEntry]
    func acknowledgeActivityFeed(consumer: String, through sequence: Int64) async throws
    func activityFeedCheckpoint(consumer: String) async throws -> Int64
    func submitActivityCorrection(_ command: ActivityCorrection) async throws -> ActivityCorrectionReceipt
    func activityCorrections() async throws -> [ActivityCorrectionReceipt]
    func acknowledgeActivityCorrection(id: UUID, expectedRevision: Int64, applied: Bool) async throws
    func deleteActivity(eventIDs: [UUID]) async throws
    func linkActivityScreen(eventID: UUID, screen: ScreenEvidenceRef, capturedAt: Date, method: String) async throws -> ActivityScreenLink
    func activityScreenLinks(eventID: UUID, afterSequence: Int64, limit: Int) async throws -> [ActivityScreenLink]
}

// Narrow test/unsupported stores may retain activity without exposing screen links.
// DatabaseManager implements both operations durably on its canonical connection.
public extension ActivityStoreProtocol {
    func linkActivityScreen(eventID: UUID, screen: ScreenEvidenceRef, capturedAt: Date, method: String) async throws -> ActivityScreenLink {
        throw DatabaseError.queryFailed(query: "linkActivityScreen", underlying: "Screen linking is unsupported by this store")
    }
    func activityScreenLinks(eventID: UUID, afterSequence: Int64, limit: Int) async throws -> [ActivityScreenLink] { [] }
}
