import ApplicationServices
import CoreGraphics
import Foundation
import Shared

struct MeetingControlRead: Sendable {
    let observation: MeetingObservation
    let visitedNodes: Int
}

enum MeetingControlMutationEvent: Equatable, Sendable { case buttonTitleChanged, ancestorValueChanged, other }

/// A deliberately narrow comparison reader. It reads labels of visible,
/// enabled, pressable buttons only; no general app text or screenshot scraping.
/// Unsupported language/provider/visibility remains possible, never active.
enum MeetingCallControlReader {
    private static let counter = MeetingReaderCounter()
    static var activeReaderCount: Int { counter.value }
    fileprivate static func noteReader(_ change: Int) { counter.add(change) }

    static func read(application: MeetingApplicationIdentity, birth: MeetingProcessBirth, config: CaptureConfig,
                     onMutation: (@Sendable (MeetingControlMutationEvent) -> Void)? = nil,
                     between: @escaping @Sendable () async -> Void = {}) async -> MeetingControlRead {
        let start = MeetingReadStart()
        func unavailable(_ reason: MeetingUncertainty) -> MeetingControlRead {
            MeetingControlRead(observation: MeetingObservation(interval: start.interval(), source: .visibleCallControls,
                signal: .unavailable, application: application, uncertainty: reason), visitedNodes: 0)
        }
        guard !Task.isCancelled else { return unavailable(.cancelled) }
        guard !CGWindowListCapture.candidateMustMaskWindow(bundleID: application.bundleID, title: nil, config: config) else {
            return unavailable(.privacyExcluded)
        }
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { return unavailable(.permissionUnavailable) }
        guard let policy = try? ScreenEvidenceAccessPolicy(config: config).fingerprintSHA256() else {
            return unavailable(.policyUnavailable)
        }
        let session = MeetingControlSession(application: application, birth: birth, policy: policy, onMutation: onMutation)
        return await withTaskCancellationHandler {
            let prepared = await session.start()
            if prepared, !Task.isCancelled { await between() }
            if Task.isCancelled { session.cancel() }
            return await session.finish()
        } onCancel: { session.cancel() }
    }
}

private final class MeetingReaderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add(_ change: Int) { lock.withLock { count += change } }
}

private final class MeetingControlSession: @unchecked Sendable {
    private let application: MeetingApplicationIdentity
    private let birth: MeetingProcessBirth
    private let policy: String
    private let onMutation: (@Sendable (MeetingControlMutationEvent) -> Void)?
    private let lock = NSLock()
    private var cancelled = false
    private var requested = false
    private var loop: CFRunLoop?
    private var result: MeetingControlRead?
    private var waiters: [CheckedContinuation<MeetingControlRead, Never>] = []

    init(application: MeetingApplicationIdentity, birth: MeetingProcessBirth, policy: String,
         onMutation: (@Sendable (MeetingControlMutationEvent) -> Void)?) {
        self.application = application; self.birth = birth; self.policy = policy; self.onMutation = onMutation
    }
    func start() async -> Bool {
        await withCheckedContinuation { ready in
            Thread { [self] in
                MeetingCallControlReader.noteReader(1)
                let loop = CFRunLoopGetCurrent()!
                lock.withLock { self.loop = loop }
                let reader = MeetingNativeControlReader(application: application, birth: birth, policy: policy,
                    onMutation: onMutation, cancelled: { self.lock.withLock { self.cancelled } })
                let prepared = reader.prepare()
                ready.resume(returning: prepared)
                if prepared {
                    let deadline = ProcessInfo.processInfo.systemUptime + 2
                    while true {
                        let state = lock.withLock { (cancelled, requested) }
                        if state.0 { reader.fail(.cancelled); break }
                        if state.1 {
                            // Drain queued observer messages before re-reading
                            // identical endpoints; an A→B→A still invalidates.
                            CFRunLoopRunInMode(.defaultMode, 0, true)
                            reader.revalidate(); break
                        }
                        if ProcessInfo.processInfo.systemUptime >= deadline { reader.fail(.budgetExceeded); break }
                        CFRunLoopRunInMode(.defaultMode, 0.010, true)
                    }
                }
                reader.close()
                let final = reader.result()
                MeetingCallControlReader.noteReader(-1)
                let continuations = lock.withLock { () -> [CheckedContinuation<MeetingControlRead, Never>] in
                    result = final; self.loop = nil
                    let stored = waiters; waiters.removeAll(); return stored
                }
                continuations.forEach { $0.resume(returning: final) }
            }.start()
        }
    }
    func cancel() {
        let loop = lock.withLock { cancelled = true; return self.loop }
        if let loop { CFRunLoopWakeUp(loop) }
    }
    func finish() async -> MeetingControlRead {
        await withCheckedContinuation { continuation in
            let state = lock.withLock { () -> (MeetingControlRead?, CFRunLoop?) in
                if let result { return (result, nil) }
                requested = true; waiters.append(continuation); return (nil, loop)
            }
            if let result = state.0 { continuation.resume(returning: result) }
            if let loop = state.1 { CFRunLoopWakeUp(loop) }
        }
    }
}

private final class MeetingControlMutation {
    var changed = false // Confined to the owned native reader/run-loop thread.
    private var buttons: [AXUIElement] = []
    private var containers: [AXUIElement] = []
    let onMutation: (@Sendable (MeetingControlMutationEvent) -> Void)?
    init(onMutation: (@Sendable (MeetingControlMutationEvent) -> Void)?) { self.onMutation = onMutation }
    func noteButton(_ element: AXUIElement) { buttons.append(element) }
    func noteContainer(_ element: AXUIElement) { containers.append(element) }
    func mark(element: AXUIElement, notification: String) {
        changed = true
        // Equality against retained native handles only: no AX/LaunchServices
        // calls in a notification callback and no captured text in test signals.
        if notification == kAXTitleChangedNotification, buttons.contains(where: { CFEqual($0, element) }) {
            onMutation?(.buttonTitleChanged)
        } else if notification == kAXValueChangedNotification, containers.contains(where: { CFEqual($0, element) }) {
            onMutation?(.ancestorValueChanged)
        } else { onMutation?(.other) }
    }
}

private final class MeetingNativeControlReader {
    private struct Failure: Error { let reason: MeetingUncertainty }
    private struct Node {
        let element: AXUIElement
        let role: String
        let subrole: String?
        let hidden: Bool
        let bounds: CGRect
        let ancestors: [Int]
        let children: [AXUIElement]
        let container: Bool
    }
    private struct Button { let index: Int; let label: String; let kind: Kind }
    private enum Kind { case leave, microphone, join }
    private let application: MeetingApplicationIdentity
    private let birth: MeetingProcessBirth
    private let policy: String
    private let cancelled: @Sendable () -> Bool
    private let mutation: MeetingControlMutation
    private let start = MeetingReadStart()
    private let observationID = UUID()
    private var deadline: TimeInterval = 0
    private var workSeconds: TimeInterval = 0
    private var error: MeetingUncertainty?
    private var app: AXUIElement?
    private var window: AXUIElement?
    private var context: ActivityContext?
    private var proof: CaptureTextPixelProof?
    private var observer: AXObserver?
    private var subscriptions: [(AXUIElement, String)] = []
    private var nodes: [Node] = []
    private var buttons: [Button] = []
    private var signal: MeetingSignal?

    init(application: MeetingApplicationIdentity, birth: MeetingProcessBirth, policy: String,
         onMutation: (@Sendable (MeetingControlMutationEvent) -> Void)?, cancelled: @escaping @Sendable () -> Bool) {
        self.application = application; self.birth = birth; self.policy = policy; self.cancelled = cancelled
        mutation = MeetingControlMutation(onMutation: onMutation)
    }

    func prepare() -> Bool {
        let work = ProcessInfo.processInfo.systemUptime
        deadline = work + 0.200
        defer { workSeconds += ProcessInfo.processInfo.systemUptime - work }
        do {
            try check()
            let app = AXUIElementCreateApplication(application.processID)
            self.app = app
            var created: AXObserver?
            let status = AXObserverCreate(application.processID, { _, element, notification, context in
                guard let context else { return }
                Unmanaged<MeetingControlMutation>.fromOpaque(context).takeUnretainedValue()
                    .mark(element: element, notification: notification as String)
            }, &created)
            guard status == .success, let created else { throw Failure(reason: .observerUnavailable) }
            observer = created
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .defaultMode)
            try observe(app, [kAXFocusedWindowChangedNotification])
            let window = try element(kAXFocusedWindowAttribute, of: app)
            self.window = window
            try observe(window, [kAXTitleChangedNotification, kAXMovedNotification, kAXResizedNotification,
                                 kAXLayoutChangedNotification, kAXValueChangedNotification, kAXUIElementDestroyedNotification])
            try proveWindow(window, initial: true)
            try visit(window, ancestors: [])
            // Finish the complete structural/clipping/occlusion inventory before
            // reading any labels. A content budget cannot stand in for proof.
            guard proof?.isCurrent() == true else { throw Failure(reason: .sourceChanged) }
            for index in nodes.indices { try readButton(index) }
            let kinds = buttons.map(\.kind)
            guard kinds.contains(.microphone), kinds.contains(.leave) != kinds.contains(.join) else {
                throw Failure(reason: .controlsUnavailable)
            }
            signal = kinds.contains(.leave) ? .inCallControls : .prejoinControls
            try check()
            guard !mutation.changed else { throw Failure(reason: .sourceChanged) }
            return true
        } catch let failure as Failure { error = failure.reason }
        catch { self.error = .nativeUnavailable }
        return false
    }

    func revalidate() {
        let work = ProcessInfo.processInfo.systemUptime
        deadline = work + max(0, 0.200 - workSeconds)
        do {
            try check()
            guard !mutation.changed, let app, let window,
                  CFEqual(try element(kAXFocusedWindowAttribute, of: app), window) else { throw Failure(reason: .sourceChanged) }
            try proveWindow(window, initial: false)
            for node in nodes {
                try check()
                guard try role(node.element) == node.role, try subrole(node.element) == node.subrole,
                      try hidden(node.element) == node.hidden else { throw Failure(reason: .sourceChanged) }
                if let parent = node.ancestors.last {
                    guard CFEqual(try element(kAXParentAttribute, of: node.element), nodes[parent].element) else {
                        throw Failure(reason: .identityUnproved)
                    }
                }
                if node.hidden { continue }
                guard try rectangle(node.element) == node.bounds else { throw Failure(reason: .visibilityUnverified) }
                let children = try children(node.element, container: node.container)
                guard children.count == node.children.count,
                      zip(children, node.children).allSatisfy({ CFEqual($0, $1) }) else { throw Failure(reason: .sourceChanged) }
            }
            for button in buttons {
                try checkButton(button.index)
                guard try label(nodes[button.index].element).utf16.elementsEqual(button.label.utf16) else {
                    throw Failure(reason: .sourceChanged)
                }
            }
            try check()
            guard !mutation.changed, proof?.isCurrent() == true,
                  ProcessInfo.processInfo.systemUptime - start.uptime <= 2 else { throw Failure(reason: .sourceChanged) }
        } catch let failure as Failure { error = mutation.changed ? .sourceChanged : failure.reason }
        catch { self.error = .nativeUnavailable }
    }

    func fail(_ reason: MeetingUncertainty) { error = reason }
    func result() -> MeetingControlRead {
        let interval = start.interval()
        if error == nil, (interval.endedUptime - interval.startedUptime > 2 || interval.endedAt < interval.startedAt) { error = .budgetExceeded }
        if cancelled() { error = .cancelled }
        let available = error == nil && signal != nil
        return MeetingControlRead(observation: MeetingObservation(interval: interval, source: .visibleCallControls,
            signal: available ? signal! : .unavailable, application: application,
            windowID: available ? context?.windowID : nil, windowObservationID: available ? observationID : nil,
            capturePolicySHA256: available ? policy : nil, uncertainty: available ? nil : (error ?? .controlsUnavailable)),
            visitedNodes: nodes.count)
    }

    func close() {
        guard let observer else { return }
        for (element, notification) in subscriptions { AXObserverRemoveNotification(observer, element, notification as CFString) }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        subscriptions.removeAll(); self.observer = nil
    }

    private func proveWindow(_ window: AXUIElement, initial: Bool) throws {
        guard try role(window) == kAXWindowRole,
              try optional(kAXMinimizedAttribute, of: window) as? Bool != true,
              let title = try optional(kAXTitleAttribute, of: window) as? String,
              title.utf16.count <= 2_048 else { throw Failure(reason: .identityUnproved) }
        let bounds = try rectangle(window)
        if initial {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            var displays = [UInt32](repeating: 0, count: 16); var count: UInt32 = 0
            guard CGGetDisplaysWithPoint(center, 16, &displays, &count) == .success, count > 0, count <= 16,
                  let inventory = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                    as? [[String: Any]], inventory.count <= 4_096 else { throw Failure(reason: .identityUnproved) }
            let matches = inventory.compactMap { item -> UInt32? in
                guard item[kCGWindowOwnerPID as String] as? Int32 == application.processID,
                      item[kCGWindowLayer as String] as? Int == 0,
                      (item[kCGWindowName as String] as? String)?.utf16.elementsEqual(title.utf16) == true,
                      let raw = item[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: raw as CFDictionary),
                      abs(rect.minX - bounds.minX) <= 1, abs(rect.minY - bounds.minY) <= 1,
                      abs(rect.width - bounds.width) <= 1, abs(rect.height - bounds.height) <= 1 else { return nil }
                return item[kCGWindowNumber as String] as? UInt32
            }
            guard matches.count == 1, let id = matches.first,
                  let proof = CaptureTextPixelProof.copy(displayID: displays[0], includedWindowIDs: [id],
                      privacyMaskBounds: [], suppliedWindows: inventory) else { throw Failure(reason: .identityUnproved) }
            context = ActivityContext(appBundleID: application.bundleID, appName: "", processID: application.processID,
                processGeneration: application.processGeneration.uuidString, windowID: id,
                windowGeneration: observationID.uuidString, displayID: displays[0], adapter: "meeting-call-controls-v1")
            self.proof = proof
        }
        guard let context, let proof, proof.uniquelyMatches(context: context, bounds: bounds, title: title),
              initial || proof.isCurrent() else { throw Failure(reason: .identityUnproved) }
    }

    private func visit(_ element: AXUIElement, ancestors: [Int]) throws {
        try check()
        guard nodes.count < 128, ancestors.count <= 10,
              !nodes.contains(where: { CFEqual($0.element, element) }) else { throw Failure(reason: .budgetExceeded) }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == application.processID else { throw Failure(reason: .identityUnproved) }
        if let parent = ancestors.last {
            guard CFEqual(try self.element(kAXParentAttribute, of: element), nodes[parent].element) else { throw Failure(reason: .identityUnproved) }
        }
        let role = try role(element), subrole = try subrole(element), hidden = try hidden(element)
        let safeSubrole = subrole == nil || (role == kAXWindowRole &&
            [kAXStandardWindowSubrole, kAXDialogSubrole, kAXFloatingWindowSubrole].contains(subrole!))
        let container = safeSubrole && [kAXWindowRole, kAXGroupRole, kAXSplitGroupRole,
            kAXScrollAreaRole, kAXSheetRole, kAXTabGroupRole, "AXWebArea"].contains(role)
        let bounds = hidden ? .zero : try rectangle(element)
        let children = hidden ? [] : try children(element, container: container)
        let index = nodes.count
        nodes.append(Node(element: element, role: role, subrole: subrole, hidden: hidden, bounds: bounds,
                          ancestors: ancestors, children: children, container: container))
        if container { mutation.noteContainer(element) }
        // Hidden structural nodes remain observed and revalidated; they can
        // become occluders. Unknown/secure subtrees never have content read.
        var titleProxy = false
        if role == kAXStaticTextRole, let window,
           let proxy = try optional(kAXTitleUIElementAttribute, of: window), CFGetTypeID(proxy) == AXUIElementGetTypeID() {
            titleProxy = CFEqual(proxy, element)
        }
        if !titleProxy {
            try observe(element, [kAXValueChangedNotification, kAXLayoutChangedNotification, kAXUIElementDestroyedNotification])
            if !hidden { try observe(element, [kAXMovedNotification, kAXResizedNotification]) }
        }
        if hidden { return }
        if container { for child in children { try visit(child, ancestors: ancestors + [index]) } }
    }

    private func readButton(_ index: Int) throws {
        let node = nodes[index]
        guard node.role == kAXButtonRole, node.subrole == nil, !node.hidden else { return }
        try checkButton(index)
        try observe(node.element, [kAXTitleChangedNotification])
        let label = try label(node.element)
        let kind: Kind?
        switch label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "leave", "leave call", "leave meeting", "end call", "hang up": kind = .leave
        case "mute microphone", "unmute microphone", "turn microphone on", "turn microphone off": kind = .microphone
        case "join", "join now", "join meeting", "start meeting": kind = .join
        default: kind = nil
        }
        if let kind {
            buttons.append(Button(index: index, label: label, kind: kind))
            mutation.noteButton(node.element)
        }
        // The same node must still be nonsecure and pressable after the label.
        try checkButton(index)
    }

    private func checkButton(_ index: Int) throws {
        let node = nodes[index]
        // Re-prove live security ancestry immediately around each label read.
        // Stored pre-read roles plus a later discard are not permission to read
        // through an ancestor that has since become secure or unknown.
        for ancestorIndex in node.ancestors {
            let ancestor = nodes[ancestorIndex]
            guard ancestor.container, try role(ancestor.element) == ancestor.role,
                  try subrole(ancestor.element) == ancestor.subrole, try hidden(ancestor.element) == false,
                  try rectangle(ancestor.element) == ancestor.bounds else { throw Failure(reason: .visibilityUnverified) }
            if let parent = ancestor.ancestors.last {
                guard CFEqual(try element(kAXParentAttribute, of: ancestor.element), nodes[parent].element) else {
                    throw Failure(reason: .identityUnproved)
                }
            }
        }
        guard !node.ancestors.isEmpty, try role(node.element) == kAXButtonRole,
              try subrole(node.element) == nil, try hidden(node.element) == false,
              try rectangle(node.element) == node.bounds,
              try optional(kAXEnabledAttribute, of: node.element) as? Bool == true,
              node.ancestors.allSatisfy({ nodes[$0].container && !nodes[$0].hidden && nodes[$0].bounds.contains(node.bounds) }),
              let context, let proof else { throw Failure(reason: .visibilityUnverified) }
        guard CFEqual(try element(kAXParentAttribute, of: node.element), nodes[node.ancestors.last!].element) else {
            throw Failure(reason: .identityUnproved)
        }
        guard case .success = proof.pixelBounds(for: node.bounds, context: context) else { throw Failure(reason: .visibilityUnverified) }
        let ancestors = Set(node.ancestors)
        for (other, candidate) in nodes.enumerated() where other != index && !ancestors.contains(other) && !candidate.hidden {
            if candidate.bounds.intersects(node.bounds) { throw Failure(reason: .visibilityUnverified) }
        }
        try configure(node.element)
        var actions: CFArray?
        guard AXUIElementCopyActionNames(node.element, &actions) == .success, let names = actions as? [String],
              names.count <= 16, names.contains(kAXPressAction) else { throw Failure(reason: .controlsUnavailable) }
    }

    private func label(_ element: AXUIElement) throws -> String {
        // Values, help, descendants and text fields are never label fallbacks.
        let raw = try optional(kAXTitleAttribute, of: element) ?? optional(kAXDescriptionAttribute, of: element)
        guard let text = raw as? String, !text.isEmpty, text.utf16.count <= 256 else { throw Failure(reason: .controlsUnavailable) }
        return text
    }

    private func children(_ element: AXUIElement, container: Bool) throws -> [AXUIElement] {
        try configure(element)
        var count: CFIndex = 0
        let status = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
        guard status == .success, count >= 0 else { throw Failure(reason: .visibilityUnverified) }
        guard count <= 128 else { throw Failure(reason: .budgetExceeded) }
        guard container || count == 0 else { throw Failure(reason: .visibilityUnverified) }
        var result: [AXUIElement] = []
        for offset in stride(from: 0, to: count, by: 16) {
            try configure(element)
            var page: CFArray?
            let size = min(16, count - offset)
            guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, offset, size, &page) == .success,
                  let page, CFArrayGetCount(page) == size else { throw Failure(reason: .visibilityUnverified) }
            for index in 0..<size {
                let value = unsafeBitCast(CFArrayGetValueAtIndex(page, index), to: CFTypeRef.self)
                guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw Failure(reason: .identityUnproved) }
                result.append(value as! AXUIElement)
            }
        }
        return result
    }

    private func role(_ element: AXUIElement) throws -> String {
        guard let value = try optional(kAXRoleAttribute, of: element) as? String, value.utf8.count <= 64 else { throw Failure(reason: .identityUnproved) }
        return value
    }
    private func subrole(_ element: AXUIElement) throws -> String? {
        guard let raw = try optional(kAXSubroleAttribute, of: element) else { return nil }
        guard let value = raw as? String, value.utf8.count <= 128 else { throw Failure(reason: .identityUnproved) }
        return value
    }
    private func hidden(_ element: AXUIElement) throws -> Bool {
        guard let value = try optional(kAXHiddenAttribute, of: element) else { return false }
        guard CFGetTypeID(value) == CFBooleanGetTypeID(), let boolean = value as? Bool else { throw Failure(reason: .visibilityUnverified) }
        return boolean
    }
    private func rectangle(_ element: AXUIElement) throws -> CGRect {
        guard let position = try optional(kAXPositionAttribute, of: element), let size = try optional(kAXSizeAttribute, of: element),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            throw Failure(reason: .visibilityUnverified)
        }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetType(position as! AXValue) == .cgPoint, AXValueGetType(size as! AXValue) == .cgSize,
              AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else {
            throw Failure(reason: .visibilityUnverified)
        }
        let rectangle = CGRect(origin: point, size: dimensions)
        guard CaptureTextPixelProof.valid(rectangle) else { throw Failure(reason: .visibilityUnverified) }
        return rectangle
    }
    private func element(_ attribute: String, of element: AXUIElement) throws -> AXUIElement {
        guard let value = try optional(attribute, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw Failure(reason: .identityUnproved)
        }
        return value as! AXUIElement
    }
    private func optional(_ attribute: String, of element: AXUIElement) throws -> CFTypeRef? {
        try configure(element)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        try check()
        if status == .attributeUnsupported || status == .noValue { return nil }
        guard status == .success else { throw Failure(reason: .controlsUnavailable) }
        return value
    }
    private func observe(_ element: AXUIElement, _ notifications: [String]) throws {
        guard let observer else { throw Failure(reason: .observerUnavailable) }
        for notification in notifications {
            try configure(element)
            if subscriptions.contains(where: { CFEqual($0.0, element) && $0.1 == notification }) { continue }
            let status = AXObserverAddNotification(observer, element, notification as CFString,
                                                   Unmanaged.passUnretained(mutation).toOpaque())
            guard status == .success else { throw Failure(reason: .observerUnavailable) }
            subscriptions.append((element, notification))
        }
    }
    private func configure(_ element: AXUIElement) throws {
        try check()
        let remaining = max(0.001, min(0.025, deadline - ProcessInfo.processInfo.systemUptime))
        guard AXUIElementSetMessagingTimeout(element, Float(remaining)) == .success else { throw Failure(reason: .nativeUnavailable) }
    }
    private func check() throws {
        if cancelled() { throw Failure(reason: .cancelled) }
        if mutation.changed { throw Failure(reason: .sourceChanged) }
        guard ProcessInfo.processInfo.systemUptime <= deadline else { throw Failure(reason: .budgetExceeded) }
        guard MeetingProcessBirth.read(pid: application.processID) == birth else { throw Failure(reason: .sourceChanged) }
    }
}
