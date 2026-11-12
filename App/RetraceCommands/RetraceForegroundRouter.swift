import Foundation
import Shared

/// Revalidate after asynchronous preparation, then hold the command authority only for
/// the synchronous native UI or playback effect. No lock is held across an await.
public struct RetraceForegroundAuthorization: Sendable {
    public let fence: NativeMutationFence
    private let validation: @Sendable () async throws -> Void
    public init(fence: NativeMutationFence, validation: @escaping @Sendable () async throws -> Void) {
        self.fence = fence; self.validation = validation
    }
    public func validate() async throws {
        try await validation()
        try fence.withAdmission {}
    }
    public func effect<T>(_ body: () throws -> T) throws -> T { try fence.withAdmission(body) }
}

/// The real UI lifecycle installs these callbacks. No registration means unavailable, and
/// replacing/removing a registration cancels and joins its admitted foreground work.
public actor RetraceForegroundRouter {
    public static let shared = RetraceForegroundRouter()
    public typealias Open = @MainActor @Sendable (RetraceNavigationTarget, RetraceForegroundAuthorization) async throws -> Void
    public typealias Playback = @MainActor @Sendable (RetracePlaybackRequest, RetraceForegroundAuthorization) async throws -> Void
    private var registration: (id: UUID, open: Open, playback: Playback)?
    private var registrationEpoch = UUID()
    private var work: [UUID: (task: Task<Void, Error>, fence: NativeMutationFence)] = [:]

    public init() {}

    public func register(open: @escaping Open, playback: @escaping Playback) async -> UUID {
        let id = UUID()
        registrationEpoch = id
        registration = nil
        let admitted = Array(work.values)
        for item in admitted { item.fence.invalidate(); item.task.cancel() }
        for item in admitted { _ = try? await item.task.value }
        guard registrationEpoch == id, !Task.isCancelled else { return id }
        registration = (id, open, playback)
        return id
    }

    public func unregister(_ id: UUID) async {
        guard registration?.id == id else { return }
        registrationEpoch = UUID()
        registration = nil
        let admitted = Array(work.values)
        for item in admitted { item.fence.invalidate(); item.task.cancel() }
        for item in admitted { _ = try? await item.task.value }
    }

    public func open(_ target: RetraceNavigationTarget, commandFence: NativeMutationFence = NativeMutationFence(), authorization: @escaping @Sendable () async throws -> Void) async throws {
        guard let registration else { throw RetraceCommandError.unavailable }
        let access = RetraceForegroundAuthorization(fence: commandFence, validation: authorization)
        try await perform(registrationID: registration.id, access: access) { try await registration.open(target, access) }
    }

    public func playback(_ request: RetracePlaybackRequest, commandFence: NativeMutationFence = NativeMutationFence(), authorization: @escaping @Sendable () async throws -> Void) async throws {
        guard let registration else { throw RetraceCommandError.unavailable }
        let access = RetraceForegroundAuthorization(fence: commandFence, validation: authorization)
        try await perform(registrationID: registration.id, access: access) { try await registration.playback(request, access) }
    }

    private func perform(registrationID: UUID, access: RetraceForegroundAuthorization,
                         effect: @escaping @Sendable () async throws -> Void) async throws {
        guard work.count < 4 else { throw RetraceCommandError.unavailable }
        let id = UUID()
        let task = Task {
            try await access.validate()
            try Task.checkCancellation()
            try await effect()
        }
        work[id] = (task, access.fence)
        defer { work[id] = nil }
        try await withTaskCancellationHandler { try await task.value } onCancel: { access.fence.invalidate(); task.cancel() }
        guard registration?.id == registrationID else { throw RetraceCommandError.unavailable }
        try Task.checkCancellation()
    }
}
