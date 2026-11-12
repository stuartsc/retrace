import Foundation
import Shared
import Database

/// Explicit UI/MCP repair owner. It never resets native status or inserts automatic work.
/// Pending jobs wait for the existing governor and retained-pixel extraction executor.
public actor ExactOCRRepairService {
    public typealias Progress = @Sendable (ExactOCRRepairPhase) async -> Void
    private struct Key: Hashable { let client: String; let request: UUID }
    private struct Work {
        let reference: ScreenEvidenceRef
        let task: Task<ExactOCRRepairOutcome, Error>
    }
    private let database: DatabaseManager
    private let processing: any ProcessingProtocol
    private let governor: any BackgroundProcessingProtocol
    private let captureState: @Sendable () async throws -> NativeCaptureState
    private let pixels: @Sendable (ExactOCRRepairTarget) async throws -> CapturedFrame
    private let metric: @Sendable (String) async -> Void
    private nonisolated let admission = ExactOCRRepairAdmission()
    private var work: [Key: Work] = [:]
    private var recent: [Key] = []
    private var tail: Task<ExactOCRRepairOutcome, Error>?
    private var pending = 0
    private var closed = false

    public init(database: DatabaseManager, processing: any ProcessingProtocol,
                governor: any BackgroundProcessingProtocol,
                captureState: @escaping @Sendable () async throws -> NativeCaptureState,
                pixels: @escaping @Sendable (ExactOCRRepairTarget) async throws -> CapturedFrame,
                metric: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.database = database; self.processing = processing; self.governor = governor
        self.captureState = captureState; self.pixels = pixels; self.metric = metric
    }

    public nonisolated func invalidate() { admission.invalidate() }

    public func repair(reference: ScreenEvidenceRef, requestID: UUID, clientID: String = "local-ui",
                       commandFence: NativeMutationFence? = nil,
                       progress: @escaping Progress = { _ in }) async throws -> ExactOCRRepairOutcome {
        try Task.checkCancellation()
        guard !closed else { throw ExactOCRRepairError.closed }
        guard !clientID.isEmpty, clientID.utf8.count <= 256, reference.source == .native,
              reference.blockIDs.isEmpty else { throw ExactOCRRepairError.invalidTarget }
        let key = Key(client: clientID, request: requestID)
        if let retained = work[key] {
            guard retained.reference == reference else { throw ExactOCRRepairError.staleTarget }
            return try await withTaskCancellationHandler { try await retained.task.value }
                onCancel: { retained.task.cancel() }
        }
        guard pending < 4 else { throw ExactOCRRepairError.busy }
        let epoch = admission.current(), id = UUID(), cancellation = NativeMutationFence()
        let predecessor = tail
        let task = Task { [database, processing, governor, captureState, pixels, metric] in
            do {
                if let predecessor { _ = await predecessor.result }
                try Task.checkCancellation()
                try epoch.withAdmission {}
                await progress(.waitingForCapacity)
                let state = try await captureState()
                let policy = ScreenEvidenceAccessPolicy(config: state.config)
                let fences = [epoch, cancellation] + (commandFence.map { [$0] } ?? [])
                let target = try await database.exactOCRRepairTarget(reference, policy: policy)
                let extracted = try await BackgroundProcessingContext.$explicitRequest.withValue(true) {
                    try await BackgroundProcessingContext.run(governor: governor, kind: .historicalOCR) {
                        try epoch.withAdmission {}
                        if let commandFence { try commandFence.withAdmission {} }
                        await progress(.readingPixels)
                        let frame = try await pixels(target)
                        guard (1...16_384).contains(frame.width), (1...16_384).contains(frame.height),
                              frame.width * frame.height <= 33_554_432,
                              frame.bytesPerRow >= frame.width * 4,
                              frame.bytesPerRow <= frame.width * 4 + 4096,
                              frame.imageData.count == frame.bytesPerRow * frame.height,
                              frame.timestamp == target.snapshot.frame.timestamp,
                              frame.metadata == target.snapshot.frame.metadata else { throw ExactOCRRepairError.invalidPixels }
                        try BackgroundProcessingContext.checkCancellation()
                        try epoch.withAdmission {}
                        await progress(.recognizing)
                        let text = try await processing.reprocessText(from: frame)
                        return (text, frame.width, frame.height)
                    }
                }
                guard try await captureState().revision == state.revision else { throw ExactOCRRepairError.staleTarget }
                await progress(.committing)
                let result = try await database.commitExactOCRRepair(target, text: extracted.0,
                    width: extracted.1, height: extracted.2, policy: policy, fences: fences)
                // Publication is already committed. Cancellation cannot change that historical fact.
                await metric("completed")
                return result
            } catch {
                await metric(error is CancellationError ? "cancelled" : "failed")
                throw error
            }
        }
        pending += 1; work[key] = .init(reference: reference, task: task); tail = task
        admission.register(id, epoch: epoch, task: task)
        defer {
            admission.remove(id); pending -= 1; recent.append(key)
            while recent.count > 32 { work.removeValue(forKey: recent.removeFirst()) }
            if pending == 0 { tail = nil }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: {
            cancellation.invalidate(); task.cancel()
        }
    }

    public func close() async {
        closed = true; admission.invalidate()
        let tasks = work.values.map(\.task)
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.result }
        work.removeAll(); recent.removeAll(); tail = nil
    }
}

private final class ExactOCRRepairAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch = NativeMutationFence()
    private var tasks: [UUID: Task<ExactOCRRepairOutcome, Error>] = [:]
    func current() -> NativeMutationFence { lock.lock(); defer { lock.unlock() }; return epoch }
    func register(_ id: UUID, epoch expected: NativeMutationFence, task: Task<ExactOCRRepairOutcome, Error>) {
        lock.lock(); let valid = epoch === expected
        if valid { tasks[id] = task }
        lock.unlock()
        if !valid { task.cancel() }
    }
    func remove(_ id: UUID) { lock.lock(); tasks[id] = nil; lock.unlock() }
    func invalidate() {
        lock.lock(); let old = epoch, pending = Array(tasks.values)
        epoch = NativeMutationFence(); tasks.removeAll(); lock.unlock()
        old.invalidate()
        for task in pending { task.cancel() }
    }
}
