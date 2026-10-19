import Foundation
import AppKit
import ApplicationServices
import Shared

/// Native boundaries only; the monitor owns ordering, generations and callbacks.
struct DisplaySwitchEnvironment: Sendable {
    let activationObservation: @Sendable () async -> DisplayActivationObservation
    let makeAXObservation: @Sendable (@escaping @Sendable () -> Void) async -> (any DisplayAXObserving)?
    let accessibilityPermission: @Sendable () -> Bool

    static let live = Self(activationObservation: {
        await MainActor.run { DisplayActivationObservation(center: NSWorkspace.shared.notificationCenter) }
    }, makeAXObservation: { await NativeDisplayAXObservation.make(onChange: $0) },
        accessibilityPermission: { PermissionMonitor.shared.hasAccessibilityPermission() })
}

/// Bounded reconciliation hints, subscribed before the first lookup/callback.
@MainActor
final class DisplayActivationObservation {
    nonisolated let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    init(center: NotificationCenter) {
        self.center = center
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = pair.stream; continuation = pair.continuation
        token = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                   object: nil, queue: nil) { _ in pair.continuation.yield(()) }
    }

    func close() {
        if let token { center.removeObserver(token); self.token = nil }
        continuation.finish()
    }
}

protocol DisplayAXObserving: AnyObject, Sendable {
    @MainActor func install() async -> Bool
    @MainActor func close()
}

/// Stop revokes the session before suspension. Native registrations retain
/// their callback context until removal of the native source completes.
actor DisplaySwitchMonitor {
    private let displayMonitor: DisplayMonitor
    private let environment: DisplaySwitchEnvironment
    private var currentDisplayID: UInt32?
    private var generation: UUID?
    private var setupGeneration: UUID?
    private var reconciliationRevision: UUID?
    private var notificationTask: Task<Void, Never>?
    private var activationObservation: DisplayActivationObservation?
    private var axObservation: (id: UUID, value: any DisplayAXObserving)?

    nonisolated(unsafe) var onDisplaySwitch: (@Sendable (UInt32, UInt32) async -> Void)?
    nonisolated(unsafe) var onAccessibilityPermissionDenied: (@Sendable () async -> Void)?
    nonisolated(unsafe) var onWindowChange: (@Sendable () async -> Void)?

    init(displayMonitor: DisplayMonitor, environment: DisplaySwitchEnvironment = .live) {
        self.displayMonitor = displayMonitor; self.environment = environment
    }

    func startMonitoring(initialDisplayID: UInt32) {
        guard generation == nil else { return }
        let session = UUID()
        generation = session
        currentDisplayID = initialDisplayID
        notificationTask = Task { await self.observe(session: session) }
    }

    private func observe(session: UUID) async {
        let observation = await environment.activationObservation()
        guard isCurrent(session) else { await observation.close(); return }
        activationObservation = observation
        await setupAXObserver(session: session)
        guard isCurrent(session) else { return }
        await checkForDisplaySwitch(session: session)
        for await _ in observation.events {
            guard isCurrent(session) else { return }
            if let callback = onWindowChange { await callback() }
            guard isCurrent(session) else { return }
            await checkForDisplaySwitch(session: session)
            guard isCurrent(session) else { return }
            await setupAXObserver(session: session)
        }
    }

    func stopMonitoring() async {
        generation = nil
        setupGeneration = nil
        reconciliationRevision = nil
        currentDisplayID = nil
        notificationTask?.cancel()
        notificationTask = nil
        // Detach before awaits: old teardown cannot clear a new owner.
        let activation = activationObservation
        activationObservation = nil
        let ax = axObservation?.value
        axObservation = nil
        await activation?.close()
        await ax?.close()
        // Do not join notificationTask here. Its display callback can be
        // queued behind CaptureManager's lifecycle operation containing Stop.
    }

    private func isCurrent(_ session: UUID) -> Bool {
        generation == session && !Task.isCancelled
    }

    private func setupAXObserver(session: UUID) async {
        guard isCurrent(session) else { return }
        let setup = UUID()
        setupGeneration = setup
        let previous = axObservation?.value
        axObservation = nil
        await previous?.close()
        guard isCurrent(session), setupGeneration == setup else { return }
        guard environment.accessibilityPermission() else {
            if let callback = onAccessibilityPermissionDenied { await callback() }
            return
        }
        let observation = await environment.makeAXObservation { [weak self] in
            Task { await self?.handleWindowChangeFromAX(session: session) }
        }
        guard let observation else { return }
        guard isCurrent(session), setupGeneration == setup else { await observation.close(); return }
        // Publish before native installation. Stop can close this owner while
        // its MainActor hop is pending; close vetoes a later install.
        axObservation = (setup, observation)
        let installed = await observation.install()
        guard installed, isCurrent(session), setupGeneration == setup else {
            await observation.close()
            if axObservation?.id == setup { axObservation = nil }
            return
        }
    }

    private func handleWindowChangeFromAX(session: UUID) async {
        guard isCurrent(session) else { return }
        if !environment.accessibilityPermission() {
            let previous = axObservation?.value
            axObservation = nil
            await previous?.close()
            guard isCurrent(session) else { return }
            if let callback = onAccessibilityPermissionDenied { await callback() }
        }
        guard isCurrent(session) else { return }
        if let callback = onWindowChange { await callback() }
        guard isCurrent(session) else { return }
        await checkForDisplaySwitch(session: session)
    }

    func checkForDisplaySwitch(session expectedSession: UUID? = nil) async {
        guard let session = expectedSession ?? generation else { return }
        guard isCurrent(session) else { return }
        let revision = UUID()
        reconciliationRevision = revision
        let (newDisplayID, hasAXPermission) = await displayMonitor.getActiveDisplayIDWithPermissionStatus()
        guard isCurrent(session), reconciliationRevision == revision else { return }
        if !hasAXPermission, let callback = onAccessibilityPermissionDenied { await callback() }
        // Read the baseline after awaits; old checks cannot resurrect Stop.
        guard isCurrent(session), reconciliationRevision == revision, let current = currentDisplayID else { return }
        if newDisplayID != current {
            currentDisplayID = newDisplayID
            if let callback = onDisplaySwitch { await callback(current, newDisplayID) }
        }
    }

    func getCurrentDisplayID() -> UInt32? { currentDisplayID }
}

private final class DisplayAXCallback: @unchecked Sendable {
    let onChange: @Sendable () -> Void
    init(_ onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
}

private final class NativeDisplayAXObservation: DisplayAXObserving, @unchecked Sendable {
    private let observer: AXObserver
    private let callback: DisplayAXCallback
    @MainActor private var closed = false
    @MainActor private var installed = false

    nonisolated private init(observer: AXObserver, callback: DisplayAXCallback) {
        self.observer = observer; self.callback = callback
    }

    nonisolated static func make(onChange: @escaping @Sendable () -> Void) async -> NativeDisplayAXObservation? {
        guard let pid = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication?.processIdentifier }),
              let observer = PermissionMonitor.shared.safeCreateAXObserver(pid: pid, callback: { _, _, _, pointer in
                  guard let pointer else { return }
                  Unmanaged<DisplayAXCallback>.fromOpaque(pointer).takeUnretainedValue().onChange()
              }) else { return nil }
        let callback = DisplayAXCallback(onChange)
        let observation = NativeDisplayAXObservation(observer: observer, callback: callback)
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.1)
        let pointer = Unmanaged.passUnretained(callback).toOpaque()
        for name in [kAXMovedNotification, kAXFocusedWindowChangedNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, pointer)
        }
        return observation
    }

    @MainActor func install() async -> Bool {
        guard !closed else { return false }
        if !installed {
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            installed = true
        }
        return true
    }

    @MainActor func close() {
        closed = true
        if installed {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            installed = false
        }
        // Callback context remains owned throughout MainActor removal. Tasks
        // already emitted carry a revoked session generation.
    }
}
