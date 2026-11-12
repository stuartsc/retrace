import CryptoKit
import Foundation
import Shared

/// App-only identity for its already selected local database. Contents are not
/// read, paths are not returned, and ordinary writes do not change the identity.
public enum SourceConfigurationSelectionIdentity {
    public static func fingerprint(databasePath: String) -> String? {
        guard !databasePath.isEmpty, !databasePath.contains("\0") else { return nil }
        let expanded = NSString(string: databasePath).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let created = attributes[.creationDate] as? Date else { return nil }
        let value = "\(url.path.utf8.count):\(url.path)|\(device)|\(inode)|\(created.timeIntervalSinceReferenceDate.bitPattern)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Internal observation supplied by the App-owned source adapter. The fingerprint
/// binds the selected local library and must change on replacement or relocation.
/// It is never accepted from, or disclosed to, an MCP client.
public struct SourceConfigurationEnvironment: Equatable, Sendable {
    public let configuredEnabled: Bool
    public let effectiveEnabled: Bool
    public let selectionFingerprint: String?
    public init(configuredEnabled: Bool, effectiveEnabled: Bool, selectionFingerprint: String?) {
        self.configuredEnabled = configuredEnabled; self.effectiveEnabled = effectiveEnabled
        self.selectionFingerprint = selectionFingerprint
    }
}

/// Dependencies deliberately expose no caller-controlled path. Connection must
/// recheck the supplied fingerprint and fences at the adapter's final publication
/// boundary. commitPreference is synchronous: it rechecks the same selection and
/// persists only the boolean while all supplied fences remain held. Local folder
/// changes must first invalidate this owner and disconnect through it.
public struct SourceConfigurationBackend: Sendable {
    public let observe: @Sendable () async throws -> SourceConfigurationEnvironment
    public let connect: @Sendable (String, [NativeMutationFence]) async throws -> Void
    public let disconnectAndDrain: @Sendable () async throws -> Void
    public let commitPreference: @Sendable (Bool, String?) throws -> Void

    public init(observe: @escaping @Sendable () async throws -> SourceConfigurationEnvironment,
                connect: @escaping @Sendable (String, [NativeMutationFence]) async throws -> Void,
                disconnectAndDrain: @escaping @Sendable () async throws -> Void,
                commitPreference: @escaping @Sendable (Bool, String?) throws -> Void) {
        self.observe = observe; self.connect = connect; self.disconnectAndDrain = disconnectAndDrain
        self.commitPreference = commitPreference
    }
}

/// Shared UI/MCP owner for existing imported-source access. Different requests
/// fail busy while a transition is in flight; identical retries join that work.
/// The MCP dispatcher owns durable request outcomes across process restarts.
public actor SourceConfigurationService {
    private struct Selection {
        let clientID: String
        let preview: SourceConfigurationPreview
        let environment: SourceConfigurationEnvironment
        let epoch: NativeMutationFence
    }
    private struct RequestKey: Hashable { let clientID: String; let requestID: UUID }
    private struct Completed { let previewID: UUID; let receipt: SourceConfigurationReceipt }
    private struct Running {
        let key: RequestKey; let previewID: UUID
        let task: Task<SourceConfigurationReceipt, Error>
    }
    private let backend: SourceConfigurationBackend
    private let clock: @Sendable () -> Date
    private nonisolated let admission = SourceConfigurationAdmission()
    private var revision = UUID()
    private var observed: SourceConfigurationEnvironment?
    private var issue: SourceConfigurationIssue?
    private var selections: [UUID: Selection] = [:]
    private var completed: [RequestKey: Completed] = [:]
    private var completionOrder: [RequestKey] = []
    private var running: Running?
    private var localChange: Task<SourceConfigurationSnapshot, Error>?
    private var closed = false

    public init(backend: SourceConfigurationBackend, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.backend = backend; self.clock = clock
    }

    /// Revokes selections and in-flight publication immediately, before an actor
    /// hop. This alone does not change the configured preference.
    public nonisolated func invalidate() { admission.invalidate() }

    public func read() async throws -> SourceConfigurationSnapshot {
        guard !closed else { throw SourceConfigurationError.closed }
        let epoch = admission.current()
        let environment = try await backend.observe()
        try epoch.withAdmission {}
        guard !closed else { throw SourceConfigurationError.closed }
        update(environment)
        return snapshot(environment)
    }

    public func preview(clientID: String, expectedRevision: UUID, enabled: Bool) async throws -> SourceConfigurationPreview {
        try validate(clientID)
        guard running == nil, localChange == nil else { throw SourceConfigurationError.busy }
        let epoch = admission.current()
        let state = try await read()
        guard running == nil, localChange == nil, state.revision == expectedRevision, let environment = observed else {
            throw SourceConfigurationError.stalePreview
        }
        try epoch.withAdmission {}
        if enabled, environment.selectionFingerprint == nil { throw SourceConfigurationError.selectionUnavailable }
        selections = selections.filter { $0.value.preview.expiresAt > clock() }
        guard selections.count < 128 else { throw SourceConfigurationError.busy }
        let preview = SourceConfigurationPreview(id: UUID(), expectedRevision: revision,
            enabled: enabled, expiresAt: clock().addingTimeInterval(120))
        selections[preview.id] = Selection(clientID: clientID, preview: preview, environment: environment, epoch: epoch)
        return preview
    }

    public func apply(clientID: String, requestID: UUID, previewID: UUID,
                      commandFence: NativeMutationFence? = nil) async throws -> SourceConfigurationReceipt {
        try validate(clientID)
        guard !closed else { throw SourceConfigurationError.closed }
        guard localChange == nil else { throw SourceConfigurationError.busy }
        try Task.checkCancellation()
        try commandFence?.withAdmission {}
        let key = RequestKey(clientID: clientID, requestID: requestID)
        if let prior = completed[key] {
            guard prior.previewID == previewID else { throw SourceConfigurationError.invalidRequest }
            return prior.receipt
        }
        if let running {
            guard running.key == key, running.previewID == previewID else { throw SourceConfigurationError.busy }
            return try await running.task.value
        }
        guard let selection = selections[previewID], selection.clientID == clientID,
              selection.preview.expiresAt > clock(), selection.preview.expectedRevision == revision else {
            throw SourceConfigurationError.stalePreview
        }
        let task = Task { try await self.perform(key: key, selection: selection, commandFence: commandFence) }
        running = Running(key: key, previewID: previewID, task: task)
        defer { running = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Revalidates the exact preview previously issued to this client. MCP uses
    /// this during confirmation instead of issuing a different preview identity.
    public func validatePreview(clientID: String, previewID: UUID) async throws {
        guard !closed else { throw SourceConfigurationError.closed }
        guard running == nil, localChange == nil else { throw SourceConfigurationError.busy }
        guard let selection = selections[previewID], selection.clientID == clientID,
              selection.preview.expiresAt > clock() else { throw SourceConfigurationError.stalePreview }
        let state = try await read()
        guard running == nil, localChange == nil, state.revision == selection.preview.expectedRevision,
              observed == selection.environment, selection.preview.expiresAt > clock() else {
            throw SourceConfigurationError.stalePreview
        }
        do { try selection.epoch.withAdmission {} }
        catch { throw SourceConfigurationError.stalePreview }
    }

    public func close() async {
        closed = true; admission.invalidate()
        let pending = running?.task
        let location = localChange
        pending?.cancel()
        location?.cancel()
        _ = await pending?.result
        _ = await location?.result
        selections.removeAll(); completed.removeAll(); completionOrder.removeAll()
    }

    /// Local folder-picker boundary, deliberately absent from MCP. Old requests
    /// are revoked and joined before disconnect; the location is persisted only
    /// after that drain. Reconnect failure preserves the saved enabled preference
    /// and exposes the actual disconnected state for a later explicit retry.
    public func changeLocalSelection(_ writeSelection: @escaping @Sendable () throws -> Void) async throws -> SourceConfigurationSnapshot {
        guard !closed else { throw SourceConfigurationError.closed }
        guard localChange == nil else { throw SourceConfigurationError.busy }
        try Task.checkCancellation()
        admission.invalidate()
        let pending = running?.task
        pending?.cancel()
        let task = Task {
            _ = await pending?.result
            return try await self.performLocalSelection(writeSelection)
        }
        localChange = task
        defer { localChange = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func performLocalSelection(_ writeSelection: @Sendable () throws -> Void) async throws -> SourceConfigurationSnapshot {
        guard !closed else { throw SourceConfigurationError.closed }
        let epoch = admission.current()
        try epoch.withAdmission {}
        do { try await backend.disconnectAndDrain() }
        catch { issue = .cleanupFailed; throw SourceConfigurationError.cleanupFailed }
        do {
            try epoch.withAdmission { try writeSelection() }
            let selected = try await backend.observe()
            try epoch.withAdmission {}
            if selected.configuredEnabled {
                guard let fingerprint = selected.selectionFingerprint else { throw SourceConfigurationError.selectionUnavailable }
                try await backend.connect(fingerprint, [epoch])
            }
            let final = try await backend.observe()
            try epoch.withAdmission {}
            guard !closed, final.effectiveEnabled == final.configuredEnabled else { throw SourceConfigurationError.connectionFailed }
            update(final); issue = nil
            return snapshot(final, transitioning: false)
        } catch {
            do { try await backend.disconnectAndDrain() }
            catch { issue = .cleanupFailed; revision = UUID(); throw SourceConfigurationError.cleanupFailed }
            issue = issueFor(error); revision = UUID(); selections.removeAll()
            throw error
        }
    }

    private func perform(key: RequestKey, selection: Selection,
                         commandFence: NativeMutationFence?) async throws -> SourceConfigurationReceipt {
        let expiry = NativeMutationFence(expiresAt: selection.preview.expiresAt, clock: clock)
        let fences = [selection.epoch, expiry] + (commandFence.map { [$0] } ?? [])
        try admitted(fences) {}
        let before = try await backend.observe()
        guard before == selection.environment, revision == selection.preview.expectedRevision else {
            update(before); throw SourceConfigurationError.stalePreview
        }
        try admitted(fences) {}
        let enabled = selection.preview.enabled
        var changedRuntime = false
        do {
            if enabled {
                guard let fingerprint = before.selectionFingerprint else { throw SourceConfigurationError.selectionUnavailable }
                if !before.effectiveEnabled {
                    // Mark before suspension: a native connector can fail after
                    // acquiring its handle; failure must still revoke the source.
                    changedRuntime = true
                    do { try await backend.connect(fingerprint, fences) }
                    catch is CancellationError { throw CancellationError() }
                    catch let error as SourceConfigurationError { throw error }
                    catch { throw SourceConfigurationError.connectionFailed }
                }
            } else {
                changedRuntime = true
                do { try await backend.disconnectAndDrain() }
                catch { throw SourceConfigurationError.cleanupFailed }
            }
            let ready = try await backend.observe()
            guard ready.selectionFingerprint == before.selectionFingerprint,
                  ready.effectiveEnabled == enabled,
                  ready.configuredEnabled == before.configuredEnabled else {
                throw SourceConfigurationError.stalePreview
            }
            // Logical commit. Cancellation/revocation before here rejects the
            // write. Once this returns, do not roll back an accepted preference.
            try admitted(fences) {
                do { try backend.commitPreference(enabled, before.selectionFingerprint) }
                catch let error as SourceConfigurationError { throw error }
                catch { throw SourceConfigurationError.persistenceFailed }
            }
        } catch {
            if enabled && changedRuntime {
                do { try await backend.disconnectAndDrain() }
                catch { issue = .cleanupFailed; revision = UUID(); throw SourceConfigurationError.cleanupFailed }
            }
            issue = error is CancellationError ? nil : issueFor(error)
            revision = UUID(); selections.removeAll()
            throw error
        }
        // No await or cancellation check after the logical commit. A cancelled
        // response cannot turn success into an apparent rollback/retry.
        let final = SourceConfigurationEnvironment(configuredEnabled: enabled, effectiveEnabled: enabled,
            selectionFingerprint: before.selectionFingerprint)
        update(final); issue = nil
        let receipt = SourceConfigurationReceipt(requestID: key.requestID,
            changed: before.configuredEnabled != enabled || before.effectiveEnabled != enabled,
            state: snapshot(final, transitioning: false))
        completed[key] = Completed(previewID: selection.preview.id, receipt: receipt)
        completionOrder.append(key)
        if completionOrder.count > 128 { completed.removeValue(forKey: completionOrder.removeFirst()) }
        selections.removeAll()
        return receipt
    }

    private func update(_ environment: SourceConfigurationEnvironment) {
        if observed != environment { revision = UUID(); observed = environment; selections.removeAll() }
    }
    private func snapshot(_ environment: SourceConfigurationEnvironment, transitioning: Bool? = nil) -> SourceConfigurationSnapshot {
        .init(revision: revision, configuredEnabled: environment.configuredEnabled,
              effectiveEnabled: environment.effectiveEnabled, hasLocalSelection: environment.selectionFingerprint != nil,
              transitioning: transitioning ?? (running != nil || localChange != nil), issue: issue, observedAt: clock())
    }
    private func validate(_ clientID: String) throws {
        guard !clientID.isEmpty, clientID.utf8.count <= 256, !clientID.contains("\0") else {
            throw SourceConfigurationError.invalidRequest
        }
    }
    private func issueFor(_ error: Error) -> SourceConfigurationIssue? {
        switch error as? SourceConfigurationError {
        case .selectionUnavailable: return .selectionUnavailable
        case .persistenceFailed: return .persistenceFailed
        case .cleanupFailed: return .cleanupFailed
        case .connectionFailed: return .connectionFailed
        default: return nil
        }
    }
    private func admitted<T>(_ fences: [NativeMutationFence], _ operation: () throws -> T) throws -> T {
        func next(_ index: Int) throws -> T {
            if index == fences.count { return try operation() }
            return try fences[index].withAdmission { try next(index + 1) }
        }
        return try next(0)
    }
}

private final class SourceConfigurationAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch = NativeMutationFence()
    func current() -> NativeMutationFence { lock.lock(); defer { lock.unlock() }; return epoch }
    func invalidate() {
        lock.lock(); let previous = epoch; epoch = NativeMutationFence(); lock.unlock()
        previous.invalidate()
    }
}
