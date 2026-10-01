import Foundation

/// Automatic work and scoped user-requested repair share native admission. Explicit
/// dictation/search do not inherit a permit. Native callbacks read its cancellation flag.
public enum BackgroundProcessingContext {
    @TaskLocal public static var permit: BackgroundProcessingPermit?
    /// A scoped user-requested repair may bypass idle deferral, but still shares the governor's
    /// single native slot and pressure limits. It never enables the global Process Now override.
    @TaskLocal public static var explicitRequest = false

    public static func checkCancellation() throws {
        try Task.checkCancellation()
        if permit?.cancellation.isCancelled == true { throw CancellationError() }
    }

    /// Every exit releases the single automatic slot, including cancellation.
    /// Non-interruptible APIs remain owned until they return; stale results fail.
    public static func run<T: Sendable>(governor: (any BackgroundProcessingProtocol)?,
        kind: BackgroundProcessingKind, operation: @Sendable () async throws -> T) async throws -> T {
        guard let governor else { return try await operation() }
        let permit = try await governor.acquire(kind)
        do {
            let value = try await withTaskCancellationHandler {
                try await $permit.withValue(permit) {
                    try checkCancellation()
                    let value = try await operation()
                    try checkCancellation()
                    return value
                }
            } onCancel: { permit.cancellation.cancel() }
            await governor.release(permit)
            return value
        } catch {
            await governor.release(permit)
            throw error
        }
    }
}
