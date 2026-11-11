import Foundation
import AppKit
import ApplicationServices
import Shared

/// Owns workspace and focused-window observation while capture is active. The
/// synchronous fence invalidates pixel attribution before the bounded async
/// consumer can be delayed by a display switch or an immediate capture.
actor DisplaySwitchMonitor {
    private let displayMonitor: DisplayMonitor
    private let fence = CaptureNotificationFence()
    private var generation: UUID?
    private var currentDisplayID: UInt32?
    private var notificationTask: Task<Void, Never>?
    private var signal: AsyncStream<Void>.Continuation?
    private var registration: CaptureAXRegistration?

    nonisolated(unsafe) var onDisplaySwitch: (@Sendable (UInt32, UInt32) async -> Void)?
    nonisolated(unsafe) var onAccessibilityPermissionDenied: (@Sendable () async -> Void)?
    nonisolated(unsafe) var onWindowChange: (@Sendable () async -> Void)?

    init(displayMonitor: DisplayMonitor) { self.displayMonitor = displayMonitor }

    /// Returns only after native notification fencing is installed. Unsupported
    /// AX windows remain unattributed in the candidate's display-only captures.
    func startMonitoring(initialDisplayID: UInt32) async {
        await stopMonitoring()
        let lifecycle = UUID()
        generation = lifecycle
        currentDisplayID = initialDisplayID
        let center = await MainActor.run { NSWorkspace.shared.notificationCenter }
        guard generation == lifecycle, !Task.isCancelled else { return }
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signal = pair.continuation
        let token = fence.start(workspaceCenter: center, displayCenter: .default) {
            pair.continuation.yield(())
        }
        await setupAXObserver(lifecycle: lifecycle, token: token)
        guard generation == lifecycle, !Task.isCancelled else { return }
        notificationTask = Task { [weak self] in
            for await _ in pair.stream {
                guard !Task.isCancelled else { return }
                await self?.handleChange(lifecycle: lifecycle, token: token)
            }
        }
    }

    func stopMonitoring() async {
        generation = nil
        fence.stop()
        signal?.finish(); signal = nil
        notificationTask?.cancel(); notificationTask = nil
        currentDisplayID = nil
        // Do not join a callback which may itself be queued behind the manager's
        // stop operation. The fence closes admission synchronously, and every
        // suspended observer operation checks its generation before resuming.
        await removeCurrentAXObserver()
    }

    private func isCurrent(_ lifecycle: UUID, token: UUID) -> Bool {
        generation == lifecycle && fence.isActive(token) && !Task.isCancelled
    }

    private func setupAXObserver(lifecycle: UUID, token: UUID) async {
        guard isCurrent(lifecycle, token: token) else { return }
        fence.suspendObservedProcess(token: token)
        await removeCurrentAXObserver()
        guard isCurrent(lifecycle, token: token) else { return }
        guard PermissionMonitor.shared.hasAccessibilityPermission() else {
            await onAccessibilityPermissionDenied?()
            return
        }
        let revision = ObservedWindowGenerations.shared.notificationRevision
        let pid = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard isCurrent(lifecycle, token: token), let pid,
              let candidate = CaptureAXRegistration.make(pid: pid, fence: fence, token: token) else { return }
        let installed = await MainActor.run {
            guard candidate.reference.fence.isActive(token) else { return false }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(candidate.observer), .commonModes)
            return true
        }
        guard installed, isCurrent(lifecycle, token: token) else {
            if installed { await Self.remove(candidate) }
            return
        }
        registration = candidate
        if candidate.hasWindowNotifications {
            _ = fence.confirmObservedProcess(pid, token: token, revision: revision)
        }
    }

    private func removeCurrentAXObserver() async {
        let old = registration
        registration = nil
        if let old { await Self.remove(old) }
    }

    private static func remove(_ registration: CaptureAXRegistration) async {
        await MainActor.run {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(registration.observer), .commonModes)
            // Keep the native refcon alive until removal finishes on its run loop.
            withExtendedLifetime(registration.reference) {}
        }
    }

    private func handleChange(lifecycle: UUID, token: UUID) async {
        guard isCurrent(lifecycle, token: token) else { return }
        if fence.takeObserverRefresh(token: token) || registration == nil {
            await setupAXObserver(lifecycle: lifecycle, token: token)
        }
        guard isCurrent(lifecycle, token: token) else { return }
        guard PermissionMonitor.shared.hasAccessibilityPermission() else {
            fence.suspendObservedProcess(token: token)
            await removeCurrentAXObserver()
            guard isCurrent(lifecycle, token: token) else { return }
            await onAccessibilityPermissionDenied?()
            return
        }
        await checkForDisplaySwitch(lifecycle: lifecycle, token: token)
        guard isCurrent(lifecycle, token: token) else { return }
        await onWindowChange?()
    }

    private func checkForDisplaySwitch(lifecycle: UUID, token: UUID) async {
        guard let currentDisplay = currentDisplayID else { return }
        let (newDisplayID, hasAXPermission) = await displayMonitor.getActiveDisplayIDWithPermissionStatus()
        guard isCurrent(lifecycle, token: token) else { return }
        guard hasAXPermission else {
            fence.suspendObservedProcess(token: token)
            await onAccessibilityPermissionDenied?()
            return
        }
        if newDisplayID != currentDisplay {
            currentDisplayID = newDisplayID
            await onDisplaySwitch?(currentDisplay, newDisplayID)
        }
    }

    func getCurrentDisplayID() -> UInt32? { currentDisplayID }
}

private final class CaptureAXReference: @unchecked Sendable {
    let fence: CaptureNotificationFence
    let token: UUID
    init(fence: CaptureNotificationFence, token: UUID) { self.fence = fence; self.token = token }
}

private struct CaptureAXRegistration: @unchecked Sendable {
    let observer: AXObserver
    let reference: CaptureAXReference
    let hasWindowNotifications: Bool

    static func make(pid: Int32, fence: CaptureNotificationFence, token: UUID) -> Self? {
        let reference = CaptureAXReference(fence: fence, token: token)
        guard let observer = PermissionMonitor.shared.safeCreateAXObserver(pid: pid, callback: { _, _, name, pointer in
            guard let pointer else { return }
            let reference = Unmanaged<CaptureAXReference>.fromOpaque(pointer).takeUnretainedValue()
            reference.fence.noteWindowNotification(name as String, token: reference.token)
        }) else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        let pointer = Unmanaged.passUnretained(reference).toOpaque()
        func subscribed(_ result: AXError) -> Bool { result == .success || result == .notificationAlreadyRegistered }
        guard subscribed(AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, pointer)) else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
        var windowNotifications = false
        if result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            let window = value as! AXUIElement
            AXUIElementSetMessagingTimeout(window, 0.1)
            let results = [kAXTitleChangedNotification, kAXMovedNotification, kAXUIElementDestroyedNotification].map {
                AXObserverAddNotification(observer, window, $0 as CFString, pointer)
            }
            windowNotifications = results.allSatisfy(subscribed)
        }
        return Self(observer: observer, reference: reference, hasWindowNotifications: windowNotifications)
    }
}
