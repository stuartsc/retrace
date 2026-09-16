import Foundation
import Shared
import Database

/// App's owning configuration bridge. Capture supplies serialization; the native
/// store is authoritative for durable policy and its live writer capability.
actor ScreenEvidenceAdmissionCoordinator: CaptureConfigurationAdmissionProtocol {
    typealias MetricSink = @Sendable (ProgressiveRecallAction, String) async -> Void

    private let store: any ScreenEvidenceAdmissionStoreProtocol
    private let metric: MetricSink
    private var session: ScreenEvidenceWriterSession?

    init(store: any ScreenEvidenceAdmissionStoreProtocol,
         metric: @escaping MetricSink = { _, _ in }) {
        self.store = store; self.metric = metric
    }

    init(database: DatabaseManager) {
        self.store = database
        self.metric = { action, outcome in
            let metadata: [String: Any] = ["action": action.rawValue, "outcome": outcome, "count": 1]
            if let bytes = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
               let json = String(data: bytes, encoding: .utf8) {
                try? await database.recordMetricEvent(metricType: .progressiveRecallAction, metadata: json)
            }
        }
    }

    func beginSession(config: CaptureConfig) async throws -> ScreenEvidencePolicyTransition {
        try await measured(.evidencePolicySessionBegan) {
            let transition = try await store.beginScreenEvidenceWriterSession(policy: .init(config: config))
            session = transition.session
            return transition
        }
    }

    func prepareConfiguration(_ config: CaptureConfig) async throws -> ScreenEvidencePolicyTransition {
        try await measured(.evidencePolicyPrepared) {
            guard let session else { throw ScreenEvidenceAdmissionError.inactive }
            return try await store.prepareScreenEvidencePolicy(session: session, policy: .init(config: config))
        }
    }

    func activate(_ transition: ScreenEvidencePolicyTransition) async throws {
        try await measured(.evidencePolicyActivated) {
            guard session == transition.session else { throw ScreenEvidenceAdmissionError.staleSession }
            try await store.activateScreenEvidencePolicy(transition)
        }
    }

    func revoke(_ transition: ScreenEvidencePolicyTransition) async throws {
        try await measured(.evidencePolicyRevoked) {
            // Forward the exact token even after a newer session was installed.
            // The writer makes stale cleanup harmless without revoking its owner.
            try await store.revokeScreenEvidencePolicy(transition)
        }
    }

    func endSession() async throws {
        guard let owningSession = session else { return }
        try await measured(.evidencePolicySessionEnded) {
            try await store.endScreenEvidenceWriterSession(owningSession)
            // Keep a failed cleanup retryable and never clear a newer owner.
            if session == owningSession { session = nil }
        }
    }

    private func measured<Result: Sendable>(
        _ action: ProgressiveRecallAction, operation: () async throws -> Result
    ) async throws -> Result {
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            Log.recordLatency("recall.\(action.rawValue)",
                valueMs: (ProcessInfo.processInfo.systemUptime - started) * 1_000, category: .app)
        }
        do {
            let result = try await operation()
            await metric(action, "success")
            return result
        } catch {
            await metric(action, error is CancellationError ? "cancelled" : "failed")
            throw error
        }
    }
}
