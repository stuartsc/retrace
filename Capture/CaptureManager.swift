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

/// Main coordinator for screen capture
/// Implements CaptureProtocol from Shared/Protocols
public actor CaptureManager: CaptureProtocol {

    // MARK: - Properties

    private let cgWindowListCapture: any CaptureFrameSource
    private let lifecycleEnvironment: CaptureLifecycleEnvironment
    private let configurationAdmission: (any CaptureConfigurationAdmissionProtocol)?
    private let displayMonitor: DisplayMonitor
    private let displaySwitchMonitor: DisplaySwitchMonitor
    private let deduplicator: FrameDeduplicator
    private let appInfoProvider: any FrontmostMetadataProviding

    private var currentConfig: CaptureConfig
    private var lastKeptFrame: CapturedFrame?
    private var _isCapturing: Bool = false

    // Frame stream management
    private var rawFrameContinuation: AsyncStream<CapturedFrame>.Continuation?
    private var dedupedFrameContinuation: AsyncStream<CapturedFrame>.Continuation?
    private var _frameStream: AsyncStream<CapturedFrame>?
    private var frameProcessingSession: CaptureFrameStreamSession?
    private var lifecycleOperation: (id: UUID, task: Task<Void, Error>)?
    private var configurationAdmissionClosed = false
    #if DEBUG
    private var lifecycleEnqueuedCheckpoint: (@Sendable () -> Void)?

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
                configurationAdmission: (any CaptureConfigurationAdmissionProtocol)? = nil) {
        let display = DisplayMonitor()
        let monitor = DisplaySwitchMonitor(displayMonitor: DisplayMonitor())
        self.currentConfig = config
        self.cgWindowListCapture = CGWindowListCapture()
        self.displayMonitor = display
        self.displaySwitchMonitor = monitor
        self.lifecycleEnvironment = .live(display: display, monitor: monitor)
        self.configurationAdmission = configurationAdmission
        self.deduplicator = FrameDeduplicator()
        self.appInfoProvider = AppInfoProvider()
    }

    init(config: CaptureConfig = .default, metadataProvider: any FrontmostMetadataProviding,
         configurationAdmission: (any CaptureConfigurationAdmissionProtocol)? = nil,
         source: any CaptureFrameSource = CGWindowListCapture(),
         lifecycleEnvironment: CaptureLifecycleEnvironment? = nil) {
        let display = DisplayMonitor()
        let monitor = DisplaySwitchMonitor(displayMonitor: DisplayMonitor())
        self.currentConfig = config
        self.cgWindowListCapture = source
        self.displayMonitor = display
        self.displaySwitchMonitor = monitor
        self.lifecycleEnvironment = lifecycleEnvironment ?? .live(display: display, monitor: monitor)
        self.configurationAdmission = configurationAdmission
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
        if operation != .initialize, configurationAdmission != nil, configurationAdmissionClosed {
            throw ScreenEvidenceAdmissionError.inactive
        }
        // Preserve the existing duplicate-start no-op: it neither applies the
        // supplied configuration nor advertises a policy it did not apply.
        if operation == .start, _isCapturing { return }

        var transition: ScreenEvidencePolicyTransition?
        do {
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
                currentConfig = config
                if _isCapturing { try await cgWindowListCapture.updateConfig(config) }
            }

            try Task.checkCancellation()
            if let transition, let admission = configurationAdmission {
                try await admission.activate(transition)
            }
            // The activation acknowledgement may arrive after its real commit
            // and after cancellation. The catch below still owns that exact token.
            try Task.checkCancellation()
            if operation == .initialize { configurationAdmissionClosed = false }
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
            if operation == .start {
                do { try await Task { try await self.stopCaptureSession() }.value }
                catch { cleanupErrors.append(error) }
            }
            if !cleanupErrors.isEmpty {
                throw CaptureLifecycleCleanupFailure(operationError: operationError, cleanupErrors: cleanupErrors)
            }
            throw operationError
        }
    }

    private func endConfigurationAdmission() async throws {
        configurationAdmissionClosed = true
        try await configurationAdmission?.endSession()
    }

    private func startCaptureSession(config: CaptureConfig) async throws {
        guard !_isCapturing else { return }

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
        let activeDisplayID = await lifecycleEnvironment.activeDisplayID()
        try Task.checkCancellation()
        currentCaptureDisplayID = activeDisplayID

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

        let initialDisplayID = await lifecycleEnvironment.activeDisplayID()
        try Task.checkCancellation()
        await startDisplaySwitchMonitoring(initialDisplayID: initialDisplayID)
    }

    public func stopCapture() async throws {
        try await runLifecycleOperation(cancelWithCaller: false) { try await self.stopCaptureSession() }
    }

    private func stopCaptureSession() async throws {
        guard _isCapturing || frameProcessingSession != nil else { return }

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
        do {
            try await cgWindowListCapture.stopCapture()
        } catch {
            sourceError = error
        }

        // Always join the forwarding task, even if source teardown failed.
        await stopFrameProcessing()
        lastKeptFrame = nil
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
        try await cgWindowListCapture.stopCapture()
        guard _isCapturing, frameProcessingSession?.id == session.id else { return }
        try await cgWindowListCapture.startCapture(
            config: currentConfig,
            frameContinuation: session.input,
            displayID: displayID
        )
        guard _isCapturing, frameProcessingSession?.id == session.id else { return }
        currentCaptureDisplayID = displayID
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
        lastKeptFrame = nil
        let id = UUID()
        let (rawStream, rawContinuation) = AsyncStream<CapturedFrame>.makeStream()
        let (output, outputContinuation) = AsyncStream<CapturedFrame>.makeStream()
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
        // Never finish the manager's mutable current-generation continuation.
        defer { output.finish() }
        var totalBytes: Int64 = 0
        var totalFrames = 0

        for await frame in rawStream {
            guard !Task.isCancelled else { break }
            totalFrames += 1
            totalBytes += Int64(frame.imageData.count)

            // Apply deduplication if enabled
            if currentConfig.adaptiveCaptureEnabled {
                let similarity = lastKeptFrame != nil ? deduplicator.computeSimilarity(frame, lastKeptFrame!) : 0.0
                let shouldKeep = deduplicator.shouldKeepFrame(
                    frame,
                    comparedTo: lastKeptFrame,
                    threshold: currentConfig.deduplicationThreshold
                )

                if shouldKeep {
                    // Keep raw frame for future similarity checks. Metadata is not needed for dedup.
                    lastKeptFrame = frame
                    let enrichedFrame = await enrich(frame)
                    guard !Task.isCancelled else { break }
                    output.yield(enrichedFrame)

                    // Update stats
                    stats = CaptureStatistics(
                        totalFramesCaptured: totalFrames,
                        framesDeduped: stats.framesDeduped,
                        averageFrameSizeBytes: Int(totalBytes / Int64(totalFrames)),
                        captureStartTime: stats.captureStartTime,
                        lastFrameTime: enrichedFrame.timestamp
                    )

                    Log.verbose("Frame kept (similarity: \(String(format: "%.2f%%", similarity * 100)))", category: .capture)
                } else {
                    // Frame was filtered out
                    stats = CaptureStatistics(
                        totalFramesCaptured: totalFrames,
                        framesDeduped: stats.framesDeduped + 1,
                        averageFrameSizeBytes: Int(totalBytes / Int64(totalFrames)),
                        captureStartTime: stats.captureStartTime,
                        lastFrameTime: stats.lastFrameTime
                    )

                    Log.info("Frame deduplicated (similarity: \(String(format: "%.2f%%", similarity * 100)), threshold: \(String(format: "%.2f%%", currentConfig.deduplicationThreshold * 100)))", category: .capture)
                }
            } else {
                // No deduplication - pass through all frames
                let enrichedFrame = await enrich(frame)
                guard !Task.isCancelled else { break }
                output.yield(enrichedFrame)

                stats = CaptureStatistics(
                    totalFramesCaptured: totalFrames,
                    framesDeduped: 0,
                    averageFrameSizeBytes: Int(totalBytes / Int64(totalFrames)),
                    captureStartTime: stats.captureStartTime,
                    lastFrameTime: enrichedFrame.timestamp
                )
            }
        }

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
