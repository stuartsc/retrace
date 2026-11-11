import Foundation
import Shared

/// A pinned strip may outlive many journal revisions. Resolve the same attempt
/// again for each click, so new recording and completed retention remain usable.
enum CapturedMomentNavigation {
    static func resolve(store: any CaptureGroupStoreProtocol, selected: ScreenEvidenceRef,
                        attemptID: UUID) async throws -> ScreenEvidenceRef? {
        try Task.checkCancellation()
        guard let fresh = try await store.captureGroup(for: selected) else { return nil }
        try Task.checkCancellation()
        let reference = fresh.members.first { $0.target.attemptID == attemptID }?.reference
        try await store.revalidateCaptureGroupRead(fresh.stamp)
        try Task.checkCancellation()
        return reference
    }
}
