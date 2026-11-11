import AppKit
import ApplicationServices
import Foundation

/// Capture owns this observation independently of the optional activity writer.
/// Native callbacks synchronously invalidate attribution before waking one
/// bounded consumer. Tokens fence stale observer installation and teardown.
final class CaptureNotificationFence: @unchecked Sendable {
    private let lock = NSLock()
    private let registry: ObservedWindowGenerations
    private var token: UUID?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var needsObserverRefresh = false
    private var onChange: (@Sendable () -> Void)?

    init(registry: ObservedWindowGenerations = .shared) { self.registry = registry }

    @discardableResult
    func start(workspaceCenter: NotificationCenter, displayCenter: NotificationCenter,
               onChange: @escaping @Sendable () -> Void = {}) -> UUID {
        stop()
        let token = UUID()
        lock.withLock {
            self.token = token
            self.onChange = onChange
            needsObserverRefresh = false
            registry.beginCaptureObservation(token: token)
        }
        let names = [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification]
        var registrations: [(NotificationCenter, NSObjectProtocol)] = names.map { name in
            (workspaceCenter, workspaceCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.noteChange(token: token, resettingWindows: true)
            })
        }
        registrations.append((displayCenter, displayCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.noteChange(token: token, resettingWindows: true) }))
        let installed = lock.withLock { () -> Bool in
            guard self.token == token else { return false }
            observers = registrations
            return true
        }
        if !installed { for (center, observer) in registrations { center.removeObserver(observer) } }
        return token
    }

    func stop() {
        let old = lock.withLock { () -> [(NotificationCenter, NSObjectProtocol)] in
            if let token { registry.endCaptureObservation(token: token) }
            token = nil; onChange = nil; needsObserverRefresh = false
            let old = observers
            observers.removeAll()
            return old
        }
        for (center, observer) in old { center.removeObserver(observer) }
    }

    func isActive(_ token: UUID) -> Bool { lock.withLock { self.token == token } }

    @discardableResult
    func noteWindowNotification(_ name: String, token: UUID) -> Bool {
        noteChange(token: token, resettingWindows: name != kAXTitleChangedNotification && name != kAXMovedNotification)
    }

    @discardableResult
    private func noteChange(token: UUID, resettingWindows: Bool) -> Bool {
        let receipt = lock.withLock { () -> (Bool, (@Sendable () -> Void)?) in
            guard self.token == token else { return (false, nil) }
            registry.noteNotification(resettingWindows: resettingWindows)
            if resettingWindows {
                registry.suspendCaptureObservation(token: token)
                needsObserverRefresh = true
            }
            return (true, onChange)
        }
        receipt.1?()
        return receipt.0
    }

    func takeObserverRefresh(token: UUID) -> Bool {
        lock.withLock {
            guard self.token == token else { return false }
            let refresh = needsObserverRefresh
            needsObserverRefresh = false
            return refresh
        }
    }

    func suspendObservedProcess(token: UUID) {
        lock.withLock {
            guard self.token == token else { return }
            registry.suspendCaptureObservation(token: token)
        }
    }

    func confirmObservedProcess(_ processID: Int32, token: UUID, revision: UInt64) -> Bool {
        lock.withLock {
            guard self.token == token else { return false }
            return registry.confirmCaptureObservation(token: token, processID: processID, revision: revision)
        }
    }

    deinit { stop() }
}
