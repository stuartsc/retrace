import Foundation
import CoreGraphics
import Shared

enum WindowChangeCapturePolicy {
    static let minimumIntervalSeconds: TimeInterval = 1.25

    static func shouldCaptureWindowChange(lastCaptureAt: Date?, now: Date = Date()) -> Bool {
        guard let lastCaptureAt else { return true }
        return now.timeIntervalSince(lastCaptureAt) >= minimumIntervalSeconds
    }
}

/// One raw/output pair and its worker, exposed internally for stream lifecycle tests.
struct CaptureFrameStreamSession: Sendable {
    let id: UUID
    let input: AsyncStream<CapturedFrame>.Continuation
    let output: AsyncStream<CapturedFrame>
    let task: Task<Void, Never>
}

/// The native source boundary used by the manager's actual lifecycle. Tests own
/// the source stream without starting a WindowServer capture or a screen timer.
protocol CaptureFrameSource: Actor {
    func startCapture(config: CaptureConfig,
                      frameContinuation: AsyncStream<CapturedFrame>.Continuation,
                      displayID: CGDirectDisplayID?) async throws
    func stopCapture() async throws
    func updateConfig(_ config: CaptureConfig) async throws
    func captureImmediateAndResetTimer() async
    func setCoverageHandler(_ handler: (@Sendable (CaptureCoverageEvent) -> Void)?) async
    func setTextOutcomeHandler(_ handler: (@Sendable (CaptureTextOutcome) -> Void)?) async
    func setGroupDelivery(_ delivery: CaptureGroupDelivery?) async
    func suspendGroupedSampling() async
    func activateGroupedSampling(expectedPolicySHA256: String) async throws
}

extension CaptureFrameSource {
    func setCoverageHandler(_ handler: (@Sendable (CaptureCoverageEvent) -> Void)?) async { }
    func setTextOutcomeHandler(_ handler: (@Sendable (CaptureTextOutcome) -> Void)?) async { }
    func setGroupDelivery(_ delivery: CaptureGroupDelivery?) async { }
    func suspendGroupedSampling() async { }
    func activateGroupedSampling(expectedPolicySHA256: String) async throws { }
}

extension CGWindowListCapture: CaptureFrameSource {}

/// Only native permission, display lookup and observer startup are replaceable;
/// configuration, task ownership and forwarding remain in CaptureManager.
struct CaptureLifecycleEnvironment: Sendable {
    let hasPermission: @Sendable () async -> Bool
    let activeDisplayID: @Sendable () async -> UInt32
    let startDisplayMonitoring: @Sendable (UInt32) async -> Void
    let stopDisplayMonitoring: @Sendable () async -> Void

    static func live(display: DisplayMonitor, monitor: DisplaySwitchMonitor) -> Self {
        Self(hasPermission: { await PermissionChecker.hasScreenRecordingPermission() },
             activeDisplayID: { await display.getActiveDisplayID() },
             startDisplayMonitoring: { await monitor.startMonitoring(initialDisplayID: $0) },
             stopDisplayMonitoring: { await monitor.stopMonitoring() })
    }
}

/// Preserve the initiating failure and every failed cleanup acknowledgement.
/// A caller must not mistake a failed durable revoke for successful cancellation.
struct CaptureLifecycleCleanupFailure: Error {
    let operationError: any Error
    let cleanupErrors: [any Error]
}

/// Comparison setting failures report whether the prior recording was restored.
/// Only fixed categories cross this boundary; native errors contain no authority.
public struct CaptureConfigurationUpdateFailure: LocalizedError, Sendable {
    public enum Reason: String, Sendable { case comparisonRejected, restorationFailed }
    public let recordingRestored: Bool
    public let reason: Reason
    public var errorDescription: String? {
        recordingRestored
            ? "The comparison setting could not be applied. Recording continues with the previous setting."
            : "The comparison setting and its restoration failed. Recording has stopped."
    }
}

/// Separate from frame/group counters: policy owner replacement also invalidates
/// an in-flight meeting read. Exhaustion permanently closes this ephemeral gate.
struct MeetingPolicyRevision {
    private var value: UInt64
    private var exhausted = false
    init(initialValue: UInt64 = 0) { value = initialValue }
    var current: UInt64? { exhausted ? nil : value }
    mutating func advance() {
        guard !exhausted, value < .max else { exhausted = true; return }
        value += 1
    }
}

/// Main coordinator for screen capture
/// Implements CaptureProtocol from Shared/Protocols
public actor CaptureManager: CaptureProtocol {

    // MARK: - Properties

    private let cgWindowListCapture: any CaptureFrameSource
    private let lifecycleEnvironment: CaptureLifecycleEnvironment
    private let configurationAdmission: (any CaptureConfigurationAdmissionProtocol)?
    private let groupDelivery: CaptureGroupDelivery?
    private let displayMonitor: DisplayMonitor
    private let displaySwitchMonitor: DisplaySwitchMonitor
    private let deduplicator: FrameDeduplicator
    private let appInfoProvider: any FrontmostMetadataProviding

    private var currentConfig: CaptureConfig
    private var lastKeptFrames: [UInt32: CapturedFrame] = [:]
    private var dedupDisplayOrder: [UInt32] = []
    private var dedupCacheBytes = 0
    private var captureConfigurationGeneration: UInt64 = 0
    private var meetingPolicyRevision = MeetingPolicyRevision()
    private var configurationChangedMonotonic: TimeInterval?
    private var configurationTransitionInFlight = false
    private var configurationGapPending = false
    private let coverageDelivery = CaptureCoverageDelivery()
    private var forwardingGaps: Set<UInt32> = []
    private var _isCapturing: Bool = false

    // Frame stream management
    private var rawFrameContinuation: AsyncStream<CapturedFrame>.Continuation?
    private var dedupedFrameContinuation: AsyncStream<CapturedFrame>.Continuation?
    private var _frameStream: AsyncStream<CapturedFrame>?
    private var frameProcessingSession: CaptureFrameStreamSession?
    private var lifecycleOperation: (id: UUID, task: Task<Void, Error>)?
    private var groupFailureShutdown: (id: UUID, task: Task<Void, Never>)?
    /// Frame forwarding may already be closed while native teardown still owns
    /// resources. Preserve a public retry path independently of recording state.
    private var sourceCleanupPending = false
    private var configurationAdmissionClosed = false
    #if DEBUG
    private var lifecycleEnqueuedCheckpoint: (@Sendable () -> Void)?
    private var groupForwardedCheckpoint: (@Sendable (CaptureGroupFrameReceipt) -> Void)?
    func setGroupForwardedCheckpoint(_ checkpoint: (@Sendable (CaptureGroupFrameReceipt) -> Void)?) {
        groupForwardedCheckpoint = checkpoint
    }

    /// Observes actual queue entry, allowing tests to order concurrent public calls
    /// without timing sleeps or invoking native device APIs.
    func setLifecycleEnqueuedCheckpoint(_ checkpoint: (@Sendable () -> Void)?) {
        lifecycleEnqueuedCheckpoint = checkpoint
    }
    #endif

    // Statistics
    private var stats = CaptureStatistics(
        totalFramesCaptured: 0,
        framesDeduped: 0,
        averageFrameSizeBytes: 0,
        captureStartTime: nil,
        lastFrameTime: nil
    )

    // Permission warnings
    private var hasShownAccessibilityWarning = false

    // Window change debouncing and title tracking
    private var lastWindowChangeCaptureTime: Date?
    private var lastNormalizedTitle: String?
    private var lastBundleID: String?
    private var windowChangeCaptureTask: Task<Void, Never>?
    private var deferredDisplaySyncTask: Task<Void, Never>?
    private var currentCaptureDisplayID: UInt32?
    private var isDisplaySwitchInFlight = false
    private static let windowChangeCaptureDelayMilliseconds = 150

    /// Callback for accessibility permission warnings
    nonisolated(unsafe) public var onAccessibilityPermissionWarning: (() -> Void)?

    /// Callback when capture stops unexpectedly (e.g., user clicked "Stop sharing" in macOS)
    nonisolated(unsafe) public var onCaptureStopped: (@Sendable () async -> Void)?

    // MARK: - Initialization

    public init(config: CaptureConfig = .default,
                configurationAdmission: (any CaptureConfigurationAdmissionProtocol)? = nil,
                groupJournal: (any CaptureGroupJournalProtocol)? = nil) {
        let display = DisplayMonitor()
        let monitor = DisplaySwitchMonitor(displayMonitor: DisplayMonitor())
        self.currentConfig = config
        self.cgWindowListCapture = CaptureSourceRouter()
        self.displayMonitor = display
        self.displaySwitchMonitor = monitor
        self.lifecycleEnvironment = .live(display: display, monitor: monitor)
        self.configurationAdmission = configurationAdmission
        self.groupDelivery = groupJournal.map { CaptureGroupDelivery(journal: $0) }
        self.deduplicator = FrameDeduplicator()
        self.appInfoProvider = AppInfoProvider()
    }

    init(config: CaptureConfig = .default, metadataProvider: any FrontmostMetadataProviding,
         configurationAdmission: (any CaptureConfigurationAdmissionProtocol)? = nil,
         groupJournal: (any CaptureGroupJournalProtocol)? = nil,
         source: any CaptureFrameSource = CaptureSourceRouter(),
         lifecycleEnvironment: CaptureLifecycleEnvironment? = nil) {
        let display = DisplayMonitor()
        let monitor = DisplaySwitchMonitor(displayMonitor: DisplayMonitor())
        self.currentConfig = config
        self.cgWindowListCapture = source
        self.displayMonitor = display
        self.displaySwitchMonitor = monitor
        self.lifecycleEnvironment = lifecycleEnvironment ?? .live(display: display, monitor: monitor)
        self.configurationAdmission = configurationAdmission
        self.groupDelivery = groupJournal.map { CaptureGroupDelivery(journal: $0) }
        self.deduplicator = FrameDeduplicator()
        self.appInfoProvider = metadataProvider
    }

    // MARK: - CaptureProtocol - Lifecycle

    public func hasPermission() async -> Bool {
        await lifecycleEnvironment.hasPermission()
    }

    public func requestPermission() async -> Bool {
        await PermissionChecker.requestPermission()
    }

    public func startCapture(config: CaptureConfig) async throws {
        try await runLifecycleOperation {
            try await self.applyConfiguration(config, operation: .start)
        }
    }

    /// Establish historical-evidence authority after the owning database opens.
    /// This entry never starts native capture hardware.
    public func initializeConfigurationAdmission() async throws {
        try await runLifecycleOperation {
            try await self.applyCurrentConfiguration(operation: .initialize)
        }
    }

    /// End the owning application's authority independently of recording pause.
    public func shutdownConfigurationAdmission() async throws {
        try await runLifecycleOperation(cancelWithCaller: false) {
            try await self.endConfigurationAdmission()
        }
    }

    public func startUsingCurrentConfiguration() async throws {
        try await runLifecycleOperation {
            try await self.applyCurrentConfiguration(operation: .start)
        }
    }

    /// Actor isolation alone does not serialize operations across permission/source awaits.
    func runLifecycleOperation(cancelWithCaller: Bool = true,
                               _ operation: @escaping @Sendable () async throws -> Void) async throws {
        let previous = lifecycleOperation?.task
        let id = UUID()
        let task = Task {
            // A failed earlier operation must not prevent a later stop or retry.
            _ = try? await previous?.value
            // Cancellation before admission owns no policy transition or device.
            if cancelWithCaller { try Task.checkCancellation() }
            try await operation()
        }
        lifecycleOperation = (id, task)
        #if DEBUG
        lifecycleEnqueuedCheckpoint?()
        #endif
        defer {
            if lifecycleOperation?.id == id { lifecycleOperation = nil }
        }
        if cancelWithCaller {
            // Unstructured tasks do not otherwise receive caller cancellation.
            // The operation owns post-await checks and its rollback; checking
            // again here could report failure after a successful activation.
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } else {
            try await task.value
        }
    }

    private enum ConfigurationOperation { case initialize, start, update }

    private func applyCurrentConfiguration(operation: ConfigurationOperation) async throws {
        // Select only after this caller owns the lifecycle slot. A snapshot made
        // before queue admission could overwrite an earlier settings operation.
        try await applyConfiguration(currentConfig, operation: operation)
    }

    private func applyConfiguration(_ config: CaptureConfig, operation: ConfigurationOperation) async throws {
        await groupFailureShutdown?.task.value
        try Task.checkCancellation()
        if sourceCleanupPending {
            try await stopCaptureSession()
            try Task.checkCancellation()
        }
        if operation != .initialize, configurationAdmission != nil, configurationAdmissionClosed {
            throw ScreenEvidenceAdmissionError.inactive
        }
        // Preserve the existing duplicate-start no-op: it neither applies the
        // supplied configuration nor advertises a policy it did not apply.
        if operation == .start, _isCapturing { return }
        if operation == .start, frameProcessingSession != nil {
            // Finish the previous failed source while its existing policy can
            // still acknowledge exact journal retries. Preparing the new epoch
            // first would make a lost begin ACK impossible to reconcile here.
            try await stopCaptureSession()
            try Task.checkCancellation()
        }

        meetingPolicyRevision.advance()
        let previousConfig = currentConfig
        let rollbackSession = operation == .update && _isCapturing &&
            Self.isComparisonOnlyChange(from: previousConfig, to: config) ? frameProcessingSession : nil

        if operation != .initialize {
            configurationTransitionInFlight = true
            captureConfigurationGeneration &+= 1
            configurationChangedMonotonic = ProcessInfo.processInfo.systemUptime
            invalidateDeduplication(displayID: nil)
            if operation == .update, _isCapturing {
                configurationGapPending = true
                coverageDelivery.receive(.init(backend: config.backend, displayID: nil,
                    state: .gap(.configurationChanged)), stage: .forwarding)
            }
        }

        var transition: ScreenEvidencePolicyTransition?
        do {
            if operation != .initialize { await cgWindowListCapture.suspendGroupedSampling() }
            try Task.checkCancellation()
            if let admission = configurationAdmission {
                if operation == .initialize {
                    transition = try await admission.beginSession(config: config)
                } else {
                    transition = try await admission.prepareConfiguration(config)
                }
            }
            try Task.checkCancellation()

            switch operation {
            case .initialize:
                // The constructor's dormant configuration becomes owned only
                // after the writer has durably invalidated its previous epoch.
                currentConfig = config
            case .start:
                // Permission and every native source await are inside the
                // inactive interval, including a denied or late failed start.
                try await startCaptureSession(config: config)
            case .update:
                let requiresDisplayRebind = currentConfig.backend != config.backend || currentConfig.displayPolicy != config.displayPolicy
                currentConfig = config
                if _isCapturing {
                    if requiresDisplayRebind, let session = frameProcessingSession {
                        let displayID = await lifecycleEnvironment.activeDisplayID()
                        try Task.checkCancellation()
                        try await switchCaptureSource(session: session, displayID: displayID)
                    } else {
                        try await cgWindowListCapture.updateConfig(config)
                    }
                }
            }

            try Task.checkCancellation()
            if let transition, let admission = configurationAdmission {
                try await admission.activate(transition)
            }
            // The activation acknowledgement may arrive after its real commit
            // and after cancellation. The catch below still owns that exact token.
            try Task.checkCancellation()
            if operation == .initialize { configurationAdmissionClosed = false }
            if operation != .initialize {
                configurationChangedMonotonic = ProcessInfo.processInfo.systemUptime
                configurationTransitionInFlight = false
                if _isCapturing {
                    try await cgWindowListCapture.activateGroupedSampling(
                        expectedPolicySHA256: ScreenEvidenceAccessPolicy(config: config).fingerprintSHA256())
                }
            }
        } catch {
            let operationError = error
            var cleanupErrors: [any Error] = []
            if let transition, let admission = configurationAdmission {
                do {
                    // Cleanup has an uncancelled task of its own, but this slot
                    // joins it before a later configuration can become active.
                    try await Task { try await admission.revoke(transition) }.value
                } catch {
                    // The store closes its local capability before a revoke
                    // write; propagate a failed durable cleanup rather than success.
                    cleanupErrors.append(error)
                }
            }
            let mayRestore = rollbackSession != nil && !Task.isCancelled && !(operationError is CancellationError)
            var restored = false
            var restorationCancelled = false
            if mayRestore, cleanupErrors.isEmpty, let rollbackSession {
                do {
                    try await restoreComparisonConfiguration(previousConfig, session: rollbackSession)
                    restored = true
                } catch is CancellationError {
                    restorationCancelled = true
                } catch {
                    cleanupErrors.append(error)
                }
            }
            if !restored && (operation == .start || operation == .update) {
                do { try await Task { try await self.stopCaptureSession() }.value }
                catch { cleanupErrors.append(error) }
            }
            if operation != .initialize {
                configurationChangedMonotonic = ProcessInfo.processInfo.systemUptime
                configurationTransitionInFlight = false
            }
            if restorationCancelled, cleanupErrors.isEmpty { throw CancellationError() }
            if mayRestore {
                throw CaptureConfigurationUpdateFailure(recordingRestored: restored,
                    reason: restored ? .comparisonRejected : .restorationFailed)
            }
            if !cleanupErrors.isEmpty {
                throw CaptureLifecycleCleanupFailure(operationError: operationError, cleanupErrors: cleanupErrors)
            }
            throw operationError
        }
    }

    /// Restoring a comparison choice cannot undo an attempted privacy change.
    private static func isComparisonOnlyChange(from previous: CaptureConfig, to next: CaptureConfig) -> Bool {
        (previous.backend != next.backend || previous.displayPolicy != next.displayPolicy) &&
            previous.captureIntervalSeconds == next.captureIntervalSeconds &&
            previous.adaptiveCaptureEnabled == next.adaptiveCaptureEnabled &&
            previous.deduplicationThreshold == next.deduplicationThreshold &&
            previous.maxResolution == next.maxResolution &&
            previous.excludedAppBundleIDs == next.excludedAppBundleIDs &&
            previous.excludePrivateWindows == next.excludePrivateWindows &&
            previous.customPrivateWindowPatterns == next.customPrivateWindowPatterns &&
            previous.showCursor == next.showCursor &&
            previous.redactWindowTitlePatterns == next.redactWindowTitlePatterns &&
            previous.redactBrowserURLPatterns == next.redactBrowserURLPatterns &&
            previous.idleThresholdSeconds == next.idleThresholdSeconds &&
            previous.captureOnWindowChange == next.captureOnWindowChange &&
            previous.captureVisibleTextEnabled == next.captureVisibleTextEnabled &&
            previous.captureGroupReceiptsEnabled == next.captureGroupReceiptsEnabled
    }

    private func restoreComparisonConfiguration(_ config: CaptureConfig,
                                                session: CaptureFrameStreamSession) async throws {
        guard _isCapturing, frameProcessingSession?.id == session.id else {
            throw CaptureError.captureSessionFailed(underlying: "Capture stream ended during configuration restoration")
        }
        var transition: ScreenEvidencePolicyTransition?
        currentConfig = config
        do {
            try Task.checkCancellation()
            transition = try await configurationAdmission?.prepareConfiguration(config)
            try Task.checkCancellation()
            try await cgWindowListCapture.stopCapture()
            coverageDelivery.endSource()
            try Task.checkCancellation()
            let displayID = await lifecycleEnvironment.activeDisplayID()
            try Task.checkCancellation()
            try await cgWindowListCapture.startCapture(config: config, frameContinuation: session.input, displayID: displayID)
            try Task.checkCancellation()
            currentCaptureDisplayID = displayID
            if let transition { try await configurationAdmission?.activate(transition) }
            try Task.checkCancellation()
            configurationChangedMonotonic = ProcessInfo.processInfo.systemUptime
            configurationTransitionInFlight = false
            try await cgWindowListCapture.activateGroupedSampling(
                expectedPolicySHA256: ScreenEvidenceAccessPolicy(config: config).fingerprintSHA256())
        } catch {
            if let transition, let admission = configurationAdmission {
                do { try await Task { try await admission.revoke(transition) }.value }
                catch let cleanupError {
                    throw CaptureLifecycleCleanupFailure(operationError: error, cleanupErrors: [cleanupError])
                }
            }
            throw error
        }
    }

    private func endConfigurationAdmission() async throws {
        meetingPolicyRevision.advance()
        configurationAdmissionClosed = true
        try await configurationAdmission?.endSession()
    }

    private func startCaptureSession(config: CaptureConfig) async throws {
        guard !_isCapturing else { return }
        if frameProcessingSession != nil { try await stopCaptureSession() }

        let permitted = await hasPermission()
        try Task.checkCancellation()
        guard permitted else {
            throw CaptureError.permissionDenied
        }

        self.currentConfig = config

        let session = startFrameProcessing { [weak self] frame in
            await self?.enrichFrameMetadata(frame) ?? frame
        }

        // Get the active display (the one containing the focused window)
        let initialDisplayID = await lifecycleEnvironment.activeDisplayID()
        try Task.checkCancellation()
        await startDisplaySwitchMonitoring(initialDisplayID: initialDisplayID)
        try Task.checkCancellation()
        let activeDisplayID = await lifecycleEnvironment.activeDisplayID()
        try Task.checkCancellation()
        currentCaptureDisplayID = activeDisplayID

        await cgWindowListCapture.setGroupDelivery(groupDelivery)
        try Task.checkCancellation()

        // The configuration bracket owns rollback, including native acquisition
        // that completes late or throws after acquiring its input stream.
        try await cgWindowListCapture.startCapture(
            config: config,
            frameContinuation: session.input,
            displayID: activeDisplayID
        )
        try Task.checkCancellation()

        _isCapturing = true
        stats = CaptureStatistics(
            totalFramesCaptured: 0,
            framesDeduped: 0,
            averageFrameSizeBytes: 0,
            captureStartTime: Date(),
            lastFrameTime: nil
        )
    }

    public func stopCapture() async throws {
        try await runLifecycleOperation(cancelWithCaller: false) { try await self.stopCaptureSession() }
    }

    private func stopCaptureSession() async throws {
        await groupFailureShutdown?.task.value
        guard _isCapturing || frameProcessingSession != nil || sourceCleanupPending else { return }

        // Invalidate callback work before the first suspension. A display-switch
        // callback must not restart the source while shutdown is awaiting it.
        _isCapturing = false
        frameProcessingSession?.task.cancel()
        frameProcessingSession?.input.finish()
        windowChangeCaptureTask?.cancel()
        windowChangeCaptureTask = nil
        deferredDisplaySyncTask?.cancel()
        deferredDisplaySyncTask = nil

        await lifecycleEnvironment.stopDisplayMonitoring()
        var sourceError: Error?
        sourceCleanupPending = true
        do {
            try await cgWindowListCapture.stopCapture()
            sourceCleanupPending = false
        } catch {
            sourceError = error
        }
        coverageDelivery.endSource()

        // Always join the forwarding task, even if source teardown failed.
        await stopFrameProcessing()
        do { try await groupDelivery?.cancelUnforwarded(reason: .sourceStopped) }
        catch { if sourceError == nil { sourceError = error } }
        invalidateDeduplication(displayID: nil)
        forwardingGaps.removeAll()
        configurationGapPending = false
        coverageDelivery.reset()
        hasShownAccessibilityWarning = false
        currentCaptureDisplayID = nil
        isDisplaySwitchInFlight = false
        if let sourceError { throw sourceError }
    }

    public var isCapturing: Bool {
        _isCapturing
    }

    // MARK: - CaptureProtocol - Frame Stream

    public var frameStream: AsyncStream<CapturedFrame> {
        if let stream = _frameStream {
            return stream
        }

        // Create new stream if none exists
        let (stream, continuation) = AsyncStream<CapturedFrame>.makeStream()
        self.dedupedFrameContinuation = continuation
        self._frameStream = stream
        return stream
    }

    // MARK: - CaptureProtocol - Configuration

    public func updateConfig(_ config: CaptureConfig) async throws {
        try await runLifecycleOperation {
            try await self.applyConfiguration(config, operation: .update)
        }
    }

    public func getConfig() async -> CaptureConfig {
        currentConfig
    }

    /// Cheap process-local proof only; never performs SQLite, AX or file work.
    /// Presence of an admission dependency alone is not active recording proof.
    public func meetingCapturePolicySnapshot() -> MeetingCapturePolicySnapshot? {
        guard _isCapturing, configurationAdmission != nil, !configurationAdmissionClosed,
              !configurationTransitionInFlight, lifecycleOperation == nil,
              let revision = meetingPolicyRevision.current else { return nil }
        return MeetingCapturePolicySnapshot(configuration: currentConfig, revision: revision)
    }

    // MARK: - CaptureProtocol - Display Info

    public func getAvailableDisplays() async throws -> [DisplayInfo] {
        try await displayMonitor.getAvailableDisplays()
    }

    public func getFocusedDisplay() async throws -> DisplayInfo? {
        try await displayMonitor.getFocusedDisplay()
    }

    // MARK: - Statistics

    /// Get current capture statistics
    public func getStatistics() -> CaptureStatistics {
        stats
    }

    /// Handlers must enqueue inexpensive content-free status/metric updates.
    public func setCoverageHandler(_ handler: (@Sendable (CaptureCoverageEvent) -> Void)?) async {
        coverageDelivery.setHandler(handler)
        let delivery = coverageDelivery
        let forward: (@Sendable (CaptureCoverageEvent) -> Void)?
        if handler == nil { forward = nil }
        else { forward = { event in delivery.receive(event, stage: .source) } }
        await cgWindowListCapture.setCoverageHandler(forward)
    }

    /// The App owner supplies a bounded content-free inbox and drains it only
    /// after capture stop joins native pixel/text work.
    public func setTextOutcomeHandler(_ handler: (@Sendable (CaptureTextOutcome) -> Void)?) async {
        await cgWindowListCapture.setTextOutcomeHandler(handler)
    }

    /// A failed durable admission must retry unchanged pixels on the next sample.
    public func invalidateDeduplication(displayID: UInt32?) {
        if let displayID {
            if let removed = lastKeptFrames.removeValue(forKey: displayID) { dedupCacheBytes -= removed.imageData.count }
            dedupDisplayOrder.removeAll { $0 == displayID }
        } else {
            lastKeptFrames.removeAll(); dedupDisplayOrder.removeAll(); dedupCacheBytes = 0
        }
    }

    // MARK: - Private Helpers - Display Switching

    /// Start monitoring for display switches
    private func startDisplaySwitchMonitoring(initialDisplayID: UInt32) async {
        // Set up display switch callback
        displaySwitchMonitor.onDisplaySwitch = { oldDisplayID, newDisplayID in
            await self.handleDisplaySwitch(from: oldDisplayID, to: newDisplayID)
        }

        // Set up accessibility permission warning callback
        displaySwitchMonitor.onAccessibilityPermissionDenied = {
            await self.handleAccessibilityPermissionDenied()
        }

        // Set up window change callback for immediate capture
        displaySwitchMonitor.onWindowChange = { [weak self] in
            await self?.handleWindowChangeCoalesced()
        }

        await lifecycleEnvironment.startDisplayMonitoring(initialDisplayID)
    }

    /// Coalesce duplicate window-change events while a capture refresh is in flight.
    private func handleWindowChangeCoalesced() async {
        guard _isCapturing else { return }
        guard currentConfig.captureOnWindowChange else { return }

        if let task = windowChangeCaptureTask {
            await task.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.handleWindowChange()
        }
        windowChangeCaptureTask = task
        await task.value
        windowChangeCaptureTask = nil
    }

    /// Handle window change - capture immediately and reset timer if enabled
    private func handleWindowChange() async {
        guard _isCapturing else { return }
        guard currentConfig.captureOnWindowChange else { return }

        // Keyboard-driven monitor moves can race with display-change notifications.
        // Reconcile active display before capture so we don't keep polling a stale display.
        await syncCaptureDisplayIfNeeded()

        // Get current context for window-change decisions.
        let currentMetadata = await appInfoProvider.getFrontmostAppInfo(includeBrowserURL: true)
        let currentTitle = currentMetadata.windowName ?? ""
        let currentBundleID = currentMetadata.appBundleID ?? ""

        // Check if this is a meaningful title change
        // Skip if titles are related (one contains the other) - handles "Messenger" vs "Messenger (1)"
        if let lastTitle = lastNormalizedTitle,
           let lastBundle = lastBundleID,
           lastBundle == currentBundleID {  // Same app
            let titlesRelated = lastTitle.contains(currentTitle) || currentTitle.contains(lastTitle)
            if titlesRelated && !lastTitle.isEmpty && !currentTitle.isEmpty {
                // Titles are related, skip capture - let regular timer handle it
                // Log.debug("[CaptureManager] Window title change skipped (related titles): '\(lastTitle)' -> '\(currentTitle)'", category: .capture)
                return
            }
        }

        let now = Date()
        guard WindowChangeCapturePolicy.shouldCaptureWindowChange(
            lastCaptureAt: lastWindowChangeCaptureTime,
            now: now
        ) else {
            return
        }
        lastWindowChangeCaptureTime = now

        // Update tracked title/bundle
        lastNormalizedTitle = currentTitle
        lastBundleID = currentBundleID

        // Allow a brief settle period after window change before taking the frame.
        try? await Task.sleep(for: .milliseconds(Self.windowChangeCaptureDelayMilliseconds), clock: .continuous)
        guard !Task.isCancelled else { return }

        // Trigger immediate capture and reset timer
        await cgWindowListCapture.captureImmediateAndResetTimer()
        await syncCaptureDisplayIfNeeded()
        scheduleDisplaySyncCheck()
    }

    /// Handle display switch by restarting capture on the new display
    private func handleDisplaySwitch(from oldDisplayID: UInt32, to newDisplayID: UInt32) async {
        guard let session = frameProcessingSession, _isCapturing else { return }
        // Notify listeners that display switched (used by TimelineWindowController to reposition window)
        await MainActor.run {
            NotificationCenter.default.post(
                name: .activeDisplayDidChange,
                object: nil,
                userInfo: ["displayID": newDisplayID]
            )
        }

        guard _isCapturing, frameProcessingSession?.id == session.id else { return }
        if currentConfig.backend == .screenCaptureKitCandidate && currentConfig.displayPolicy == .allDisplays {
            currentCaptureDisplayID = newDisplayID
            return
        }
        guard oldDisplayID != newDisplayID else {
            currentCaptureDisplayID = newDisplayID
            return
        }
        guard !isDisplaySwitchInFlight else { return }

        isDisplaySwitchInFlight = true
        defer {
            if frameProcessingSession?.id == session.id { isDisplaySwitchInFlight = false }
        }

        do {
            try await runDisplaySwitchOperation(sessionID: session.id) {
                try await self.switchCaptureSource(session: session, displayID: newDisplayID)
            }
        } catch {
            Log.error("Failed to switch displays: \(error.localizedDescription)", category: .capture)
        }
    }

    /// Admit display source work only while its captured stream is current.
    func runDisplaySwitchOperation(
        sessionID: UUID,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await runLifecycleOperation {
            // Validate after admission: a queued stop/restart may have replaced
            // the source while this display callback was waiting its turn.
            guard await self.frameProcessingSession?.id == sessionID else { return }
            try await operation()
        }
    }

    private func switchCaptureSource(session: CaptureFrameStreamSession, displayID: UInt32) async throws {
        guard _isCapturing, frameProcessingSession?.id == session.id else { return }
        captureConfigurationGeneration &+= 1
        configurationChangedMonotonic = ProcessInfo.processInfo.systemUptime
        invalidateDeduplication(displayID: nil)
        if !configurationGapPending {
            configurationGapPending = true
            coverageDelivery.receive(.init(backend: currentConfig.backend, displayID: nil,
                state: .gap(.configurationChanged)), stage: .forwarding)
        }
        try await cgWindowListCapture.stopCapture()
        coverageDelivery.endSource()
        guard _isCapturing, frameProcessingSession?.id == session.id else { return }
        try await cgWindowListCapture.startCapture(
            config: currentConfig,
            frameContinuation: session.input,
            displayID: displayID
        )
        guard _isCapturing, frameProcessingSession?.id == session.id else { return }
        currentCaptureDisplayID = displayID
        if !configurationTransitionInFlight {
            configurationChangedMonotonic = ProcessInfo.processInfo.systemUptime
            try await cgWindowListCapture.activateGroupedSampling(
                expectedPolicySHA256: ScreenEvidenceAccessPolicy(config: currentConfig).fingerprintSHA256())
        }
    }

    /// Handle accessibility permission denial
    private func handleAccessibilityPermissionDenied() async {
        // Only show warning once per session
        guard !hasShownAccessibilityWarning else { return }
        hasShownAccessibilityWarning = true

        // logger.warning("Accessibility permission denied - display switching disabled")

        // Notify UI layer
        onAccessibilityPermissionWarning?()
    }

    /// Handle stream stopped unexpectedly (e.g., user clicked "Stop sharing" in macOS)
    private func handleStreamStopped() async {
        guard _isCapturing else { return }

        Log.info("Screen capture stream stopped unexpectedly", category: .capture)

        do {
            try await stopCapture()
        } catch {
            Log.error("Failed to stop capture after stream termination: \(error.localizedDescription)", category: .capture)
        }

        // Notify listeners
        if let callback = onCaptureStopped {
            await callback()
        }
    }

    // MARK: - Private Helpers - Frame Processing

    /// Set up the same stream path used by capture without starting a screen timer.
    /// Lifecycle callers join stop before restart; generation ownership also protects
    /// the output if an older, suspended worker outlives a replacement.
    func startFrameProcessing(
        enrich: @escaping @Sendable (CapturedFrame) async -> CapturedFrame
    ) -> CaptureFrameStreamSession {
        frameProcessingSession?.task.cancel()
        frameProcessingSession?.input.finish()
        dedupedFrameContinuation?.finish()
        invalidateDeduplication(displayID: nil)
        let id = UUID()
        let (rawStream, rawContinuation) = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingOldest(2))
        let (output, outputContinuation) = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingOldest(2))
        rawFrameContinuation = rawContinuation
        dedupedFrameContinuation = outputContinuation
        _frameStream = output
        let task = Task {
            await processFrameStream(rawStream: rawStream, output: outputContinuation, enrich: enrich)
        }
        let session = CaptureFrameStreamSession(id: id, input: rawContinuation, output: output, task: task)
        frameProcessingSession = session
        Log.debug("[Capture-Stream] Started generation \(id)", category: .capture)
        return session
    }

    func stopFrameProcessing() async {
        // Detach only this generation before awaiting. A stale stop cannot clear
        // a replacement's state after its old worker eventually resumes.
        let session = frameProcessingSession
        frameProcessingSession = nil
        rawFrameContinuation?.finish()
        rawFrameContinuation = nil
        dedupedFrameContinuation = nil
        _frameStream = nil
        session?.task.cancel()
        await session?.task.value
        if let session {
            Log.debug("[Capture-Stream] Joined generation \(session.id)", category: .capture)
        }
    }

    /// Process the raw frame stream with deduplication and metadata enrichment
    private func processFrameStream(
        rawStream: AsyncStream<CapturedFrame>,
        output: AsyncStream<CapturedFrame>.Continuation,
        enrich: @Sendable (CapturedFrame) async -> CapturedFrame
    ) async {
        defer { output.finish() }
        var totalBytes: Int64 = 0
        var totalFrames = 0
        do {
            for await frame in rawStream {
                guard !Task.isCancelled else { break }
                guard !configurationTransitionInFlight else {
                    try await cancelGroupFrame(frame, reason: .configurationChanged); continue
                }
                if let boundary = configurationChangedMonotonic,
                   (frame.metadata.captureMonotonicTime ?? -.infinity) < boundary {
                    try await cancelGroupFrame(frame, reason: .configurationChanged); continue
                }
                if currentConfig.backend == .screenCaptureKitCandidate, currentConfig.captureGroupReceiptsEnabled,
                   frame.metadata.captureGroup == nil { throw CaptureGroupJournalError.invalidTransition }
                let member = frame.metadata.captureGroup
                if let member {
                    guard groupDelivery != nil, let receipt = frame.metadata.pixelReceipt,
                          receipt.attemptID == member.attemptID, member.displayID == frame.metadata.displayID else {
                        throw CaptureGroupJournalError.invalidTransition
                    }
                }
                let admittedGeneration = captureConfigurationGeneration
                let displayID = frame.metadata.displayID
                totalFrames += 1
                totalBytes += Int64(frame.imageData.count)
                var previous = lastKeptFrames[displayID]
                if previous?.metadata.captureContext != frame.metadata.captureContext ||
                    previous?.metadata.redactionReason != frame.metadata.redactionReason { previous = nil }
                // A grouped suppression must name a cached sample in the same
                // source/configuration/attachment lifetime. Missing proof keeps
                // fresh pixels; it never invents an earlier read or timestamp.
                var reference: CaptureAttemptReference?
                if let member {
                    if let old = previous?.metadata.captureGroup, let receipt = previous?.metadata.pixelReceipt,
                       old.sessionID == member.sessionID, old.configurationGeneration == member.configurationGeneration,
                       old.attachmentID == member.attachmentID, old.displayID == member.displayID,
                       old.groupID != member.groupID, old.attemptID == receipt.attemptID {
                        reference = .init(member: old, pixelReceipt: receipt)
                    } else { previous = nil }
                }
                // The grouped candidate retains every changed pixel, including
                // tiny text edits that sampled/perceptual comparisons can miss.
                // Legacy capture remains independently selectable for comparison.
                let exact = member == nil ? nil : ExactFrameReuse.comparison(frame, previous: previous,
                    directTextEnabled: currentConfig.captureVisibleTextEnabled)
                var shouldKeep = !currentConfig.adaptiveCaptureEnabled || (member != nil ? exact == nil :
                    ((currentConfig.captureVisibleTextEnabled && DirectTextDeduplication.hasNewEvidence(frame, comparedTo: previous)) ||
                    deduplicator.shouldKeepFrame(frame, comparedTo: previous, threshold: currentConfig.deduplicationThreshold)))
                if !shouldKeep, let member {
                    guard let delivery = groupDelivery, let pixels = frame.metadata.pixelReceipt, let reference, let exact else {
                        throw CaptureGroupJournalError.invalidTransition
                    }
                    let suppressed = try await delivery.suppress(member, receipt: pixels, reference: reference,
                        comparison: exact)
                    if !suppressed { invalidateDeduplication(displayID: displayID); shouldKeep = true }
                }
                guard shouldKeep else {
                    stats = CaptureStatistics(totalFramesCaptured: totalFrames, framesDeduped: stats.framesDeduped + 1,
                        averageFrameSizeBytes: Int(totalBytes / Int64(totalFrames)),
                        captureStartTime: stats.captureStartTime, lastFrameTime: stats.lastFrameTime)
                    continue
                }
                guard admittedGeneration == captureConfigurationGeneration, !configurationTransitionInFlight else {
                    try await cancelGroupFrame(frame, reason: .configurationChanged); continue
                }
                rememberForDeduplication(frame)
                let enrichedFrame = await enrich(frame)
                guard !Task.isCancelled else { break }
                guard admittedGeneration == captureConfigurationGeneration, !configurationTransitionInFlight else {
                    try await cancelGroupFrame(frame, reason: .configurationChanged); continue
                }
                switch output.yield(enrichedFrame) {
                case .enqueued:
                    if let member {
                        try await groupDelivery?.forwarded(member)
                        #if DEBUG
                        groupForwardedCheckpoint?(member)
                        #endif
                    }
                    if configurationGapPending {
                        configurationGapPending = false
                        coverageDelivery.receive(.init(backend: currentConfig.backend, displayID: nil,
                            state: .recovered), stage: .forwarding)
                    }
                    if forwardingGaps.remove(displayID) != nil {
                        coverageDelivery.receive(CaptureCoverageEvent(backend: currentConfig.backend, displayID: displayID,
                                                                     state: .recovered), stage: .forwarding)
                    }
                    stats = CaptureStatistics(totalFramesCaptured: totalFrames, framesDeduped: stats.framesDeduped,
                        averageFrameSizeBytes: Int(totalBytes / Int64(totalFrames)),
                        captureStartTime: stats.captureStartTime, lastFrameTime: enrichedFrame.timestamp)
                case .dropped(let dropped):
                    if let droppedMember = dropped.metadata.captureGroup, let receipt = dropped.metadata.pixelReceipt {
                        try await groupDelivery?.terminal(.init(member: droppedMember, disposition: .dropped,
                            reason: .outputBufferBackpressure, pixelReceipt: receipt))
                    }
                    invalidateDeduplication(displayID: dropped.metadata.displayID)
                    if !forwardingGaps.contains(dropped.metadata.displayID) {
                        if forwardingGaps.count < 128 { forwardingGaps.insert(dropped.metadata.displayID) }
                        coverageDelivery.receive(CaptureCoverageEvent(backend: currentConfig.backend, displayID: dropped.metadata.displayID,
                                                                     state: .gap(.consumerBackpressure)), stage: .forwarding)
                    }
                case .terminated:
                    try await cancelGroupFrame(frame, reason: .streamCancelled)
                    return
                @unknown default: throw CaptureGroupJournalError.invalidTransition
                }
            }
            if !Task.isCancelled, _isCapturing, currentConfig.backend == .screenCaptureKitCandidate,
               currentConfig.captureGroupReceiptsEnabled { await stopAfterGroupJournalFailure() }
        } catch {
            await stopAfterGroupJournalFailure()
        }
    }

    private func cancelGroupFrame(_ frame: CapturedFrame, reason: CaptureGroupOutcomeReason) async throws {
        guard let member = frame.metadata.captureGroup else { return }
        guard let delivery = groupDelivery, let pixels = frame.metadata.pixelReceipt else {
            throw CaptureGroupJournalError.invalidTransition
        }
        try await delivery.terminal(.init(member: member, disposition: .cancelled,
            reason: reason, pixelReceipt: pixels))
        invalidateDeduplication(displayID: member.displayID)
    }

    /// Runs in the forwarding worker, so it joins native work but never itself.
    /// App observes stream exhaustion plus this categorical gap through its
    /// owned lifecycle task and joins normal stop before closing the journal.
    private func stopAfterGroupJournalFailure() async {
        if let shutdown = groupFailureShutdown { await shutdown.task.value; return }
        _isCapturing = false
        windowChangeCaptureTask?.cancel(); windowChangeCaptureTask = nil
        deferredDisplaySyncTask?.cancel(); deferredDisplaySyncTask = nil
        invalidateDeduplication(displayID: nil)
        coverageDelivery.receive(.init(backend: .screenCaptureKitCandidate, displayID: nil,
            state: .gap(.groupJournalUnavailable)), stage: .forwarding)
        let source = cgWindowListCapture, environment = lifecycleEnvironment, id = UUID()
        sourceCleanupPending = true
        let task = Task {
            await environment.stopDisplayMonitoring()
            do {
                try await source.stopCapture()
                sourceCleanupPending = false
            } catch {
                // The App's normal stop must retry this owner before releasing
                // the capture service or admitting another configuration.
                sourceCleanupPending = true
            }
        }
        groupFailureShutdown = (id, task)
        await task.value
        if groupFailureShutdown?.id == id { groupFailureShutdown = nil }
    }

    private func rememberForDeduplication(_ frame: CapturedFrame) {
        let displayID = frame.metadata.displayID
        invalidateDeduplication(displayID: displayID)
        let byteLimit = 128 * 1024 * 1024
        guard frame.imageData.count <= byteLimit else { return }
        while (lastKeptFrames.count >= 8 || dedupCacheBytes + frame.imageData.count > byteLimit),
              let oldest = dedupDisplayOrder.first { invalidateDeduplication(displayID: oldest) }
        lastKeptFrames[displayID] = frame
        dedupDisplayOrder.append(displayID)
        dedupCacheBytes += frame.imageData.count
    }

    /// Capture-time metadata is immutable. Unknown context stays unknown; a
    /// later frontmost app cannot supply provenance for pixels already saved.
    func enrichFrameMetadata(_ frame: CapturedFrame) async -> CapturedFrame {
        frame
    }

    /// Compare active display vs capture display and force a switch when they drift apart.
    private func syncCaptureDisplayIfNeeded() async {
        guard _isCapturing else { return }
        guard !isDisplaySwitchInFlight else { return }

        let (activeDisplayID, hasAXPermission) = await displayMonitor.getActiveDisplayIDWithPermissionStatus()
        guard hasAXPermission else { return }

        guard let captureDisplayID = currentCaptureDisplayID else {
            currentCaptureDisplayID = activeDisplayID
            return
        }

        guard activeDisplayID != captureDisplayID else { return }
        await handleDisplaySwitch(from: captureDisplayID, to: activeDisplayID)
    }

    /// Schedule one delayed drift check to catch async display updates after keyboard window moves.
    private func scheduleDisplaySyncCheck(delayMilliseconds: UInt64 = 300) {
        deferredDisplaySyncTask?.cancel()
        deferredDisplaySyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delayMilliseconds)), clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.syncCaptureDisplayIfNeeded()
        }
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    /// Posted when the active display changes (user switched to app on different monitor)
    static let activeDisplayDidChange = Notification.Name("activeDisplayDidChange")
}
