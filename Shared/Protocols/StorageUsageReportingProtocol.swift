import Foundation

public protocol StorageUsageReportingProtocol: Sendable {
    /// Construction is inert. Start performs an initial scan and enables periodic refresh.
    func start() async
    /// Returns cached metadata only; never traverses a filesystem.
    func snapshot() async -> StorageUsageSnapshot
    /// Concurrent callers join one scan. Cancelling a waiter does not cancel shared work.
    @discardableResult func refresh() async -> StorageUsageSnapshot
    /// Terminal cancellation joins the periodic loop and current scan before returning.
    func close() async
}
