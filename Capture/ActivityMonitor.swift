import Foundation
import AppKit
import ApplicationServices
import Shared

enum ActivityApplicationSnapshotRoute: String, Sendable { case current, workspace, ax }

enum ActivityApplicationSnapshotReason: String, CaseIterable, Sendable {
    case available
    case availableWithoutLaunchDate = "available-without-launch-date"
    case missingApplication = "missing-app"
    case missingBundleIdentifier = "missing-bundle-id"
    case terminatedApplication = "terminated-app"
    case invalidProcessIdentifier = "invalid-process"
}

/// Only fixed codes and bounded counters can reach the diagnostic sink.
struct ActivityApplicationDiagnostic: Sendable {
    let route: ActivityApplicationSnapshotRoute
    let reason: ActivityApplicationSnapshotReason
    let suppressedTransitions: [ActivityApplicationSnapshotReason: Int]
    var message: String {
        let counts = ActivityApplicationSnapshotReason.allCases.compactMap { reason -> String? in
            guard let count = suppressedTransitions[reason] else { return nil }
            return "\(reason.rawValue):\(count)"
        }
        return "[Activity] Native application snapshot route=\(route.rawValue) reason=\(reason.rawValue) suppressed=\(counts.isEmpty ? "none" : counts.joined(separator: ","))"
    }
}

enum ActivityApplicationDiagnosticDelivery {
    // Log.info may lock, write and rotate files. Keep that work off both
    // MainActor and Swift's cooperative executor after rate admission.
    private static let queue = DispatchQueue(label: "com.retrace.activity.snapshot-diagnostics", qos: .utility)

    static func enqueue(_ diagnostic: ActivityApplicationDiagnostic,
                        write: @escaping @Sendable (ActivityApplicationDiagnostic) -> Void = {
                            Log.info($0.message, category: .capture)
                        }) {
        queue.async { write(diagnostic) }
    }
}

@MainActor
final class ActivityApplicationDiagnostics {
    static let shared = ActivityApplicationDiagnostics()
    private struct State {
        var lastReason: ActivityApplicationSnapshotReason
        var lastEmission: TimeInterval
        var suppressed: [ActivityApplicationSnapshotReason: Int] = [:]
    }
    private let minimumInterval: TimeInterval
    private let now: () -> TimeInterval
    private let emit: (ActivityApplicationDiagnostic) -> Void
    private var states: [ActivityApplicationSnapshotRoute: State] = [:]

    init(minimumInterval: TimeInterval = 30,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         emit: @escaping (ActivityApplicationDiagnostic) -> Void = { ActivityApplicationDiagnosticDelivery.enqueue($0) }) {
        self.minimumInterval = max(1, minimumInterval); self.now = now; self.emit = emit
    }

    func record(_ reason: ActivityApplicationSnapshotReason, route: ActivityApplicationSnapshotRoute) {
        let time = now()
        guard var state = states[route] else {
            states[route] = State(lastReason: reason, lastEmission: time)
            emit(.init(route: route, reason: reason, suppressedTransitions: [:]))
            return
        }
        let changed = state.lastReason != reason
        state.lastReason = reason
        if time - state.lastEmission < minimumInterval {
            if changed { state.suppressed[reason] = min(state.suppressed[reason, default: 0], Int.max - 1) + 1 }
            states[route] = state
            return
        }
        // Flush suppressed transitions even if the current reason has stabilized.
        // Fixed reason counts preserve brief failures without an identity log.
        let shouldEmit = changed || !state.suppressed.isEmpty
        let diagnostic = ActivityApplicationDiagnostic(route: route, reason: reason, suppressedTransitions: state.suppressed)
        if shouldEmit { state.lastEmission = time; state.suppressed.removeAll(keepingCapacity: true) }
        states[route] = state
        if shouldEmit { emit(diagnostic) }
    }
}

/// NSRunningApplication documents native equality as its process-identity test;
/// PID alone is insufficient and launchDate is absent without LaunchServices.
/// Retained handles plus the observed PID fence automatic termination/relaunch.
/// These opaque observed-lifetime tokens are independent of window/lifecycle resets.
@MainActor
final class ActivityApplicationIdentityRegistry {
    static let shared = ActivityApplicationIdentityRegistry()
    private struct Entry {
        let app: NSRunningApplication
        let pid: Int32
        let generation: String
    }
    private let capacity: Int
    private var entries: [Entry] = []

    init(capacity: Int = 256) { self.capacity = min(256, max(1, capacity)) }

    func generation(for app: NSRunningApplication, observedPID: Int32) -> String? {
        entries.removeAll { $0.app.isTerminated || $0.app.processIdentifier != $0.pid }
        guard observedPID > 0, !app.isTerminated, app.processIdentifier == observedPID else { return nil }
        if let index = entries.firstIndex(where: { $0.pid == observedPID && $0.app.isEqual(app) }) {
            let existing = entries.remove(at: index)
            entries.append(existing)
            return existing.generation
        }
        if entries.count == capacity { entries.removeFirst() }
        let entry = Entry(app: app, pid: observedPID, generation: "native-process:\(UUID())")
        entries.append(entry)
        return entry.generation
    }
}

struct ActivityApplicationSnapshot: Sendable, Equatable {
    let bundleID: String
    let name: String
    let pid: Int32
    let generation: String

    init(bundleID: String, name: String, pid: Int32, generation: String) {
        self.bundleID = bundleID; self.name = name; self.pid = pid; self.generation = generation
    }

    @MainActor init?(_ app: NSRunningApplication?, route: ActivityApplicationSnapshotRoute = .current,
                     registry: ActivityApplicationIdentityRegistry? = nil,
                     diagnostics: ActivityApplicationDiagnostics? = nil) {
        let diagnostics = diagnostics ?? .shared
        guard let app else {
            diagnostics.record(.missingApplication, route: route); return nil
        }
        guard !app.isTerminated else {
            diagnostics.record(.terminatedApplication, route: route); return nil
        }
        let processID = app.processIdentifier
        guard processID > 0 else {
            diagnostics.record(.invalidProcessIdentifier, route: route); return nil
        }
        guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else {
            diagnostics.record(.missingBundleIdentifier, route: route); return nil
        }
        let hasLaunchDate = app.launchDate != nil
        guard let generation = (registry ?? .shared).generation(for: app, observedPID: processID) else {
            diagnostics.record(.invalidProcessIdentifier, route: route); return nil
        }
        self.bundleID = bundleID; name = app.localizedName ?? bundleID; pid = processID
        self.generation = generation
        diagnostics.record(hasLaunchDate ? .available : .availableWithoutLaunchDate, route: route)
    }
}

struct ActivityObservationSignal: Sendable {
    let kind: ActivityEventKind
    let app: ActivityApplicationSnapshot?
    var enrichedContext: ActivityContext? = nil
    var relatedEventID: UUID? = nil
    var generation: Int = 0
    var notificationRevision: UInt64? = nil
    var isWindowSample = false
    var ordinal: UInt64 = 0
    var administrativeMethod: String? = nil
    let wallTime = Date()
    let monotonicTime = ProcessInfo.processInfo.systemUptime
}

/// The notification callback performs a bounded enqueue, never database or AX work.
final class ActivityObservationBuffer: @unchecked Sendable {
    let stream: AsyncStream<ActivityObservationSignal>
    private let continuation: AsyncStream<ActivityObservationSignal>.Continuation
    private let lock = NSLock()
    private var generation = 0
    private var suspended = false
    private var dropped = 0
    private var ordinal: UInt64 = 0
    private var observerRefresh: (@Sendable () -> Void)?

    init(capacity: Int = 128) {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(max(1, capacity)))
    }

    func send(_ input: ActivityObservationSignal) {
        lock.lock(); defer { lock.unlock() }
        if input.kind == .enrichment || input.isWindowSample {
            guard !suspended, input.generation == generation else { return }
            if let revision = input.notificationRevision,
               revision != ObservedWindowGenerations.shared.notificationRevision { return }
        }
        var signal = input; signal.generation = generation
        ordinal &+= 1; signal.ordinal = ordinal
        if case .dropped = continuation.yield(signal) { dropped += 1 }
    }
    func suspend() {
        lock.withLock { suspended = true; generation += 1; ObservedWindowGenerations.shared.reset() }
    }
    func resume() {
        lock.withLock { suspended = false; generation += 1; ObservedWindowGenerations.shared.reset() }
    }
    func permitsContent(generation expected: Int) -> Bool { lock.withLock { !suspended && generation == expected } }
    func permitsCapture(generation expected: Int, processedOrdinal: UInt64) -> Bool {
        lock.withLock { !suspended && generation == expected && ordinal == processedOrdinal && dropped == 0 }
    }
    func takeDroppedCount() -> Int { lock.withLock { let value = dropped; dropped = 0; return value } }
    func setObserverRefresh(_ callback: (@Sendable () -> Void)?) { lock.withLock { observerRefresh = callback } }
    func refreshObserver() {
        let callback = lock.withLock { observerRefresh }
        callback?()
    }
    func finish() { continuation.finish() }
}

@MainActor
private final class ActivityObservationBridge {
    private let buffer: ActivityObservationBuffer
    private var tokens: [NSObjectProtocol] = []
    private var observer: AXObserver?
    private var focusedWindow: AXUIElement?
    private var poll: Task<Void, Never>?
    private var observedPID: Int32?
    private var observedGeneration: String?
    private var registrationID: UUID?
    private var isObserving = false
    private var observerUnavailable = false

    init(buffer: ActivityObservationBuffer) { self.buffer = buffer }

    func start() {
        guard !isObserving else { return }
        isObserving = true
        buffer.setObserverRefresh { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe(kind: .reconciliation, application: NSWorkspace.shared.frontmostApplication, emitSignal: false)
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                self?.observe(kind: .focus, application: note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                              route: .workspace)
            }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.buffer.suspend(); self.buffer.send(.init(kind: .sleep, app: nil))
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.buffer.resume(); self.buffer.send(.init(kind: .wake, app: nil))
                    self.observe(kind: .reconciliation, application: NSWorkspace.shared.frontmostApplication)
                }
            })
        }
        observe(kind: .focus, application: NSWorkspace.shared.frontmostApplication)
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2), clock: .continuous) } catch { break }
                guard let self else { break }
                self.observe(kind: .reconciliation, application: NSWorkspace.shared.frontmostApplication)
            }
        }
    }

    private func observe(kind: ActivityEventKind, application: NSRunningApplication?,
                         route: ActivityApplicationSnapshotRoute = .current, emitSignal: Bool = true) {
        guard isObserving else { return }
        let applicationSnapshot = ActivityApplicationSnapshot(application, route: route)
        if emitSignal {
            if kind == .focus { ObservedWindowGenerations.shared.reset() }
            buffer.send(.init(kind: kind, app: applicationSnapshot))
        }
        let pid = application?.processIdentifier
        let generation = applicationSnapshot?.generation
        if pid != observedPID || generation != observedGeneration || registrationID == nil {
            let changedProcess = pid != observedPID || generation != observedGeneration
            observedPID = pid
            observedGeneration = generation
            if changedProcess { removeAXObserver() }
            guard let pid, let generation else { return }
            let requestID = UUID(); registrationID = requestID
            let buffer = self.buffer
            // AX setup/metadata reads happen off main. Only run-loop registration is UI work.
            Task { [weak self] in
                let setup = await Task.detached(priority: .utility) { ActivityAXRegistration.make(pid: pid, buffer: buffer) }.value
                guard let self, self.isObserving, self.observedPID == pid, self.observedGeneration == generation,
                      self.registrationID == requestID else { return }
                self.registrationID = nil
                guard let setup else {
                    self.removeAXObserver()
                    if !self.observerUnavailable { buffer.send(.init(kind: .observerFailure, app: nil)) }
                    self.observerUnavailable = true
                    return
                }
                // Keep the old observer live until the replacement subscribes to
                // the current same-app window's title/move/destroy notifications.
                self.removeAXObserver()
                self.observer = setup.observer; self.focusedWindow = setup.window
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(setup.observer), .commonModes)
                if self.observerUnavailable {
                    buffer.send(.init(kind: .resume, app: nil, administrativeMethod: "accessibility-observer-restored"))
                    buffer.send(.init(kind: .reconciliation, app: ActivityApplicationSnapshot(NSWorkspace.shared.frontmostApplication)))
                }
                self.observerUnavailable = false
            }
        }
    }

    private func removeAXObserver() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; focusedWindow = nil
    }

    func stop() {
        isObserving = false
        buffer.setObserverRefresh(nil)
        poll?.cancel(); poll = nil
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        tokens.removeAll(); observedPID = nil; observedGeneration = nil; registrationID = nil; removeAXObserver()
    }
}

/// The real AX callback route, separated only from the run-loop API so notification
/// ordering can be exercised with native test windows and the canonical writer.
enum ActivityAXNotificationHandler {
    static func handle(_ notification: String, app: ActivityApplicationSnapshot?,
                       buffer: ActivityObservationBuffer,
                       registry: ObservedWindowGenerations = .shared) {
        let windowChanged = notification != kAXTitleChangedNotification && notification != kAXMovedNotification
        registry.noteNotification(resettingWindows: windowChanged)
        buffer.send(.init(kind: .focus, app: app))
        if windowChanged { buffer.refreshObserver() }
    }
}

private struct ActivityAXRegistration: @unchecked Sendable {
    let observer: AXObserver
    let application: AXUIElement
    let window: AXUIElement?

    static func make(pid: Int32, buffer: ActivityObservationBuffer) -> Self? {
        guard AXIsProcessTrusted() else { return nil }
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, _, notification, pointer in
            guard let pointer else { return }
            let buffer = Unmanaged<ActivityObservationBuffer>.fromOpaque(pointer).takeUnretainedValue()
            // No AX traversal in a run-loop callback. Reconcile the current focused window off main.
            MainActor.assumeIsolated {
                ActivityAXNotificationHandler.handle(notification as String,
                    app: ActivityApplicationSnapshot(NSWorkspace.shared.frontmostApplication, route: .ax), buffer: buffer)
            }
        }, &observer) == .success, let observer else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
        let window: AXUIElement? = result == .success && value.map({ CFGetTypeID($0) == AXUIElementGetTypeID() }) == true
            ? (value as! AXUIElement) : nil
        let pointer = Unmanaged.passUnretained(buffer).toOpaque()
        let subscribed = AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, pointer)
        AXObserverAddNotification(observer, app, kAXTitleChangedNotification as CFString, pointer)
        if let window {
            for name in [kAXTitleChangedNotification, kAXMovedNotification, kAXUIElementDestroyedNotification] {
                AXObserverAddNotification(observer, window, name as CFString, pointer)
            }
        }
        guard subscribed == .success || subscribed == .notificationAlreadyRegistered else { return nil }
        return .init(observer: observer, application: app, window: window)
    }
}

public struct ActivityMonitorHealth: Sendable {
    public let collecting: Bool
    public let degraded: Bool
    public let lastObservedAt: Date?
    public let lastPersistedAt: Date?
    public let droppedTransitions: Int
}

/// Independent of the screenshot worker, its deduplication and OCR queues.
public actor ActivityMonitor {
    private let store: any ActivityStoreProtocol
    private let configuration: @Sendable () async -> CaptureConfig
    private let source: ActivityContextSource
    private let recordDurableLatency: @Sendable (Double) -> Void
    private var buffer: ActivityObservationBuffer?
    private var bridge: ActivityObservationBridge?
    private var worker: Task<Void, Never>?
    private var sessionID = UUID()
    private var sequence: Int64 = 0
    private var lastContext: ActivityContext?
    private var lastBaseContext: ActivityContext?
    private var lastFocusEventID: UUID?
    private var lastWrittenEventID: UUID?
    private var enrichmentTask: Task<Void, Never>?
    private var enrichmentID: UUID?
    private var enrichmentResamplePending = false
    private var lifecycleTask: Task<Void, Never>?
    private var lifecycleID: UUID?
    private var lastEventTime: Date?
    private var lastEventKind: ActivityEventKind?
    private var lastPersistedAt: Date?
    private var lastObservedAt: Date?
    private var previousWall: Date?
    private var previousMonotonic: TimeInterval?
    private var storageFailed = false
    private var droppedTransitions = 0
    private var permissionAvailable: Bool?
    private var lastObserverFailureAt: Date?
    private var lastContextEvent: ActivityEvent?
    private var lastContentGeneration = 0
    private var lastProcessedOrdinal: UInt64 = 0

    public init(store: any ActivityStoreProtocol, configuration: @escaping @Sendable () async -> CaptureConfig) {
        self.store = store; self.configuration = configuration; self.source = .live
        self.recordDurableLatency = { Log.recordLatency("activity.notification_to_durable", valueMs: $0, category: .capture) }
    }

    init(store: any ActivityStoreProtocol, configuration: @escaping @Sendable () async -> CaptureConfig,
         source: ActivityContextSource,
         recordDurableLatency: @escaping @Sendable (Double) -> Void = {
             Log.recordLatency("activity.notification_to_durable", valueMs: $0, category: .capture)
         }) {
        self.store = store; self.configuration = configuration; self.source = source
        self.recordDurableLatency = recordDurableLatency
    }

    public func start() async {
        await startObserving(observations: nil)
    }

    func start(observations: ActivityObservationBuffer) async {
        await startObserving(observations: observations)
    }

    private func startObserving(observations: ActivityObservationBuffer?) async {
        let previous = lifecycleTask
        let id = UUID(); lifecycleID = id
        let task = Task { await previous?.value; await self.startObservation(observations: observations) }
        lifecycleTask = task
        await task.value
        if lifecycleID == id { lifecycleTask = nil; lifecycleID = nil }
    }

    private func startObservation(observations: ActivityObservationBuffer?) async {
        guard worker == nil else { return }
        sessionID = UUID(); sequence = 0; lastContext = nil; lastBaseContext = nil
        lastFocusEventID = nil; lastWrittenEventID = nil
        lastContextEvent = nil; lastProcessedOrdinal = 0
        ObservedWindowGenerations.shared.reset()
        previousWall = nil; previousMonotonic = nil
        let buffer = observations ?? ActivityObservationBuffer(); self.buffer = buffer
        buffer.send(.init(kind: .startup, app: nil))
        worker = Task { [weak self] in
            for await signal in buffer.stream {
                guard !Task.isCancelled else { break }
                await self?.consume(signal, buffer: buffer)
            }
        }
        if observations == nil {
            let bridge = await ActivityObservationBridge(buffer: buffer)
            self.bridge = bridge
            await bridge.start()
        }
    }

    public func stop(shutdown: Bool = false) async {
        let previous = lifecycleTask
        let id = UUID(); lifecycleID = id
        let task = Task { await previous?.value; await self.stopObservation(shutdown: shutdown) }
        lifecycleTask = task
        await task.value
        if lifecycleID == id { lifecycleTask = nil; lifecycleID = nil }
    }

    private func stopObservation(shutdown: Bool) async {
        guard let buffer else { return }
        buffer.suspend()
        enrichmentTask?.cancel(); enrichmentTask = nil; enrichmentID = nil
        await bridge?.stop(); bridge = nil
        buffer.finish()
        let task = worker
        await task?.value
        let signal = ActivityObservationSignal(kind: shutdown ? .shutdown : .pause, app: nil)
        _ = await persist(kind: signal.kind, coverage: shutdown ? .stopped : .paused, context: nil, signal: signal, method: "master-capture-stop")
        worker = nil; self.buffer = nil; resetContext()
    }

    public func health() -> ActivityMonitorHealth {
        .init(collecting: worker != nil, degraded: storageFailed || permissionAvailable == false || lastObserverFailureAt != nil, lastObservedAt: lastObservedAt,
              lastPersistedAt: lastPersistedAt, droppedTransitions: droppedTransitions)
    }

    /// Deterministic regression synchronization around controlled external AX work.
    /// Join only the captured request; do not change state or wait for a later retry.
    func waitForCurrentEnrichmentForTesting() async {
        let request = enrichmentTask
        await request?.value
    }

    public func configurationChanged() async {
        guard let buffer else { return }
        buffer.suspend()
        resetContext()
        ObservedWindowGenerations.shared.reset()
        buffer.send(.init(kind: .gap, app: nil, administrativeMethod: "capture-policy-changed"))
        buffer.resume()
        let app = await source.frontmost()
        guard self.buffer === buffer else { return }
        buffer.send(.init(kind: .reconciliation, app: app))
        Log.info("[Activity] Capture policy changed; queued context invalidated", category: .capture)
    }

    public func captureIdentity(for metadata: FrameMetadata, at date: Date) async -> ActivityCaptureIdentity? {
        guard worker != nil, !storageFailed, let buffer,
              buffer.permitsCapture(generation: lastContentGeneration, processedOrdinal: lastProcessedOrdinal),
              let event = lastContextEvent, let observed = event.context,
              let captured = metadata.captureContext, let monotonic = metadata.captureMonotonicTime,
              date.timeIntervalSince1970.isFinite, monotonic.isFinite, monotonic >= event.monotonicTime,
              date >= event.observedAt, abs(date.timeIntervalSince(event.observedAt) - (monotonic - event.monotonicTime)) <= 2,
              let windowID = captured.windowID, windowID > 0,
              let windowGeneration = captured.windowGeneration, !windowGeneration.isEmpty,
              captured.processID > 0, !captured.processGeneration.isEmpty,
              captured.displayID == metadata.displayID, metadata.displayID > 0,
              metadata.redactionReason == nil, metadata.appBundleID == captured.appBundleID,
              metadata.windowName == captured.windowTitle, metadata.browserURL == captured.safeURL,
              sameSurface(observed, captured) else { return nil }
        return ActivityCaptureIdentity(activityEventID: event.id, sessionID: event.sessionID,
            processID: captured.processID, processGeneration: captured.processGeneration,
            windowID: windowID, windowGeneration: windowGeneration, captureMonotonicTime: monotonic,
            documentID: captured.documentID, paneID: captured.paneID)
    }

    private func sameSurface(_ first: ActivityContext, _ second: ActivityContext) -> Bool {
        first.appBundleID == second.appBundleID && first.processID == second.processID
            && first.processGeneration == second.processGeneration && first.windowID == second.windowID
            && first.windowGeneration == second.windowGeneration && first.displayID == second.displayID
            && first.documentID == second.documentID && first.paneID == second.paneID
            && first.windowTitle == second.windowTitle && first.safeURL == second.safeURL
    }

    private func consume(_ signal: ActivityObservationSignal, buffer: ActivityObservationBuffer) async {
        defer { lastProcessedOrdinal = signal.ordinal }
        let dropped = buffer.takeDroppedCount()
        if dropped > 0 {
            droppedTransitions += dropped; resetContext()
            _ = await persist(kind: .gap, coverage: .unknown, context: nil, signal: signal, method: "bounded-queue-overflow")
        }
        if storageFailed {
            resetContext()
            guard await persist(kind: .gap, coverage: .unknown, context: nil, signal: signal, method: "storage-reconciliation") else { return }
        }
        if let wall = previousWall, let monotonic = previousMonotonic,
           abs(signal.wallTime.timeIntervalSince(wall) - (signal.monotonicTime - monotonic)) > 2 {
            resetContext()
            _ = await persist(kind: .clockChange, coverage: .unknown, context: nil, signal: signal, method: "wall-clock-discontinuity")
        }
        previousWall = signal.wallTime; previousMonotonic = signal.monotonicTime

        switch signal.kind {
        case .startup, .pause, .shutdown, .sleep, .wake, .resume, .gap, .observerFailure:
            if signal.kind == .resume, signal.administrativeMethod == "accessibility-observer-restored" {
                lastObserverFailureAt = nil
            }
            if signal.kind == .observerFailure {
                if let lastObserverFailureAt, signal.wallTime.timeIntervalSince(lastObserverFailureAt) < 30 { return }
                lastObserverFailureAt = signal.wallTime
            }
            let coverage: ActivityCoverage = signal.kind == .sleep ? .sleeping : signal.kind == .pause ? .paused : signal.kind == .shutdown ? .stopped : .unknown
            resetContext()
            _ = await persist(kind: signal.kind, coverage: coverage, context: nil, signal: signal,
                              method: signal.administrativeMethod ?? "lifecycle")
            return
        default: break
        }
        guard buffer.permitsContent(generation: signal.generation) else { return }
        let config = await configuration()
        guard buffer.permitsContent(generation: signal.generation) else { return }
        let currentApp = await source.frontmost()
        guard buffer.permitsContent(generation: signal.generation) else { return }
        // Only an explicit reconciliation may sample a later current process.
        // An unavailable notified identity remains unknown at its original time.
        guard let app = signal.app ?? (signal.kind == .reconciliation ? currentApp : nil) else {
            resetContext()
            _ = await persist(kind: .gap, coverage: .unknown, context: nil, signal: signal,
                              method: signal.kind == .reconciliation ? "frontmost-app-unavailable" : "notified-app-unavailable")
            return
        }
        guard !config.excludedAppBundleIDs.contains(app.bundleID),
              !["com.apple.loginwindow", "com.apple.SecurityAgent"].contains(app.bundleID) else {
            resetContext()
            if lastEventKind != .excluded || lastEventTime.map({ signal.wallTime.timeIntervalSince($0) >= 30 }) ?? true {
                _ = await persist(kind: .excluded, coverage: .excluded, context: nil, signal: signal, method: "capture-policy")
            }
            return
        }
        if signal.kind == .enrichment {
            guard app == currentApp, buffer.permitsContent(generation: signal.generation),
                  signal.notificationRevision == ObservedWindowGenerations.shared.notificationRevision,
                  signal.relatedEventID == lastFocusEventID, let enriched = signal.enrichedContext,
                  enriched.windowID == lastBaseContext?.windowID,
                  enriched.windowGeneration == lastBaseContext?.windowGeneration,
                  enriched.processGeneration == lastBaseContext?.processGeneration,
                  config.redactWindowTitlePatterns.allSatisfy({ $0.isEmpty || !(enriched.windowTitle ?? "").localizedCaseInsensitiveContains($0) }),
                  config.redactBrowserURLPatterns.isEmpty else { return }
            if enriched == lastContext { return }
            let navigationChanged = lastContext?.documentID != nil && lastContext?.documentID != enriched.documentID
            if await persist(kind: navigationChanged ? .focus : .enrichment, coverage: .uncertain,
                             context: enriched, signal: signal, method: "captured-window-ax-document-v1",
                             relatedEventID: navigationChanged ? nil : signal.relatedEventID),
               buffer.permitsContent(generation: signal.generation) {
                lastContext = enriched
                if navigationChanged { lastFocusEventID = lastWrittenEventID }
            }
            return
        }

        if signal.isWindowSample, let context = signal.enrichedContext {
            guard signal.notificationRevision == ObservedWindowGenerations.shared.notificationRevision,
                  context.appBundleID == app.bundleID, context.processGeneration == app.generation,
                  config.redactWindowTitlePatterns.allSatisfy({ $0.isEmpty || !(context.windowTitle ?? "").localizedCaseInsensitiveContains($0) }) else { return }
            if context != lastBaseContext {
                let fallback = signal.kind == .reconciliation
                if await persist(kind: fallback ? .reconciliation : .focus, coverage: .uncertain,
                                 context: context, signal: signal,
                                 method: signal.administrativeMethod
                                     ?? (fallback ? "two-second-reconciliation" : "sampled-window-after-notification")),
                   buffer.permitsContent(generation: signal.generation) {
                    lastContext = context; lastBaseContext = context; lastFocusEventID = lastWrittenEventID
                }
            } else if lastEventTime.map({ signal.wallTime.timeIntervalSince($0) >= 30 }) ?? true {
                _ = await persist(kind: .heartbeat, coverage: .uncertain, context: lastContext ?? context,
                                  signal: signal, method: "unchanged-focus-reconciled")
            }
            if let relatedEventID = lastFocusEventID, app == currentApp,
               let revision = signal.notificationRevision,
               revision == ObservedWindowGenerations.shared.notificationRevision,
               buffer.permitsContent(generation: signal.generation) {
                // Keep one AX read in flight. A later same-title signal requests a
                // fresh sample when it finishes, instead of losing that navigation
                // or spawning an unbounded set of cancelled AX reads.
                guard enrichmentTask == nil else {
                    enrichmentResamplePending = true
                    return
                }
                let generation = signal.generation
                let source = self.source
                let requestID = UUID(); enrichmentID = requestID
                enrichmentTask = Task.detached(priority: .utility) { [weak self] in
                    let enriched = await source.document(context, app)
                    if !Task.isCancelled, let enriched,
                       revision == ObservedWindowGenerations.shared.notificationRevision {
                        buffer.send(.init(kind: .enrichment, app: app, enrichedContext: enriched,
                                          relatedEventID: relatedEventID, generation: generation,
                                          notificationRevision: revision))
                    }
                    await self?.finishEnrichment(requestID)
                }
            }
            return
        }

        // Only permission-safe app metadata is durable at notification time.
        // A later window sample gets its own observation time and cannot rewrite this event.
        if signal.kind == .focus,
           lastContext?.appBundleID != app.bundleID || lastContext?.processGeneration != app.generation,
           let minimal = AppInfoProvider().activityContext(for: app, isStillFocused: false, config: config) {
            guard await persist(kind: .focus, coverage: .uncertain, context: minimal, signal: signal,
                                method: "workspace-app-notification"),
                  buffer.permitsContent(generation: signal.generation) else { return }
            lastContext = minimal; lastBaseContext = nil; lastFocusEventID = lastWrittenEventID
        }
        guard app == currentApp else { return }
        let permission = source.permission()
        if permissionAvailable != permission {
            permissionAvailable = permission
            if !permission {
                resetContext()
                _ = await persist(kind: .permissionLost, coverage: .unknown, context: nil, signal: signal, method: "accessibility-unavailable")
            }
        }
        let revision = ObservedWindowGenerations.shared.notificationRevision
        let context = await source.window(app, true, config)
        guard buffer.permitsContent(generation: signal.generation) else { return }
        guard app == (await source.frontmost()), buffer.permitsContent(generation: signal.generation),
              revision == ObservedWindowGenerations.shared.notificationRevision else { return }
        guard let context else {
            let shouldPublish = lastContext != nil || lastEventKind != .excluded || lastEventTime.map({ signal.wallTime.timeIntervalSince($0) >= 30 }) ?? true
            resetContext()
            if shouldPublish {
                _ = await persist(kind: .excluded, coverage: .excluded, context: nil, signal: signal, method: "capture-policy-or-unproven-window")
            }
            return
        }
        // Queue the newly sampled context behind already observed notifications.
        // This preserves chronological monotonic ordering without backdating a window.
        buffer.send(.init(kind: signal.kind, app: app, enrichedContext: context,
                          generation: signal.generation, notificationRevision: revision, isWindowSample: true,
                          administrativeMethod: signal.administrativeMethod))
    }

    private func finishEnrichment(_ id: UUID) {
        guard enrichmentID == id else { return }
        enrichmentTask = nil; enrichmentID = nil
        if enrichmentResamplePending {
            enrichmentResamplePending = false
            // This is a new sample of the current source, never a replayed app
            // notification with an obsolete application and a fresh timestamp.
            buffer?.send(.init(kind: .reconciliation, app: nil, administrativeMethod: "document-enrichment-retry"))
        }
    }

    private func resetContext() {
        lastContext = nil; lastBaseContext = nil; lastFocusEventID = nil; lastContextEvent = nil
        ObservedWindowGenerations.shared.reset()
        enrichmentTask?.cancel(); enrichmentTask = nil; enrichmentID = nil
        enrichmentResamplePending = false
    }

    private func persist(kind: ActivityEventKind, coverage: ActivityCoverage, context: ActivityContext?,
                         signal: ActivityObservationSignal, method: String, relatedEventID: UUID? = nil) async -> Bool {
        sequence += 1
        let event = ActivityEvent(sessionID: sessionID, sequence: sequence, observedAt: signal.wallTime,
                                  monotonicTime: max(previousMonotonic ?? 0, signal.monotonicTime),
                                  kind: kind, coverage: coverage, context: context, relatedEventID: relatedEventID, method: method)
        lastObservedAt = signal.wallTime
        do {
            let receipt = try await store.appendActivity(event)
            let acknowledgedAt = ProcessInfo.processInfo.systemUptime
            lastPersistedAt = receipt.persistedAt; lastEventTime = signal.wallTime; storageFailed = false
            lastEventKind = kind
            lastWrittenEventID = event.id
            if context != nil, buffer?.permitsContent(generation: signal.generation) == true {
                lastContextEvent = event; lastContentGeneration = signal.generation
            }
            // persistedAt is sampled before the transaction's writes and commit.
            // Measure through the successful acknowledgement using the signal's monotonic clock.
            recordDurableLatency(max(0, (acknowledgedAt - signal.monotonicTime) * 1000))
            return true
        } catch {
            storageFailed = true
            Log.warning("[Activity] Persistence unavailable; coverage requires reconciliation", category: .capture)
            return false
        }
    }
}
