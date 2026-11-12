import Database
import Foundation
import Shared

/// A bounded pass over durable eligibility, independent of callbacks and network status.
enum CompanionBatchReconciler {
    static func run(markers: TimelineMarkerService,
        readFirstPass: @Sendable (AudioMediaManifest) async throws -> [AudioTranscription],
        publish: @Sendable (CompanionBatchCandidate, [AudioTranscription]) async throws -> CompanionBatchPublicationReceipt,
        checkAdmission: @Sendable () throws -> Void,
        terminalSourceFailure: @Sendable (any Error) -> Bool) async throws {
        let candidates = try await markers.companionBatchCandidates(now: Date(), limit: 8)
        var firstFailure: (any Error)?
        for candidate in candidates {
            try Task.checkCancellation(); try checkAdmission()
            do {
                let rows = try await readFirstPass(candidate.manifest)
                if rows.isEmpty {
                    try await markers.finishCompanionBatch(candidate, disposition: .waiting, groupID: nil, retryAfter: Date().addingTimeInterval(30))
                    continue
                }
                let receipt = try await publish(candidate, rows)
                try checkAdmission(); try Task.checkCancellation()
                try await markers.finishCompanionBatch(candidate, disposition: .published, groupID: receipt.groupID, retryAfter: nil)
            } catch is CancellationError { throw CancellationError() }
            catch ContextStoreError.revisionConflict { continue }
            catch {
                if terminalSourceFailure(error) {
                    try await markers.finishCompanionBatch(candidate, disposition: .sourceUnavailable, groupID: nil, retryAfter: nil)
                } else {
                    try await markers.finishCompanionBatch(candidate, disposition: .waiting, groupID: nil, retryAfter: Date().addingTimeInterval(30))
                    if firstFailure == nil { firstFailure = error }
                }
            }
        }
        if let firstFailure { throw firstFailure }
    }
}
