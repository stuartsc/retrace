import Foundation
import Database
import Shared

/// Shared native annotation owner. Reads never activate capture, transport or a
/// model. Policy changes synchronously revoke both pending reads and mutations.
public actor NativeAnnotationService {
    private let database: DatabaseManager
    private let captureState: @Sendable () async throws -> NativeCaptureState
    private let drainOutput: @Sendable () async -> Void
    private nonisolated let admission = AnnotationAdmission()
    private var work: [UUID: Task<Void, Never>] = [:]
    private var closed = false

    public init(database: DatabaseManager, captureState: @escaping @Sendable () async throws -> NativeCaptureState,
                drainOutput: @escaping @Sendable () async -> Void = {}) {
        self.database = database; self.captureState = captureState; self.drainOutput = drainOutput
    }
    public nonisolated func invalidate() { admission.invalidate() }

    public func read(references: [ScreenEvidenceRef]) async throws -> NativeAnnotationSnapshot {
        let epoch = admission.current()
        return try await owned { [database, captureState] in
            try epoch.withAdmission {}
            let state = try await captureState()
            let result = try await database.nativeAnnotations(references: references, policy: .init(config: state.config))
            guard try await captureState().revision == state.revision else { throw NativeAnnotationError.staleSelection }
            try epoch.withAdmission {}
            return result
        }
    }

    /// Local UI compatibility adapter. Exact references are resolved on the native
    /// writer, then run through the same bounded source/policy checks as MCP.
    public func readSegments(_ ids: [SegmentID], anchor: FrameID? = nil) async throws -> NativeAnnotationSnapshot {
        let epoch = admission.current()
        return try await owned { [database, captureState] in
            try epoch.withAdmission {}
            let state = try await captureState(), policy = ScreenEvidenceAccessPolicy(config: state.config)
            let references = try await database.nativeAnnotationReferences(segmentIDs: ids, anchor: anchor, policy: policy)
            let result = try await database.nativeAnnotations(references: references, policy: policy)
            guard try await captureState().revision == state.revision else { throw NativeAnnotationError.staleSelection }
            try epoch.withAdmission {}
            return result
        }
    }

    public func validate(_ expected: NativeAnnotationSnapshot) async throws {
        guard try await read(references: expected.segments.map(\.reference)) == expected else { throw NativeAnnotationError.staleSelection }
    }

    public func preview(snapshot: NativeAnnotationSnapshot, mutation: NativeAnnotationMutation) async throws -> Int {
        let epoch = admission.current()
        return try await owned { [database, captureState] in
            try epoch.withAdmission {}
            let state = try await captureState()
            let count = try await database.nativeAnnotationImpact(expected: snapshot, mutation: mutation, policy: .init(config: state.config))
            guard try await captureState().revision == state.revision else { throw NativeAnnotationError.staleSelection }
            try epoch.withAdmission {}
            return count
        }
    }

    public func apply(snapshot: NativeAnnotationSnapshot, mutation: NativeAnnotationMutation,
                      commandFence: NativeMutationFence? = nil,
                      selectionFence: NativeMutationFence? = nil) async throws -> NativeAnnotationReceipt {
        let epoch = admission.current()
        return try await owned { [database, captureState, drainOutput] in
            try epoch.withAdmission {}
            let state = try await captureState()
            let receipt = try await database.mutateNativeAnnotations(expected: snapshot, mutation: mutation,
                policy: .init(config: state.config), fences: [epoch] + (commandFence.map { [$0] } ?? []) + (selectionFence.map { [$0] } ?? []))
            await drainOutput()
            return receipt
        }
    }

    private func owned<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard !closed else { throw NativeAnnotationError.closed }
        guard work.count < 8 else { throw NativeAnnotationError.unavailable }
        let id = UUID(), task = Task { try await operation() }
        work[id] = Task { _ = await task.result }
        defer { work[id] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func close() async {
        closed = true; admission.invalidate()
        let pending = Array(work.values)
        for task in pending { await task.value }
        work.removeAll()
    }
}

private final class AnnotationAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch = NativeMutationFence()
    func current() -> NativeMutationFence { lock.lock(); defer { lock.unlock() }; return epoch }
    func invalidate() {
        lock.lock(); let previous = epoch; epoch = NativeMutationFence(); lock.unlock()
        previous.invalidate()
    }
}
