import Foundation

public protocol ResourceUsageProviding: Sendable {
    /// Cheap cached read; never enumerates processes or scans files.
    func snapshot() async -> ResourceUsageSnapshot
}
