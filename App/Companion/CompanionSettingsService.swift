import Foundation
import LocalAuthentication
import Security
import Shared

public struct CompanionSettingsState: Sendable {
    public let endpoint: String?
    public let configured: Bool
    public let lastError: String?
}

/// Private companion credentials live in one Keychain item, never preferences or logs.
/// Merely displaying settings does not enable a transport.
public actor CompanionSettingsService {
    struct Stored: Codable, Equatable, Sendable { let endpoint: URL; let token: String }
    struct Credentials: Sendable {
        let read: @Sendable () throws -> Data?
        let write: @Sendable (Data?) throws -> Void
    }
    private let controller: CompanionController
    private let credentials: Credentials
    private var stored: Stored?
    private var loaded = false
    private var terminal = false
    private var lastError: String?
    private var persistenceSuspended = false
    private var transition: Task<Void, Error>?
    private var transitionRevision = UUID()
    private var closeTask: Task<Void, Error>?

    public init(controller: CompanionController, nativeStoreID: UUID) {
        self.controller = controller
        credentials = Self.keychain(account: nativeStoreID.uuidString)
    }
    init(controller: CompanionController, credentials: Credentials) {
        self.controller = controller; self.credentials = credentials
    }
    public func state() -> CompanionSettingsState {
        do { try load() } catch { lastError = "Private companion credentials are unavailable." }
        return .init(endpoint: stored?.endpoint.absoluteString, configured: stored != nil, lastError: lastError)
    }
    /// App initialization only. An absent item durably closes any enrollment left
    /// behind by an interrupted disconnect before new recording can register media.
    public func restore() async throws {
        guard !terminal else { throw CompanionError.closed }
        guard !persistenceSuspended else { throw CompanionError.unavailable }
        try load()
        try await apply(stored, reservation: controller.reserveConfiguration())
    }
    public func configure(endpoint: URL?, bearerToken: String?) async throws {
        try Task.checkCancellation()
        guard !terminal else { throw CompanionError.closed }
        try load()
        let next: Stored?
        if let endpoint {
            try Self.validate(endpoint)
            let supplied = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let token = supplied.isEmpty && stored?.endpoint == endpoint ? stored?.token ?? "" : supplied
            guard (32...256).contains(token.utf8.count), token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
                throw CompanionError.invalidPayload
            }
            next = .init(endpoint: endpoint, token: token)
        } else { next = nil }
        let restartEnrollment = next != nil && stored == nil
        // Revoke transport synchronously before any persistence/actor suspension.
        let reservation = controller.reserveConfiguration()
        transition?.cancel()
        transitionRevision = UUID()
        if restartEnrollment {
            // Persist the disabled boundary before an enabled credential can
            // survive a crash. Restoring that credential may then safely open
            // a new epoch without enrolling disabled-period media.
            try await controller.prepareEnrollmentReset(reservation: reservation)
            try Task.checkCancellation()
            try controller.checkConfigurationReservation(reservation)
        }
        do {
            try credentials.write(try next.map { try JSONEncoder().encode($0) })
            stored = next; loaded = true; lastError = nil; persistenceSuspended = false
        } catch {
            persistenceSuspended = true
            transition?.cancel()
            lastError = "Companion changes could not be saved. Live delivery is suspended; retry before restarting."
            throw error
        }
        try await apply(next, reservation: reservation, restartEnrollment: restartEnrollment)
    }
    /// The coordinator invokes this only after the current capture-policy mutation completes.
    public func resumeAfterPolicyChange() async throws {
        guard !terminal else { throw CompanionError.closed }
        guard !persistenceSuspended else { throw CompanionError.unavailable }
        try load(); try await apply(stored, reservation: controller.reserveConfiguration())
    }
    private func apply(_ value: Stored?, reservation: UUID, restartEnrollment: Bool = false) async throws {
        let revision = UUID()
        transitionRevision = revision
        let old = transition
        old?.cancel()
        let task = Task { [controller] in
            if let old { _ = await old.result }
            try Task.checkCancellation()
            try await controller.configure(value.map { .init(endpoint: $0.endpoint, bearerToken: $0.token) },
                reservation: reservation, restartEnrollment: restartEnrollment)
        }
        transition = task
        do {
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            if transitionRevision == revision { lastError = nil }
        } catch {
            if transitionRevision == revision { lastError = "The private companion is unavailable. Recordings remain local." }
            throw error
        }
    }
    public nonisolated func invalidate() { controller.invalidate() }
    public func close() async throws {
        if let closeTask { return try await closeTask.value }
        terminal = true; controller.invalidate(); transition?.cancel()
        let pending = transition
        let task = Task { [controller] in
            if let pending { _ = await pending.result }
            try await controller.close()
        }
        closeTask = task
        do { try await task.value }
        catch { closeTask = nil; throw error }
    }
    private func load() throws {
        if loaded { return }
        if let data = try credentials.read() {
            guard data.count <= 4096 else { throw CompanionError.invalidPayload }
            let value = try JSONDecoder().decode(Stored.self, from: data)
            try Self.validate(value.endpoint)
            guard (32...256).contains(value.token.utf8.count), value.token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
                throw CompanionError.invalidPayload
            }
            stored = value
        }
        loaded = true
    }
    static func validate(_ endpoint: URL) throws {
        guard let c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let host = c.host?.lowercased(), c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil,
              c.path == "/retrace-companion" || c.path == "/retrace-companion/",
              (c.scheme == "https" && host.hasSuffix(".ts.net") && host.count > 7 && (c.port == nil || c.port == 443)) ||
              (c.scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) && (c.port ?? 80) > 0) else {
            throw CompanionError.invalidPayload
        }
    }
    private static func keychain(account: String) -> Credentials {
        let service = "com.retrace.private-companion.v1"
        return Credentials(read: {
            let authentication = LAContext()
            authentication.interactionNotAllowed = true
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account,
                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: authentication]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = item as? Data else { throw CompanionError.unavailable }
            return data
        }, write: { data in
            let authentication = LAContext()
            authentication.interactionNotAllowed = true
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account,
                kSecUseAuthenticationContext as String: authentication]
            guard let data else {
                let status = SecItemDelete(query as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw CompanionError.unavailable }
                return
            }
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var insert = query
                insert[kSecValueData as String] = data
                insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw CompanionError.unavailable }
            } else if status != errSecSuccess { throw CompanionError.unavailable }
        })
    }
}
