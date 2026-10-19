import Foundation
import Shared

/// One cached report selection for Dashboard and Settings. No filesystem reads.
struct StorageUsagePresentation {
    let report: StorageUsageReport?
    let isPartial: Bool
    let isShowingLastComplete: Bool
    let isScanning: Bool

    init(snapshot: StorageUsageSnapshot) {
        let latest = snapshot.latestReport
        report = latest?.isComplete == true ? latest : (snapshot.lastCompleteReport ?? latest)
        isPartial = report.map { !$0.isComplete } ?? false
        isShowingLastComplete = latest?.isComplete == false && snapshot.lastCompleteReport != nil
        isScanning = snapshot.isScanning
    }

    var value: String {
        guard let report else { return "Not measured" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: report.total.allocatedBytes), countStyle: .binary)
    }

    var subtitle: String {
        guard let report else { return isScanning ? "Measuring storage…" : "Awaiting periodic check" }
        let label = isPartial ? "Partial" : (isShowingLastComplete ? "Last complete" : "Allocated")
        return "\(label) · \(report.finishedAt.formatted(date: .omitted, time: .shortened))"
    }

    var detail: String {
        "Includes screen and audio recordings, database, models, caches, logs, backup and candidate copies. " +
        "Checked every 15 minutes; see Settings → Storage for the breakdown. " +
        "Shared APFS blocks mean allocated file space can exceed uniquely occupied space."
    }
}
