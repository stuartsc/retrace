import Foundation
import Shared

/// Owns configuration and one audio session independently of screen recording.
/// The native adapter must stop capture, finish its source, and await the existing
/// bridge/AudioProcessingManager task naturally. It must not cancel that iterator:
/// accepted PCM tails and persisted-batch callbacks belong to the old generation.
public actor AudioSessionOwner {
    public struct Pipeline: Sendable {
        public let start: @Sendable (AudioCaptureConfig) async throws -> Void
        public let stopAndDrain: @Sendable () async throws -> Void
        public let runtime: @Sendable () async -> AudioCaptureRuntime
        public let revokeMarkers: @Sendable () async -> Void
        public let setMicrophoneAllowed: @Sendable (Bool) async -> Void
        public let systemAudioPermitted: @Sendable () async -> Bool
        public init(start: @escaping @Sendable (AudioCaptureConfig) async throws -> Void,
                    stopAndDrain: @escaping @Sendable () async throws -> Void,
                    runtime: @escaping @Sendable () async -> AudioCaptureRuntime,
                    revokeMarkers: @escaping @Sendable () async -> Void,
                    setMicrophoneAllowed: @escaping @Sendable (Bool) async -> Void,
                    systemAudioPermitted: @escaping @Sendable () async -> Bool = { false }) {
            self.start = start; self.stopAndDrain = stopAndDrain; self.runtime = runtime
            self.revokeMarkers = revokeMarkers; self.setMicrophoneAllowed = setMicrophoneAllowed
            self.systemAudioPermitted = systemAudioPermitted
        }
    }
    private let store: any AudioSessionSettingsStoreProtocol
    private let base: AudioCaptureConfig
    private let pipeline: Pipeline
    private var configured: AudioSessionSettings?
    private var phase: AudioSessionPhase = .paused
    private var issue: AudioSessionIssue?
    private var recordingRequested = false
    private var generation = UUID()
    private var sessionOpen = false
    private var appliedRevision: UUID?
    private var terminal = false
    private var tail: Task<Void, Never>?
    private var queued = 0
    private var closeTask: Task<Void, Error>?
    private let closeAdmission = NativeMutationFence()

    public init(store: any AudioSessionSettingsStoreProtocol, baseConfig: AudioCaptureConfig, pipeline: Pipeline) {
        self.store = store; self.base = baseConfig; self.pipeline = pipeline
    }

    public func initialize() async throws {
        try await serialized { owner in try await owner.loadSettings() }
    }

    /// Passive: no device, permission request, model, stream or database initialization.
    public func snapshot() async -> AudioSessionSnapshot {
        let runtime = await pipeline.runtime()
        let current = configured
        let system: AudioSourceRuntime
        if current?.systemAudioEnabled == true, recordingRequested,
           !(await pipeline.systemAudioPermitted()) {
            system = .init(.blockedByPolicy)
        } else { system = runtime.systemAudio }
        return AudioSessionSnapshot(configured: current, recordingRequested: recordingRequested,
            phase: phase, runtime: .init(microphone: runtime.microphone, systemAudio: system), issue: issue)
    }

    /// Master pause wins over an already suspended native startup. Lifecycle work
    /// is uncancelled and joined, so a cancelled caller cannot abandon cleanup.
    public func setRecordingRequested(_ requested: Bool) async throws {
        guard !terminal else { throw AudioSessionError.closed }
        recordingRequested = requested
        generation = UUID()
        try await serialized(lifecycle: true) { owner in
            try await owner.loadSettings()
            guard await owner.reconcile() else { throw AudioSessionError.cleanupFailed }
        }
    }

    /// The settings transaction is the logical commit. After it commits, native
    /// reconciliation is joined even if the caller disconnects. Historical retries
    /// return their immutable receipt and never restore superseded settings.
    public func update(_ command: AudioSessionSettingsCommand,
                       fence: NativeMutationFence? = nil) async throws -> AudioSessionSettingsReceipt {
        let cancellation = NativeMutationFence()
        return try await withTaskCancellationHandler {
          try await serialized { owner in
            try await owner.loadSettings()
            guard !owner.terminal else { throw AudioSessionError.closed }
            let permitted = await owner.pipeline.systemAudioPermitted()
            if command.systemAudioEnabled && !permitted { throw AudioSessionError.systemAudioPolicyUnavailable }
            guard !owner.terminal else { throw AudioSessionError.closed }
            let receipt = try await owner.store.applyAudioSessionSettings(command,
                fences: [cancellation, owner.closeAdmission] + (fence.map { [$0] } ?? []))
            do { owner.configured = try await owner.store.audioSessionSettings() }
            catch {
                // The logical commit stands. If its current state cannot be read,
                // stop native input rather than retaining a possibly disabled mic.
                owner.configured = nil; owner.issue = .settingsUnavailable; owner.phase = .degraded
                await owner.pipeline.revokeMarkers()
                await owner.pipeline.setMicrophoneAllowed(false)
                do { try await owner.pipeline.stopAndDrain(); owner.sessionOpen = false }
                catch { owner.issue = .cleanupFailed }
                return receipt
            }
            // A durable old command cannot restart the current stream.
            if owner.appliedRevision != owner.configured?.revision { _ = await owner.reconcile() }
            return receipt
          }
        } onCancel: { cancellation.invalidate() }
    }

    private func loadSettings() async throws {
        guard !terminal else { throw AudioSessionError.closed }
        guard configured == nil else { return }
        do {
            configured = try await store.initializeAudioSessionSettings(
                microphoneEnabled: base.microphoneEnabled, systemAudioEnabled: base.systemAudioEnabled)
            issue = nil
        } catch {
            issue = .settingsUnavailable; phase = .degraded
            throw error
        }
    }

    private func reconcile() async -> Bool {
        guard !terminal, let configured else { return true }
        if sessionOpen, recordingRequested, appliedRevision == configured.revision { return true }
        let token = generation
        phase = sessionOpen && recordingRequested ? .reconfiguring : (recordingRequested ? .starting : .stopping)
        await pipeline.revokeMarkers()
        await pipeline.setMicrophoneAllowed(false)
        // Always drain, including failed startup: the native API may have opened
        // a source before reporting failure and processing may hold accepted PCM.
        do { try await pipeline.stopAndDrain() }
        catch { issue = .cleanupFailed; phase = .degraded; return false }
        sessionOpen = false; appliedRevision = nil
        guard !terminal, recordingRequested, generation == token else {
            phase = terminal ? .closed : .paused
            return true
        }
        let systemPermitted = await pipeline.systemAudioPermitted()
        guard !terminal, recordingRequested, generation == token else { return true }
        let effective = configured.applying(to: base, systemAudioPermitted: systemPermitted)
        // Both sources disabled still allows the one empty stream/processor to
        // service saved transcription work; capture must start no native device.
        await pipeline.setMicrophoneAllowed(effective.microphoneEnabled)
        guard !terminal, recordingRequested, generation == token else {
            await pipeline.setMicrophoneAllowed(false)
            phase = terminal ? .closed : .paused
            return true
        }
        do {
            try await pipeline.start(effective)
            sessionOpen = true
            guard !terminal, recordingRequested, generation == token else {
                await pipeline.revokeMarkers()
                await pipeline.setMicrophoneAllowed(false)
                try await pipeline.stopAndDrain()
                sessionOpen = false
                phase = terminal ? .closed : .paused
                return true
            }
            appliedRevision = configured.revision
            let runtime = await pipeline.runtime()
            let microphoneFailed = effective.microphoneEnabled && !runtime.microphone.isActive
            let systemFailed = configured.systemAudioEnabled && (!systemPermitted || !runtime.systemAudio.isActive)
            phase = microphoneFailed || systemFailed ? .degraded : .running
            issue = nil
        } catch {
            await pipeline.revokeMarkers()
            await pipeline.setMicrophoneAllowed(false)
            do { try await pipeline.stopAndDrain(); sessionOpen = false; issue = .startupFailed }
            catch { issue = .cleanupFailed }
            phase = terminal ? .closed : .degraded
        }
        return issue != .cleanupFailed
    }

    private func serialized<T: Sendable>(lifecycle: Bool = false,
        _ operation: @escaping @Sendable (isolated AudioSessionOwner) async throws -> T) async throws -> T {
        if !lifecycle { try Task.checkCancellation() }
        guard !terminal else { throw AudioSessionError.closed }
        guard lifecycle || queued < 8 else { throw AudioSessionError.busy }
        queued += 1
        let previous = tail
        let task = Task { await previous?.value; return try await operation(self) }
        tail = Task { _ = await task.result }
        defer { queued -= 1 }
        // Do not propagate cancellation after a durable commit. The caller's
        // command fence remains the revocable admission at the SQLite boundary.
        return try await task.value
    }

    public func close() async throws {
        if let closeTask { try await closeTask.value; return }
        terminal = true; recordingRequested = false; generation = UUID()
        closeAdmission.invalidate()
        let previous = tail
        let task = Task { [pipeline] in
            await pipeline.revokeMarkers()
            await pipeline.setMicrophoneAllowed(false)
            await previous?.value
            do { try await pipeline.stopAndDrain() }
            catch { self.issue = .cleanupFailed; self.phase = .degraded; throw AudioSessionError.cleanupFailed }
            self.sessionOpen = false; self.appliedRevision = nil; self.phase = .closed
        }
        closeTask = task
        do { try await task.value }
        catch { closeTask = nil; throw error }
    }
}
