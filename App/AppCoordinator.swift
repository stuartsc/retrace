import Foundation
import Shared
import Database
import Storage
import Capture
import Processing
import Search
import Migration
import CoreGraphics
import ImageIO

enum AudioPipelineBufferPolicy {
    static let bridgeSampleLimit = 12_000

    static func makeStream(
        limit: Int = bridgeSampleLimit
    ) -> (stream: AsyncStream<CapturedAudio>, continuation: AsyncStream<CapturedAudio>.Continuation) {
        AsyncStream<CapturedAudio>.makeStream(
            of: CapturedAudio.self,
            bufferingPolicy: .bufferingNewest(limit)
        )
    }
}

enum VideoSegmentSizingPolicy {
    static let defaultMaxFramesPerSegment = 150
    static let minimumMaxFramesPerSegment = 24
    static let bytesPerPixel = 4
    static let activeWALBudgetBytes: Int64 = 2 * 1024 * 1024 * 1024

    static func maxFramesPerSegment(width: Int, height: Int) -> Int {
        let rawBytesPerFrame = estimatedRawBytes(width: width, height: height, frames: 1)
        guard rawBytesPerFrame > 0 else {
            return defaultMaxFramesPerSegment
        }

        let budgetedFrames = Int(activeWALBudgetBytes / rawBytesPerFrame)
        return min(
            defaultMaxFramesPerSegment,
            max(minimumMaxFramesPerSegment, budgetedFrames)
        )
    }

    static func estimatedRawBytes(width: Int, height: Int, frames: Int) -> Int64 {
        guard width > 0, height > 0, frames > 0 else { return 0 }
        return Int64(width) * Int64(height) * Int64(bytesPerPixel) * Int64(frames)
    }
}

enum FrameReadinessPolicy {
    static func shouldMarkReadableAfterWALRegistration(_ didRegisterWALMapping: Bool) -> Bool {
        didRegisterWALMapping
    }

    static func shouldBufferUntilVideoFlush(didRegisterWALMapping: Bool) -> Bool {
        !didRegisterWALMapping
    }
}

enum LiveFrameReadSource: Equatable {
    case activeWAL
    case video
}

enum LiveFrameReadPolicy {
    static func orderedSources(
        frameSource: FrameSource,
        isVideoFinalized: Bool
    ) -> [LiveFrameReadSource] {
        guard frameSource == .native else { return [.video] }
        return isVideoFinalized ? [.video, .activeWAL] : [.activeWAL, .video]
    }
}

enum PipelineStopReason: Sendable {
    case normal
    case unexpectedScreenCaptureStop
}

struct PipelineStopTeardownPlan: Equatable, Sendable {
    let stopScreenCapture: Bool
    let stopAudioCapture: Bool
    let cancelPipelineTasks: Bool
    let cancelRefinementLoop: Bool
    let persistStoppedRecordingState: Bool
}

enum PipelineStopTeardownPolicy {
    static func plan(
        for reason: PipelineStopReason,
        persistState: Bool
    ) -> PipelineStopTeardownPlan {
        PipelineStopTeardownPlan(
            stopScreenCapture: reason != .unexpectedScreenCaptureStop,
            stopAudioCapture: true,
            cancelPipelineTasks: true,
            cancelRefinementLoop: true,
            persistStoppedRecordingState: persistState
        )
    }
}

// MARK: - OCR Power Settings Notifications

public enum OCRPowerSettingsNotification {
    public static let didChange = Notification.Name("PowerSettingsDidChange")
}

/// Snapshot of OCR power settings, used to apply settings immediately without
/// relying on asynchronous UserDefaults propagation.
public struct OCRPowerSettingsSnapshot: Sendable {
    public let ocrEnabled: Bool
    public let pauseOnBattery: Bool
    public let pauseOnLowPowerMode: Bool
    public let processingLevel: Int
    public let appFilterModeRaw: String
    public let filteredAppsJSON: String

    public init(
        ocrEnabled: Bool,
        pauseOnBattery: Bool,
        pauseOnLowPowerMode: Bool,
        processingLevel: Int,
        appFilterModeRaw: String,
        filteredAppsJSON: String
    ) {
        self.ocrEnabled = ocrEnabled
        self.pauseOnBattery = pauseOnBattery
        self.pauseOnLowPowerMode = pauseOnLowPowerMode
        self.processingLevel = processingLevel
        self.appFilterModeRaw = appFilterModeRaw
        self.filteredAppsJSON = filteredAppsJSON
    }

    public static func fromDefaults(
        _ defaults: UserDefaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
    ) -> OCRPowerSettingsSnapshot {
        OCRPowerSettingsSnapshot(
            ocrEnabled: defaults.object(forKey: "ocrEnabled") as? Bool ?? true,
            pauseOnBattery: defaults.bool(forKey: "ocrOnlyWhenPluggedIn"),
            pauseOnLowPowerMode: defaults.bool(forKey: "ocrPauseInLowPowerMode"),
            processingLevel: (defaults.object(forKey: "ocrProcessingLevel") as? NSNumber)?.intValue ?? 3,
            appFilterModeRaw: defaults.string(forKey: "ocrAppFilterMode") ?? "all",
            filteredAppsJSON: defaults.string(forKey: "ocrFilteredApps") ?? ""
        )
    }
}

// MARK: - Thread-Safe Status Holder

/// Thread-safe holder for pipeline status that can be read without actor isolation.
/// This prevents task pile-up when UI polls for status while the actor is busy.
public final class PipelineStatusHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _isRunning = false
    private var _framesProcessed = 0
    private var _errors = 0
    private var _startTime: Date?

    // Diagnostics for UI responsiveness tracking
    private var _pendingActorRequests = 0
    private var _maxPendingRequests = 0
    private var _slowResponseCount = 0
    private var _lastActorResponseTime: Date?

    public var status: PipelineStatus {
        lock.lock()
        defer { lock.unlock() }
        return PipelineStatus(
            isRunning: _isRunning,
            framesProcessed: _framesProcessed,
            errors: _errors,
            startTime: _startTime
        )
    }

    /// Diagnostics about actor responsiveness (for detecting potential UI freeze conditions)
    public var diagnostics: (pendingRequests: Int, maxPending: Int, slowResponses: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (_pendingActorRequests, _maxPendingRequests, _slowResponseCount)
    }

    func update(isRunning: Bool? = nil, framesProcessed: Int? = nil, errors: Int? = nil, startTime: Date?? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let isRunning = isRunning { _isRunning = isRunning }
        if let framesProcessed = framesProcessed { _framesProcessed = framesProcessed }
        if let errors = errors { _errors = errors }
        if let startTime = startTime { _startTime = startTime }
    }

    func incrementFrames() {
        lock.lock()
        defer { lock.unlock() }
        _framesProcessed += 1
    }

    func incrementErrors() {
        lock.lock()
        defer { lock.unlock() }
        _errors += 1
    }

    /// Track when an actor request starts (call before await)
    public func trackActorRequestStart() {
        lock.lock()
        defer { lock.unlock() }
        _pendingActorRequests += 1
        if _pendingActorRequests > _maxPendingRequests {
            _maxPendingRequests = _pendingActorRequests
        }
    }

    /// Track when an actor request completes (call after await returns)
    public func trackActorRequestEnd(startTime: Date) {
        lock.lock()
        defer { lock.unlock() }
        _pendingActorRequests = max(0, _pendingActorRequests - 1)
        _lastActorResponseTime = Date()

        // Track slow responses (> 100ms is concerning for UI)
        let elapsed = Date().timeIntervalSince(startTime)
        if elapsed > 0.1 {
            _slowResponseCount += 1
        }
    }

    /// Reset diagnostic counters (call periodically, e.g., every hour)
    public func resetDiagnostics() {
        lock.lock()
        defer { lock.unlock() }
        _maxPendingRequests = _pendingActorRequests
        _slowResponseCount = 0
    }
}

/// Main coordinator that wires all modules together
/// Implements the core data pipeline: Capture → Storage → Processing → Database → Search
/// Owner: APP integration
public actor AppCoordinator {
    private static let manualBackfillBatchLimit = 25
    static let startupOCRNodeTextBackfillBatchLimit = 25
    static let startupOCRNodeTextBackfillQueueCapacity = 25
    static let startupOCRNodeTextBackfillPriority = -5
    private static let manualPass2BatchLimit = 25
    private static let manualPass3BatchLimit = 10
    private static let automaticBackfillBatchLimit = 10
    private static let automaticPass2BatchLimit = 10
    private static let automaticPass3BatchLimit = 5

    static func shouldStartAutomaticRefinementLoop(
        defaultsValue: Bool?,
        environmentValue: String?
    ) -> Bool {
        if let environmentValue {
            switch environmentValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                break
            }
        }

        return defaultsValue ?? false
    }

    private static func shouldStartAutomaticRefinementLoop() -> Bool {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        return shouldStartAutomaticRefinementLoop(
            defaultsValue: defaults.object(forKey: "automaticAudioRefinementEnabled") as? Bool,
            environmentValue: ProcessInfo.processInfo.environment["RETRACE_AUTOMATIC_REFINEMENT_LOOP"]
        )
    }

    public struct SegmentCommentCreateResult: Sendable {
        public let comment: SegmentComment
        public let linkedSegmentIDs: [SegmentID]
        public let skippedSegmentIDs: [SegmentID]
        public let failedSegmentIDs: [SegmentID]

        public init(
            comment: SegmentComment,
            linkedSegmentIDs: [SegmentID],
            skippedSegmentIDs: [SegmentID],
            failedSegmentIDs: [SegmentID]
        ) {
            self.comment = comment
            self.linkedSegmentIDs = linkedSegmentIDs
            self.skippedSegmentIDs = skippedSegmentIDs
            self.failedSegmentIDs = failedSegmentIDs
        }
    }

    // MARK: - Properties

    private let services: ServiceContainer
    private var activityMonitor: ActivityMonitor?
    private var recallService: ProgressiveRecallService?
    private let recordingLifecycle = RecordingLifecycle()
    private var masterCaptureRequested = false
    private var captureTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var refinementLoopTask: Task<Void, Never>?
    private var legacyOCRNodeTextMaintenanceTask: Task<Void, Never>?
    private var isRunning = false
    /// Writer ownership exists before its first WAL append, so filesystem
    /// enumeration alone cannot determine whether a video is orphaned.
    private var liveVideoWriterPaths: Set<String> = []

    // Statistics
    private var pipelineStartTime: Date?
    private var totalFramesProcessed = 0
    private var totalErrors = 0

    /// Thread-safe status holder for UI polling without actor hop
    public nonisolated let statusHolder = PipelineStatusHolder()

    // Segment tracking (app focus sessions - Rewind compatible)
    private var currentSegmentID: Int64?

    private var lastSegmentContext: ActivityContext?
    private var lastFrameTimestamp: Date?

    // Timeline visibility tracking - pause capture when timeline is open
    private var isTimelineVisible = false

    // Signal to flush pending frames to the OCR queue
    private var shouldFlushPendingFrames = false

    // Permission monitoring - stops recording gracefully if permissions are revoked
    private var permissionMonitorSetup = false

    // Storage health notifications (volume mount, used to trigger cache validation)
    private var storageHealthObserverTokens: [NSObjectProtocol] = []

    // Periodic task to finalize orphaned videos (processingState stuck at 1)
    private var orphanedVideoCleanupTask: Task<Void, Never>?
    private var startupRecoveryTask: Task<Void, Never>?
    private static let pipelineMemoryLogInterval: TimeInterval = 5.0

    // MARK: - Initialization

    public init(services: ServiceContainer) {
        self.services = services
        Log.info("AppCoordinator created", category: .app)
    }

    /// Convenience initializer with default configuration
    public init() {
        self.services = ServiceContainer()
        Log.info("AppCoordinator created with default services", category: .app)
    }

    // MARK: - Public Accessors

    nonisolated public var onboardingManager: OnboardingManager {
        services.onboardingManager
    }

    nonisolated public var modelManager: ModelManager {
        services.modelManager
    }

    public func getAudioBackfill() async -> AudioBackfillManager? {
        await services.audioBackfill
    }

    /// Status of a refinement run
    public struct RefinementRunStatus: Sendable {
        public let backfillProcessed: Int
        public let pass2Refined: Int
        public let pass3Refined: Int
        public let totalSentencesAffected: Int
    }

    public struct AudioHistoryRepairStatus: Sendable {
        public let markedForRepair: Int
        public let backfillProcessed: Int
        public let pass2Refined: Int
        public let pass3Refined: Int
        public let totalSentencesAffected: Int
    }

    /// Manually trigger a full refinement cycle now (ignores schedule).
    /// Safe to call multiple times — individual managers have isRunning guards.
    public func triggerRefinementNow() async -> RefinementRunStatus {
        Log.info("[AppCoordinator] Manual refinement triggered", category: .app)

        var backfillProcessed = 0
        var pass2Refined = 0
        var pass3Refined = 0
        var totalSentences = 0

        if let backfill = await services.audioBackfill {
            let result = await backfill.processAllPendingBatches(maxBatches: Self.manualBackfillBatchLimit)
            backfillProcessed = result.processedCount
            totalSentences += result.totalSentences
            Log.info("[AppCoordinator] Manual backfill: \(result.processedCount) transcribed, \(result.totalSentences) sentences", category: .app)
        }

        if let refinement = await services.audioRefinement {
            let result = await refinement.processAllPendingRefinements(maxBatches: Self.manualPass2BatchLimit)
            pass2Refined = result.refinedCount
            totalSentences += result.totalSentences
            Log.info("[AppCoordinator] Manual pass-2: \(result.refinedCount) refined", category: .app)
        }

        if let contextual = await services.audioContextualRefinement {
            let result = await contextual.processAllPendingRefinements(
                runMode: .manual,
                maxBatches: Self.manualPass3BatchLimit
            )
            pass3Refined = result.refinedCount
            totalSentences += result.totalSentences
            Log.info("[AppCoordinator] Manual pass-3: \(result.refinedCount) refined", category: .app)
        }

        return RefinementRunStatus(
            backfillProcessed: backfillProcessed,
            pass2Refined: pass2Refined,
            pass3Refined: pass3Refined,
            totalSentencesAffected: totalSentences
        )
    }

    /// Mark historical placeholder batches in a bounded range as pending, then run the full
    /// repair/refinement cycle. This replaces ad-hoc DB resets for old [silence]/[hallucination] rows.
    public func repairAudioHistory(from startDate: Date, to endDate: Date, limit: Int = 500) async -> AudioHistoryRepairStatus {
        let metadata = "from=\(Int(startDate.timeIntervalSince1970));to=\(Int(endDate.timeIntervalSince1970));limit=\(limit)"
        try? await recordMetricEvent(metricType: .audioHistoryRepairStarted, metadata: metadata)

        var markedForRepair = 0
        if let db = await services.database.getConnection() {
            let queries = AudioTranscriptionQueries(db: db)
            do {
                markedForRepair = try await queries.markHistoricalPlaceholdersPendingForRepair(
                    from: startDate,
                    to: endDate,
                    limit: limit
                )
                Log.info("[AppCoordinator] Audio history repair marked \(markedForRepair) batch(es)", category: .app)
            } catch {
                Log.error("[AppCoordinator] Audio history repair marking failed", category: .app, error: error)
            }
        }

        let refinement = await triggerRefinementNow()
        let result = AudioHistoryRepairStatus(
            markedForRepair: markedForRepair,
            backfillProcessed: refinement.backfillProcessed,
            pass2Refined: refinement.pass2Refined,
            pass3Refined: refinement.pass3Refined,
            totalSentencesAffected: refinement.totalSentencesAffected
        )

        let completionMetadata = "\(metadata);marked=\(markedForRepair);backfill=\(result.backfillProcessed);pass2=\(result.pass2Refined);pass3=\(result.pass3Refined);sentences=\(result.totalSentencesAffected)"
        try? await recordMetricEvent(metricType: .audioHistoryRepairCompleted, metadata: completionMetadata)
        return result
    }

    public func getAudioTranscriptionQueries() async -> AudioTranscriptionQueries? {
        guard let db = await services.database.getConnection() else { return nil }
        return AudioTranscriptionQueries(db: db)
    }

    /// The same configured directory used by the audio writer, including custom storage locations.
    public func getAudioStorageDirectory() async -> URL {
        await services.storage.getStorageDirectory()
    }

    // MARK: - Dictation

    @discardableResult
    public func beginDictation() async -> UUID {
        let context = await MainActor.run {
            DictationTargetContextProvider.current()
        }
        let id = await services.dictation.beginDictation(targetContext: context)
        try? await recordMetricEvent(metricType: .dictationStarted, metadata: context?.bundleID)
        return id
    }

    public func endDictation() async -> DictationSession? {
        do {
            let context = await MainActor.run {
                DictationTargetContextProvider.current()
            }
            let session = try await services.dictation.endDictation(
                currentTargetContext: context,
                validateInsertionTarget: true
            )
            try? await recordMetricEvent(metricType: .dictationCompleted, metadata: session.status.rawValue)

            switch session.status {
            case .inserted:
                let metadata = [
                    session.targetContext?.bundleID,
                    session.targetContext?.appName
                ].compactMap { $0 }.joined(separator: "|")
                try? await recordMetricEvent(metricType: .dictationInserted, metadata: metadata.isEmpty ? nil : metadata)
            case .cancelled:
                try? await recordMetricEvent(metricType: .dictationCancelled)
            case .failed, .blockedSecureInput, .blockedFocusChanged:
                try? await recordMetricEvent(
                    metricType: .dictationFailed,
                    metadata: session.errorMessage ?? session.status.rawValue
                )
            case .capturing, .transcribing, .empty:
                break
            }

            return session
        } catch {
            try? await recordMetricEvent(metricType: .dictationFailed, metadata: error.localizedDescription)
            Log.error("[AppCoordinator] Dictation end failed", category: .app, error: error)
            return nil
        }
    }

    public func getRecentDictationSessions(limit: Int = 10, offset: Int = 0) async throws -> [DictationSession] {
        guard let db = await services.database.getConnection() else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try await DictationSessionQueries(db: db).getRecentSessions(limit: limit, offset: offset)
    }

    public func getDictationConfig() async -> DictationConfig {
        let config = await services.dictation.getConfig()
        let persistedShortcut = await services.onboardingManager.dictationShortcut
        guard config.shortcut != persistedShortcut else {
            return config
        }

        let mergedConfig = DictationConfig(
            isEnabled: config.isEnabled,
            shortcut: persistedShortcut,
            preRollSeconds: config.preRollSeconds,
            postRollSeconds: config.postRollSeconds,
            restoreClipboardDelaySeconds: config.restoreClipboardDelaySeconds,
            insertionMethod: config.insertionMethod
        )
        await services.dictation.updateConfig(mergedConfig)
        return mergedConfig
    }

    public func updateDictationConfig(_ config: DictationConfig) async {
        await services.dictation.updateConfig(config)
        await services.onboardingManager.setDictationShortcut(config.shortcut)
        try? await recordMetricEvent(metricType: .dictationSettingsChanged, metadata: config.shortcut.displayString)
    }

    /// Get current capture configuration
    public func getCaptureConfig() async -> CaptureConfig {
        await services.capture.getConfig()
    }

    /// Update capture configuration
    public func updateCaptureConfig(_ config: CaptureConfig) async throws {
        try await services.capture.updateConfig(config)
        await activityMonitor?.configurationChanged()
        try? await services.database.recordMetricEvent(metricType: .progressiveRecallAction,
            metadata: "{\"action\":\"captureSettingChanged\",\"count\":1,\"outcome\":\"success\"}")
    }

    public func activityMonitorHealth() async -> ActivityMonitorHealth? { await activityMonitor?.health() }

    public func isActivityContextEnabled() -> Bool {
        Self.userDefaultsSuite.bool(forKey: "activityContextEnabled")
    }

    /// Independent opt-in for future context collection. Master pause still applies.
    public func setActivityContextEnabled(_ enabled: Bool) async {
        Self.userDefaultsSuite.set(enabled, forKey: "activityContextEnabled")
        if enabled && masterCaptureRequested {
            let permitted = await services.capture.hasPermission()
            if permitted && isActivityContextEnabled() && masterCaptureRequested {
                await independentActivityMonitor().start()
                if !isActivityContextEnabled() || !masterCaptureRequested { await activityMonitor?.stop() }
            }
        } else {
            await activityMonitor?.stop()
        }
        try? await services.database.recordMetricEvent(metricType: .progressiveRecallAction,
            metadata: "{\"action\":\"captureSettingChanged\",\"count\":1,\"outcome\":\"success\"}")
    }

    public func progressiveRecallHealth() async -> ProgressiveRecallStageHealth {
        let monitor = await activityMonitor?.health()
        let activity = try? await services.database.activityHealth()
        let capture = await services.capture.getStatistics()
        let queue = await getQueueStatistics()
        let adapter = await services.dataAdapter
        let retained = try? await adapter?.getMostRecentFrameTimestamp()
        let oldest = try? await adapter?.oldestPendingTextAt()
        let audio = await services.audioProcessing.getStatistics()
        return ProgressiveRecallStageHealth(contextEnabled: isActivityContextEnabled(), collecting: monitor?.collecting ?? false,
            degraded: (monitor?.degraded ?? false) || activity == nil, activity: activity,
            imageAdmittedAt: capture.lastFrameTime, imageRetainedAt: retained,
            deduplicatedImages: capture.framesDeduped, pendingText: queue?.pendingCount,
            processingText: queue?.processingCount, failedText: queue?.totalFailed,
            oldestPendingTextAt: oldest, audioProcessedAt: audio.lastProcessedAt,
            audioTranscriptions: audio.totalTranscriptionsGenerated)
    }

    public func progressiveRecall() async throws -> ProgressiveRecallService {
        if let service = recallService { return service }
        guard let adapter = await services.dataAdapter else { throw DataAdapterError.notInitialized }
        // Actor reentrancy may have created the service during the adapter await.
        if let service = recallService { return service }
        let capture = services.capture
        let service = ProgressiveRecallService(database: services.database, adapter: adapter,
            configuration: { await capture.getConfig() }, imageReader: { [weak self] frame in
                guard let self else { throw EvidenceUnavailableReason.recordingMissing }
                return try await self.exactEvidenceImage(frame)
            })
        recallService = service
        return service
    }

    private func exactEvidenceImage(_ item: FrameWithVideoInfo) async throws -> CGImage {
        guard let adapter = await services.dataAdapter else { throw EvidenceUnavailableReason.sourceDisconnected }
        let url = try await adapter.resolveEvidenceVideoURL(item)
        guard let video = item.videoInfo, let width = video.width, let height = video.height,
              width > 0, height > 0 else { throw EvidenceUnavailableReason.frameFinalising }
        do {
            if item.frame.source == .native && !video.isVideoFinalized {
                let wal = await services.storage.getWALManager()
                let raw = try await wal.readExactFrame(videoID: activeWALSegmentID(from: video.videoPath),
                    frameID: item.frame.id.value, expectedTimestamp: item.frame.timestamp,
                    expectedWidth: width, expectedHeight: height, expectedDisplayID: item.frame.metadata.displayID)
                return try cgImage(fromRawBGRAFrame: raw)
            }
            return try await ExactFrameReader.readFrame(videoURL: url, frameIndex: video.frameIndex,
                frameRate: video.frameRate, expectedWidth: width, expectedHeight: height)
        } catch let error as ExactFrameReadError {
            switch error {
            case .recordingMissing: throw EvidenceUnavailableReason.recordingMissing
            case .frameFinalising: throw EvidenceUnavailableReason.frameFinalising
            case .integrityFailure, .cancelled: throw EvidenceUnavailableReason.integrityFailure
            }
        }
    }

    private func independentActivityMonitor() -> ActivityMonitor {
        if let monitor = activityMonitor { return monitor }
        let capture = services.capture
        let monitor = ActivityMonitor(store: services.database, configuration: { await capture.getConfig() })
        activityMonitor = monitor
        return monitor
    }

    // MARK: - Timeline Visibility

    /// Set whether the timeline is currently visible (pauses frame processing when true)
    public func setTimelineVisible(_ visible: Bool) {
        isTimelineVisible = visible
        // When timeline becomes visible, signal to flush any buffered frames to OCR queue
        if visible {
            shouldFlushPendingFrames = true
        }
        Log.info("Timeline visibility changed: \(visible) - frame processing \(visible ? "paused" : "resumed")", category: .app)
    }

    // MARK: - Lifecycle

    /// Keep startup recovery and worker activation in one owned lifecycle task.
    func startFrameProcessingAfterRecovery(_ recover: @escaping @Sendable () async throws -> Void) {
        guard startupRecoveryTask == nil else { return }
        startupRecoveryTask = Task {
            do {
                try await recover()
            } catch is CancellationError {
                return
            } catch {
                Log.error("[AppCoordinator] Background crash recovery failed", category: .app, error: error)
            }
            guard !Task.isCancelled else { return }
            if let queue = await services.processingQueue {
                await queue.startWorkers()
                Log.info("✓ Processing queue workers started after startup recovery", category: .app)
            }
            startLegacyOCRNodeTextMaintenance()
        }
    }

    /// Initialize all services
    public func initialize() async throws {
        Log.info("Initializing AppCoordinator...", category: .app)
        try await services.initialize()

        Log.info("AppCoordinator initialized successfully", category: .app)

        // Configure the stopped queue before recovery; power updates cannot start
        // or restart workers until startup recovery releases existing claims.
        await applyPowerSettings()
        startFrameProcessingAfterRecovery { [self] in
            try await recoverFromCrash()
        }

        // Start periodic orphaned video cleanup (runs every 60s)
        startOrphanedVideoCleanup()

        // Log auto-start state for debugging
        let shouldAutoStart = Self.shouldAutoStartRecording()
        Log.info("Auto-start recording check: shouldAutoStartRecording=\(shouldAutoStart)", category: .app)
    }

    /// Recover frames from write-ahead log (WAL) after a crash
    private func recoverFromCrash() async throws {
        try Task.checkCancellation()
        // Skip crash recovery during first launch (onboarding) - there's nothing to recover
        // and the database may not be fully ready yet
        guard await services.onboardingManager.hasCompletedOnboarding else {
            Log.info("Skipping crash recovery during onboarding (first launch)", category: .app)
            return
        }

        Log.info("Checking for crash recovery...", category: .app)

        // Cast to concrete StorageManager to access WAL
        guard let storageManager = services.storage as? StorageManager else {
            Log.warning("Storage not using WAL-enabled StorageManager, skipping recovery", category: .app)
            return
        }

        let walManager = await storageManager.getWALManager()
        let recoveryManager = RecoveryManager(
            walManager: walManager,
            storage: services.storage,
            database: services.database,
            processing: services.processing,
            search: services.search
        )

        // Set callback for enqueueing recovered frames
        if let queue = await services.processingQueue {
            await recoveryManager.setFrameEnqueueCallback { frameIDs in
                try await queue.enqueueBatch(frameIDs: frameIDs)
            }
        }

        let result = try await recoveryManager.recoverAll()
        try Task.checkCancellation()

        // Finalize any orphaned videos (processingState=1 but no active WAL session)
        // This cleans up videos left unfinalised due to dev restarts or crashes
        let orphanedVideosFinalized = try await finalizeOrphanedVideoSnapshot {
            try await walManager.listActiveSessions()
        }
        if orphanedVideosFinalized > 0 {
            Log.warning("[Recovery] Finalized \(orphanedVideosFinalized) orphaned videos (processingState was stuck at 1)", category: .app)
        }

        // Re-enqueue frames that were processing during crash
        try Task.checkCancellation()
        if let queue = await services.processingQueue {
            try await queue.requeueCrashedFrames()
        }

        if result.sessionsRecovered > 0 {
            Log.warning("Crash recovery completed: \(result.sessionsRecovered) sessions, \(result.framesRecovered) frames recovered", category: .app)
        } else {
            Log.info("No crash recovery needed", category: .app)
        }

        // Re-enqueue orphaned frames (processingStatus=0 but not in queue)
        // These are frames that were captured but never enqueued due to app restart
        try await reEnqueueOrphanedFrames()
    }

    /// Re-enqueue frames that have processingStatus=0 but are not in the processing queue
    /// This happens when the app restarts before buffered frames were enqueued
    private func reEnqueueOrphanedFrames() async throws {
        try Task.checkCancellation()
        guard let queue = await services.processingQueue else {
            Log.warning("[ORPHAN-RECOVERY] Processing queue not available", category: .app)
            return
        }

        do {
            let orphanedCount = try await services.database.countPendingFramesNotInQueue()
            if orphanedCount == 0 {
                Log.info("[ORPHAN-RECOVERY] No orphaned frames found", category: .app)
                return
            }

            Log.info("[ORPHAN-RECOVERY] Found \(orphanedCount) orphaned frames (pending but not in queue)", category: .app)

            // Process in batches to avoid memory issues
            let batchSize = 500
            var totalEnqueued = 0

            while true {
                try Task.checkCancellation()
                let frameIDs = try await services.database.getPendingFrameIDsNotInQueue(limit: batchSize)
                if frameIDs.isEmpty {
                    break
                }

                for frameID in frameIDs {
                    try Task.checkCancellation()
                    // Enqueue without frame data (will extract from video)
                    try await queue.enqueue(frameID: frameID, priority: -1) // Low priority so new frames process first
                }

                totalEnqueued += frameIDs.count
                Log.info("[ORPHAN-RECOVERY] Enqueued batch of \(frameIDs.count) frames (total: \(totalEnqueued)/\(orphanedCount))", category: .app)

                // Small delay between batches to avoid overwhelming the queue
                try await Task.sleep(for: .milliseconds(100), clock: .continuous)
            }

            Log.info("[ORPHAN-RECOVERY] Completed - enqueued \(totalEnqueued) orphaned frames for OCR processing", category: .app)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.error("[ORPHAN-RECOVERY] Failed to re-enqueue orphaned frames", category: .app, error: error)
        }
    }

    /// Register Rewind data source if enabled
    /// Should be called after onboarding completes if user opted in
    public func registerRewindSourceIfEnabled() async throws {
        try await services.registerRewindSourceIfEnabled()
    }

    /// Set Rewind data source enabled/disabled
    /// Updates UserDefaults and connects/disconnects the data source immediately
    public func setRewindSourceEnabled(_ enabled: Bool) async {
        await services.setRewindSourceEnabled(enabled)
    }

    /// Setup callback for accessibility permission warnings
    public func setupAccessibilityWarningCallback(_ callback: @escaping @Sendable () -> Void) async {
        services.capture.onAccessibilityPermissionWarning = callback
    }

    // MARK: - Recording State Persistence

    private static let recordingStateKey = "shouldAutoStartRecording"
    /// Use a fixed suite name so it works regardless of how the app is launched (swift build vs .app bundle)
    private static let userDefaultsSuite = UserDefaults(suiteName: "io.retrace.app") ?? .standard

    /// Save recording state to UserDefaults for persistence across app restarts
    private nonisolated func saveRecordingState(_ isRecording: Bool) {
        Self.userDefaultsSuite.set(isRecording, forKey: Self.recordingStateKey)
        Self.userDefaultsSuite.synchronize()  // Force immediate write to disk
        Log.debug("[AppCoordinator] saveRecordingState(\(isRecording)) - saved to UserDefaults", category: .app)
    }

    /// Check if recording should auto-start based on previous state
    public nonisolated static func shouldAutoStartRecording() -> Bool {
        let value = userDefaultsSuite.bool(forKey: recordingStateKey)
        Log.debug("[AppCoordinator] shouldAutoStartRecording() checking key '\(recordingStateKey)' in suite 'Retrace' = \(value)", category: .app)
        return value
    }

    /// Start the capture pipeline
    public func startPipeline() async throws {
        try await recordingLifecycle.start(operation: { try await self.startPipelineNow() },
            rollback: { await self.rollbackPipelineStartup() })
    }

    private func startPipelineNow() async throws {
        try Task.checkCancellation()
        guard !isRunning else {
            Log.warning("Pipeline already running", category: .app)
            return
        }

        Log.info("Starting capture pipeline...", category: .app)
        masterCaptureRequested = true

        // Check permissions first
        guard await services.capture.hasPermission() else {
            Log.error("Screen recording permission not granted", category: .app)
            throw AppError.permissionDenied(permission: "screen recording")
        }

        try Task.checkCancellation()
        if isActivityContextEnabled() { await independentActivityMonitor().start() }
        // Activity persistence is independent of optional audio model readiness.
        await ensureWhisperModel()
        try Task.checkCancellation()

        // Set up callback for when capture stops unexpectedly (e.g., user clicks "Stop sharing")
        services.capture.onCaptureStopped = { [weak self] in
            guard let self = self else { return }
            await self.handleCaptureStopped()
        }

        // Start screen capture
        try await services.capture.startUsingCurrentConfiguration()
        try Task.checkCancellation()

        // Start permission monitoring to detect if user revokes permissions while recording
        await startPermissionMonitoring()
        try Task.checkCancellation()

        // Start audio capture
        do {
            let audioConfig = AudioCaptureConfig.default
            try await services.audioCapture.startCapture(config: audioConfig)
            Log.info("Audio capture started", category: .app)
        } catch {
            Log.warning("Audio capture failed to start: \(error)", category: .app)
        }
        try Task.checkCancellation()

        // Start processing pipelines
        isRunning = true
        pipelineStartTime = Date()
        statusHolder.update(isRunning: true, startTime: pipelineStartTime)
        captureTask = Task {
            await runPipeline()
        }
        audioTask = Task {
            await runAudioPipeline()
        }

        if Self.shouldStartAutomaticRefinementLoop() {
            // Continuous refinement pipeline: backfill -> pass-2 -> pass-3, looping every 10 minutes.
            refinementLoopTask?.cancel()
            refinementLoopTask = Task.detached(priority: .background) { [services] in
                let cycleInterval: Duration = .seconds(10 * 60)

                // ONCE: Reset records from older pipeline versions so they get re-refined with current logic
                if let db = await services.database.getConnection() {
                    let queries = AudioTranscriptionQueries(db: db)
                    do {
                        let staleCount = try await queries.countStalePipelineRecords()
                        if staleCount > 0 {
                            Log.info("Pipeline version check: \(staleCount) records from older pipeline version - resetting for re-processing", category: .app)
                            let result = try await queries.resetStalePipelineRecords()
                            Log.info("Pipeline version reset: \(result.resetCount) sentences reset to pass-1, \(result.resetWords) stale words reset", category: .app)
                        } else {
                            Log.debug("Pipeline version check: all records up to date", category: .app)
                        }
                    } catch {
                        Log.warning("Pipeline version check failed: \(error)", category: .app)
                    }
                }

                while !Task.isCancelled {
                    if let backfill = await services.audioBackfill {
                        let result = await backfill.processAllPendingBatches(maxBatches: Self.automaticBackfillBatchLimit)
                        if result.processedCount > 0 || result.silenceCount > 0 {
                            Log.info("Audio backfill complete: \(result.processedCount) transcribed, \(result.silenceCount) silence, \(result.totalSentences) sentences", category: .app)
                        }
                    }
                    if Task.isCancelled { break }

                    // Pass-2 refinement with turbo model.
                    if let refinement = await services.audioRefinement {
                        let result = await refinement.processAllPendingRefinements(maxBatches: Self.automaticPass2BatchLimit)
                        if result.refinedCount > 0 {
                            Log.info("Audio refinement (pass-2) complete: \(result.refinedCount) refined, \(result.totalSentences) sentences", category: .app)
                        }
                    }
                    if Task.isCancelled { break }

                    // Pass-3 contextual refinement (has internal idle gating).
                    if let contextual = await services.audioContextualRefinement {
                        let result = await contextual.processAllPendingRefinements(maxBatches: Self.automaticPass3BatchLimit)
                        if result.refinedCount > 0 {
                            Log.info("Contextual refinement (pass-3) complete: \(result.refinedCount) refined, \(result.totalSentences) sentences", category: .app)
                        }
                    }
                    if Task.isCancelled { break }

                    try? await Task.sleep(for: cycleInterval, clock: .continuous)
                }
                Log.info("Refinement loop stopped", category: .app)
            }
        } else {
            refinementLoopTask?.cancel()
            refinementLoopTask = nil
            Log.info("Automatic audio refinement loop disabled; use manual refinement to reprocess historical audio", category: .app)
        }

        // Save recording state for persistence across restarts
        saveRecordingState(true)

        // Start unified storage health monitoring (disk space, I/O latency, volume events, keep-alive)
        startStorageHealthNotifications()
        StorageHealthMonitor.shared.startMonitoring(
            storagePath: AppPaths.expandedStorageRoot,
            onCriticalError: { [weak self] in
                await self?.handleStorageCriticalError()
            }
        )

        Log.info("Capture pipeline started successfully", category: .app)
    }

    /// Stop the capture pipeline
    /// - Parameter persistState: If true, saves recording state as stopped. Set to false during shutdown
    ///   so the app remembers recording was active and auto-starts on next launch.
    public func stopPipeline(persistState: Bool = true) async throws {
        try await stopPipeline(persistState: persistState, reason: .normal)
    }

    private func stopPipeline(
        persistState: Bool,
        reason: PipelineStopReason
    ) async throws {
        try await recordingLifecycle.stop(onRequest: { await self.preparePipelineStop(reason: reason, persistState: persistState) },
            operation: { try await self.stopPipelineNow(persistState: persistState, reason: reason) })
    }

    private func preparePipelineStop(reason: PipelineStopReason, persistState: Bool) async {
        if reason == .normal {
            masterCaptureRequested = false
            if persistState { saveRecordingState(false) }
            await activityMonitor?.stop()
        }
    }

    private func rollbackPipelineStartup() async {
        masterCaptureRequested = false
        await activityMonitor?.stop()
        if isRunning {
            try? await stopPipelineNow(persistState: false, reason: .normal)
        } else {
            await stopPermissionMonitoring()
            try? await services.capture.stopCapture()
            try? await services.audioCapture.stopCapture()
        }
    }

    private func stopPipelineNow(persistState: Bool, reason: PipelineStopReason) async throws {
        guard isRunning else {
            if reason == .normal && persistState { saveRecordingState(false) }
            Log.warning("Pipeline not running", category: .app)
            return
        }

        let stopPlan = PipelineStopTeardownPolicy.plan(for: reason, persistState: persistState)
        Log.info("Stopping capture pipeline...", category: .app)

        // Stop permission monitoring
        await stopPermissionMonitoring()

        // Stop storage health monitoring
        StorageHealthMonitor.shared.stopMonitoring()
        stopStorageHealthNotifications()

        // Stop screen capture
        var screenStopError: Error?
        if stopPlan.stopScreenCapture {
            do { try await services.capture.stopCapture() }
            catch { screenStopError = error }
        }

        // Stop audio capture
        if stopPlan.stopAudioCapture {
            do {
                try await services.audioCapture.stopCapture()
            } catch {
                Log.warning("Audio capture stop failed: \(error)", category: .app)
            }
        }

        // Cancel pipeline tasks
        if stopPlan.cancelPipelineTasks {
            let endingTasks = [captureTask, audioTask].compactMap { $0 }
            // Final media/segment writes belong to this recording, and must finish
            // before the lifecycle gate permits a replacement recording to start.
            await RecordingLifecycle.cancelAndJoin(endingTasks)
            captureTask = nil
            audioTask = nil
        }
        if stopPlan.cancelRefinementLoop {
            refinementLoopTask?.cancel()
            refinementLoopTask = nil
        }

        // Wait for processing queue to drain
        await services.processing.waitForQueueDrain()
        // Audio processing drains automatically when stream ends

        isRunning = false
        statusHolder.update(isRunning: false)

        // Only save recording state as stopped if explicitly requested (user clicked stop)
        // During shutdown, we want to preserve the "recording" state so it auto-starts next launch
        if stopPlan.persistStoppedRecordingState {
            saveRecordingState(false)
        }

        if let screenStopError { throw screenStopError }
        Log.info("Capture pipeline stopped successfully", category: .app)
    }

    // MARK: - Whisper Model Management

    /// Ensure the whisper model is downloaded; if not, download it and upgrade from mock to real transcription
    private func ensureWhisperModel() async {
        // Check if model already exists
        if let _ = await services.modelManager.getWhisperModelPath() {
            // Model exists — upgrade transcription service if still using mock
            do {
                try await services.upgradeToRealTranscription()
            } catch {
                Log.warning("[AppCoordinator] Failed to upgrade transcription service: \(error)", category: .app)
            }
        } else {
            // Model missing — download it
            Log.info("[AppCoordinator] Whisper model not found, downloading (~465MB)...", category: .app)
            do {
                let _ = try await services.modelManager.downloadModel(ModelManager.whisperModel) { progress in
                    Log.debug("[AppCoordinator] Whisper download: \(Int(progress.percentage))%", category: .app)
                }
                Log.info("[AppCoordinator] Whisper model downloaded successfully", category: .app)
                try await services.upgradeToRealTranscription()
            } catch {
                Log.warning("[AppCoordinator] Failed to download whisper model (audio will be recorded but not transcribed): \(error)", category: .app)
            }
        }

        // Download turbo model in background for pass-2 refinement (non-blocking)
        if await services.modelManager.getWhisperTurboModelPath() == nil {
            Task {
                Log.info("[AppCoordinator] Whisper turbo model not found, downloading (~1.6GB) in background...", category: .app)
                do {
                    let _ = try await services.modelManager.downloadModel(ModelManager.whisperTurboModel) { progress in
                        if Int(progress.percentage) % 10 == 0 {
                            Log.debug("[AppCoordinator] Whisper turbo download: \(Int(progress.percentage))%", category: .app)
                        }
                    }
                    Log.info("[AppCoordinator] Whisper turbo model downloaded successfully", category: .app)
                    if try await services.installAudioRefinementManagersIfAvailable() {
                        Log.info("[AppCoordinator] Audio refinement managers installed after turbo download", category: .app)
                    }
                } catch {
                    Log.warning("[AppCoordinator] Failed to download turbo model (refinement will not be available): \(error)", category: .app)
                }
            }
        }
    }

    // MARK: - Storage Health Notifications

    private func startStorageHealthNotifications() {
        stopStorageHealthNotifications()

        let center = NotificationCenter.default
        let mounted = center.addObserver(forName: .storageVolumeMounted, object: nil, queue: .main) { [weak self] notification in
            Task { await self?.handleStorageVolumeMounted(notification) }
        }
        storageHealthObserverTokens.append(mounted)
    }

    private func stopStorageHealthNotifications() {
        let center = NotificationCenter.default
        for token in storageHealthObserverTokens {
            center.removeObserver(token)
        }
        storageHealthObserverTokens.removeAll()
    }

    private func handleStorageVolumeMounted(_ notification: Notification) async {
        Log.info("[AppCoordinator] Storage volume mounted - validating StorageManager caches", category: .app)
        await services.storage.validateCaches()
    }

    private func handleStorageCriticalError() async {
        Log.error("[AppCoordinator] Storage critical error - invalidating StorageManager caches and stopping pipeline", category: .app)
        await services.storage.invalidateAllCaches()
        try? await stopPipeline()
    }

    /// Fence future recording requests before awaiting termination work.
    public func prepareForShutdown() async {
        await recordingLifecycle.beginShutdown()
    }

    /// Shutdown all services
    public func shutdown() async throws {
        await prepareForShutdown()
        // Join cancelled device startup before closing its canonical database writer.
        try await stopPipeline(persistState: false)
        await activityMonitor?.stop(shutdown: true)
        // Join recovery before stopping services/closing SQLite. A cancelled
        // startup task must never start OCR workers after shutdown has begun.
        startupRecoveryTask?.cancel()
        legacyOCRNodeTextMaintenanceTask?.cancel()
        await startupRecoveryTask?.value
        startupRecoveryTask = nil
        await stopLegacyOCRNodeTextMaintenance()

        // Stop periodic cleanup tasks
        stopOrphanedVideoCleanup()

        Log.info("Shutting down AppCoordinator...", category: .app)
        try await services.shutdown()
        Log.info("AppCoordinator shutdown complete", category: .app)
    }

    // MARK: - Power Settings

    /// Apply power-aware OCR settings to the processing queue
    /// Called on startup, when settings change, and when power source changes
    public func applyPowerSettings() async {
        let snapshot = OCRPowerSettingsSnapshot.fromDefaults()
        await applyPowerSettings(snapshot: snapshot)
    }

    /// Apply power-aware OCR settings from an explicit snapshot.
    /// This path avoids races where UserDefaults writes are not immediately visible.
    public func applyPowerSettings(snapshot: OCRPowerSettingsSnapshot) async {
        let ocrEnabled = snapshot.ocrEnabled
        let pauseOnBattery = snapshot.pauseOnBattery
        let pauseOnLowPowerMode = snapshot.pauseOnLowPowerMode
        let processingLevel = min(max(snapshot.processingLevel, 1), 5)

        // Parse app filter mode and filtered apps
        let filterModeRaw = snapshot.appFilterModeRaw
        let filterMode = OCRAppFilterMode(rawValue: filterModeRaw) ?? .allApps

        var excludedBundleIDs: Set<String> = []
        var includedBundleIDs: Set<String> = []

        // ocrFilteredApps is stored as JSON array of {bundleID, name, iconPath} objects
        struct FilteredAppInfo: Codable {
            let bundleID: String
        }
        let appsString = snapshot.filteredAppsJSON
        Log.info("[AppCoordinator] Raw ocrFilteredApps from snapshot: '\(appsString)'", category: .app)
        Log.info("[AppCoordinator] Raw ocrAppFilterMode from snapshot: '\(filterModeRaw)'", category: .app)

        if !appsString.isEmpty,
           let data = appsString.data(using: .utf8),
           let apps = try? JSONDecoder().decode([FilteredAppInfo].self, from: data) {
            let bundleIDs = apps.map(\.bundleID)
            Log.info("[AppCoordinator] Parsed bundleIDs: \(bundleIDs)", category: .app)
            switch filterMode {
            case .allApps:
                Log.info("[AppCoordinator] Filter mode is allApps, not applying any filter", category: .app)
                break // No filtering
            case .onlyTheseApps:
                includedBundleIDs = Set(bundleIDs)
                Log.info("[AppCoordinator] Filter mode is onlyTheseApps, includedBundleIDs=\(includedBundleIDs)", category: .app)
            case .allExceptTheseApps:
                excludedBundleIDs = Set(bundleIDs)
                Log.info("[AppCoordinator] Filter mode is allExceptTheseApps, excludedBundleIDs=\(excludedBundleIDs)", category: .app)
            }
        } else {
            Log.info("[AppCoordinator] No filtered apps configured or failed to parse", category: .app)
        }

        // Get current power source
        let powerSource = PowerStateMonitor.shared.getCurrentPowerSource()
        let isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

        // Derive priority and OCR backfill rate from processing level.
        // Keep this single-worker by default: OCR is durable backlog work, while
        // capture/audio/dictation must remain responsive and memory-bounded.
        // Keep Vision work at utility or above: background QoS caused prolonged
        // native OCR stalls on-device. Lower levels still retain their FPS caps.
        // Level 1: Efficiency  - utility, 0.25 FPS, 1 worker
        // Level 2: Light       - utility, 0.5 FPS, 1 worker
        // Level 3: Balanced    - utility, 1 FPS, 1 worker
        // Level 4: Performance - medium, 1.5 FPS, 1 worker
        // Level 5: Max         - high, 2 FPS, 1 worker
        let taskPriority: TaskPriority
        let maxFPS: Double
        let workerCount: Int
        switch processingLevel {
        case 1:
            taskPriority = .utility; maxFPS = 0.25; workerCount = 1
        case 2:
            taskPriority = .utility; maxFPS = 0.5; workerCount = 1
        case 4:
            taskPriority = .medium; maxFPS = 1.5; workerCount = 1
        case 5:
            taskPriority = .high; maxFPS = 2.0; workerCount = 1
        default: // 3 = Balanced (default)
            taskPriority = .utility; maxFPS = 1.0; workerCount = 1
        }

        // Update processing config - always prefer background processing for VNRecognizeTextRequest
        let currentConfig = await services.processing.getConfig()
        let preferBackground = true
        if currentConfig.preferBackgroundProcessing != preferBackground {
            let updatedConfig = ProcessingConfig(
                accessibilityEnabled: currentConfig.accessibilityEnabled,
                ocrAccuracyLevel: currentConfig.ocrAccuracyLevel,
                recognitionLanguages: currentConfig.recognitionLanguages,
                minimumConfidence: currentConfig.minimumConfidence,
                preferBackgroundProcessing: preferBackground
            )
            await services.processing.updateConfig(updatedConfig)
        }

        // Apply to processing queue
        if let queue = await services.processingQueue {
            await queue.updatePowerConfig(
                ocrEnabled: ocrEnabled,
                pauseOnBattery: pauseOnBattery,
                pauseOnLowPowerMode: pauseOnLowPowerMode,
                isLowPowerModeEnabled: isLowPowerModeEnabled,
                currentPowerSource: powerSource,
                maxFPS: maxFPS,
                workerCount: workerCount,
                taskPriority: taskPriority,
                excludedBundleIDs: excludedBundleIDs,
                includedBundleIDs: includedBundleIDs
            )
        } else {
            Log.warning("[AppCoordinator] processingQueue is nil, cannot apply power config", category: .app)
        }

        Log.info(
            "[AppCoordinator] Applied power settings: ocrEnabled=\(ocrEnabled), level=\(processingLevel), workers=\(workerCount), priority=\(taskPriority), maxFPS=\(maxFPS), preferBgProcessing=\(preferBackground), pauseOnBattery=\(pauseOnBattery), pauseOnLowPowerMode=\(pauseOnLowPowerMode), isLowPowerModeEnabled=\(isLowPowerModeEnabled), power=\(powerSource)",
            category: .app
        )
    }

    /// Handle capture stopped unexpectedly (e.g., user clicked "Stop sharing" in macOS)
    private func handleCaptureStopped() async {
        guard isRunning else { return }

        Log.info("Capture stopped unexpectedly, cleaning up pipeline...", category: .app)

        do {
            try await stopPipeline(persistState: true, reason: .unexpectedScreenCaptureStop)
            Log.info("Pipeline cleanup complete after unexpected stop", category: .app)
        } catch {
            Log.error("Pipeline cleanup failed after unexpected stop: \(error)", category: .app)
        }
    }

    // MARK: - Storage Health (delegated to StorageHealthMonitor)
    // Storage monitoring is now handled by StorageHealthMonitor.shared which provides:
    // - Volume mount/unmount detection (instant via NSWorkspace notifications)
    // - Disk space monitoring with thresholds
    // - I/O latency tracking
    // - Keep-alive writes to prevent drive spindown
    // - Periodic health check every 30 seconds as fallback

    // MARK: - Permission Monitoring

    /// Start monitoring for permission changes while recording
    /// Gracefully stops the pipeline if permissions are revoked
    private func startPermissionMonitoring() async {
        guard !permissionMonitorSetup else { return }
        permissionMonitorSetup = true

        // Set up callbacks for permission revocation
        PermissionMonitor.shared.onScreenRecordingRevoked = { [weak self] in
            guard let self = self else { return }
            Log.error("[AppCoordinator] Screen recording permission revoked - stopping pipeline gracefully", category: .app)
            try? await self.stopPipeline()

            // Post notification so UI can alert user
            await MainActor.run {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ScreenRecordingPermissionRevoked"),
                    object: nil
                )
            }
        }

        PermissionMonitor.shared.onAccessibilityRevoked = {
            Log.warning("[AppCoordinator] Accessibility permission revoked - display switching disabled", category: .app)

            // Post notification so UI can alert user
            await MainActor.run {
                NotificationCenter.default.post(
                    name: NSNotification.Name("AccessibilityPermissionRevoked"),
                    object: nil
                )
            }
        }

        // Start the periodic permission check
        await PermissionMonitor.shared.startMonitoring()
        Log.info("[AppCoordinator] Permission monitoring started", category: .app)
    }

    /// Stop monitoring for permission changes
    private func stopPermissionMonitoring() async {
        await PermissionMonitor.shared.stopMonitoring()
        permissionMonitorSetup = false
        Log.info("[AppCoordinator] Permission monitoring stopped", category: .app)
    }

    // MARK: - Orphaned Video Cleanup

    /// Start periodic cleanup of orphaned videos (processingState stuck at 1)
    /// Runs every 60 seconds to catch videos that weren't finalized properly
    private func startOrphanedVideoCleanup() {
        orphanedVideoCleanupTask?.cancel()

        orphanedVideoCleanupTask = Task { [weak self] in
            let cleanupInterval: UInt64 = 60_000_000_000 // 60 seconds

            while !Task.isCancelled {
                try? await Task.sleep(for: .nanoseconds(Int64(cleanupInterval)), clock: .continuous)
                guard !Task.isCancelled else { break }

                await self?.cleanupOrphanedVideos()
            }
        }

        Log.info("[AppCoordinator] Orphaned video cleanup task started (60s interval)", category: .app)
    }

    /// Stop the orphaned video cleanup task
    private func stopOrphanedVideoCleanup() {
        orphanedVideoCleanupTask?.cancel()
        orphanedVideoCleanupTask = nil
    }

    /// Finalize any orphaned videos that have processingState=1 but no active WAL session
    private func cleanupOrphanedVideos() async {
        do {
            // Get active WAL sessions to exclude currently-being-written videos
            guard let storageManager = services.storage as? StorageManager else {
                return
            }

            let walManager = await storageManager.getWALManager()
            let orphanedCount = try await finalizeOrphanedVideoSnapshot {
                try await walManager.listActiveSessions()
            }
            if orphanedCount > 0 {
                Log.warning("[OrphanCleanup] Finalized \(orphanedCount) orphaned videos (processingState was stuck at 1)", category: .app)
            }
        } catch {
            Log.error("[OrphanCleanup] Failed to cleanup orphaned videos", category: .app, error: error)
        }
    }

    /// Finalize only known orphan candidates. Never let a stale WAL snapshot
    /// apply a bulk update to a placeholder inserted while lookup was suspended.
    func finalizeOrphanedVideoSnapshot(
        readActiveWALSessions: @Sendable () async throws -> [WALSession]
    ) async throws -> Int {
        try Task.checkCancellation()
        let candidates = try await services.database.getAllUnfinalisedVideos()
        try Task.checkCancellation()
        let activeWALSessions = try await readActiveWALSessions()
        try Task.checkCancellation()
        let activeWALPathIDs = Set(activeWALSessions.map { $0.videoID.value })
        var finalizedCount = 0

        for candidate in candidates {
            try Task.checkCancellation()
            guard !liveVideoWriterPaths.contains(candidate.relativePath) else { continue }
            let pathName = URL(fileURLWithPath: candidate.relativePath)
                .deletingPathExtension().lastPathComponent
            // An unknown path cannot be proven unrelated to an active journal.
            guard let pathID = Int64(pathName), !activeWALPathIDs.contains(pathID) else { continue }
            guard let video = try await services.database.getVideoSegment(
                id: VideoSegmentID(value: candidate.id)
            ) else { continue }
            try Task.checkCancellation()
            // Actor reentrancy can publish writer ownership during any await.
            guard !liveVideoWriterPaths.contains(candidate.relativePath) else { continue }
            try await services.database.markVideoFinalized(
                id: candidate.id, frameCount: video.frameCount, fileSize: video.fileSizeBytes
            )
            finalizedCount += 1
        }
        return finalizedCount
    }

    // MARK: - Pipeline Implementation

    /// Buffered frame entry - tracks frames pending readability confirmation
    private struct BufferedFrame {
        let frameID: Int64
        /// The frame's index in the video segment (0-based)
        let frameIndexInSegment: Int
    }

    /// State for tracking a video writer by resolution
    private struct VideoWriterState {
        var writer: SegmentWriter
        var videoDBID: Int64
        var frameCount: Int
        var isReadable: Bool
        /// Buffer for frames waiting to be confirmed flushed to disk before marking readable
        var pendingFrames: [BufferedFrame]
        var width: Int
        var height: Int
    }

    /// Main pipeline: Capture → Storage → Processing → Database → Search
    /// Uses Rewind-style multi-resolution video writing
    private func runPipeline() async {
        Log.info("Pipeline processing started", category: .app)

        let frameStream = await services.capture.frameStream
        var writersByResolution: [String: VideoWriterState] = [:]
        var lastPipelineMemoryLogAt = Date.distantPast
        let videoUpdateInterval = 5

        func maybeLogPipelineMemory(reason: String) {
            let now = Date()
            guard now.timeIntervalSince(lastPipelineMemoryLogAt) >= Self.pipelineMemoryLogInterval else { return }
            lastPipelineMemoryLogAt = now
            logPipelineMemorySnapshot(writersByResolution: writersByResolution, reason: reason)
        }

        for await captured in frameStream {
            let identity = await activityMonitor?.captureIdentity(for: captured.metadata, at: captured.timestamp)
            let frame = CapturedFrame(timestamp: captured.timestamp, imageData: captured.imageData,
                width: captured.width, height: captured.height, bytesPerRow: captured.bytesPerRow,
                metadata: captured.metadata.linkingActivity(identity))
            Log.verbose("[Pipeline] Received frame from stream: \(frame.width)x\(frame.height), app=\(frame.metadata.appName)", category: .app)

            if Task.isCancelled {
                Log.info("Pipeline task cancelled", category: .app)
                break
            }

            // Skip frames entirely when loginwindow is frontmost (lock screen, login, etc.)
            if frame.metadata.appBundleID == "com.apple.loginwindow" {
                continue
            }

            // Skip frames when timeline is visible (don't record while user is viewing timeline)
            if isTimelineVisible {
                // Check if we need to flush pending frames before pausing
                if shouldFlushPendingFrames {
                    shouldFlushPendingFrames = false
                    if let processingQueue = await services.processingQueue {
                        for (_, state) in writersByResolution {
                            let pendingCount = state.pendingFrames.count
                            if pendingCount > 0 {
                                Log.info("[FLUSH] Timeline opened - enqueueing \(pendingCount) pending frames for OCR", category: .app)
                                // DON'T clear pendingFrames here - they still need to be marked readable
                                // when the fragment actually flushes to disk.
                                for bufferedFrame in state.pendingFrames {
                                    try? await processingQueue.enqueue(frameID: bufferedFrame.frameID)
                                }
                            }
                        }
                    }
                }
                continue
            }

            do {
                let resolutionKey = "\(frame.width)x\(frame.height)"
                var writerState: VideoWriterState

                if var existingState = writersByResolution[resolutionKey] {
                    let maxFramesPerSegment = VideoSegmentSizingPolicy.maxFramesPerSegment(
                        width: frame.width,
                        height: frame.height
                    )
                    if existingState.frameCount >= maxFramesPerSegment {
                        try await finalizeWriter(&existingState, processingQueue: await services.processingQueue)
                        writersByResolution.removeValue(forKey: resolutionKey)
                        writerState = try await createNewWriterState(width: frame.width, height: frame.height)
                        writersByResolution[resolutionKey] = writerState
                    } else {
                        writerState = existingState
                    }
                } else {
                    if let unfinalised = try await services.database.getUnfinalisedVideoByResolution(
                        width: frame.width,
                        height: frame.height
                    ) {
                        Log.info("Resuming unfinalised video \(unfinalised.id) for resolution \(resolutionKey)", category: .app)
                        writerState = try await resumeWriterState(from: unfinalised)
                    } else {
                        writerState = try await createNewWriterState(width: frame.width, height: frame.height)
                    }
                    writersByResolution[resolutionKey] = writerState
                }

                try await writerState.writer.appendFrame(frame)

                // Verify encoder actually wrote the frame by checking its frame count
                // This detects if the encoder silently failed or auto-finalized
                let actualEncoderFrameCount = await writerState.writer.frameCount
                if actualEncoderFrameCount != writerState.frameCount + 1 {
                    Log.error("[ENCODER-MISMATCH] Encoder frame count (\(actualEncoderFrameCount)) != expected (\(writerState.frameCount + 1)) - encoder may have failed/finalized. Removing broken writer for videoDBID=\(writerState.videoDBID), resolution=\(resolutionKey)", category: .app)
                    try? await writerState.writer.cancel()
                    let cancelledWriterPath = await writerState.writer.relativePath
                    liveVideoWriterPaths.remove(cancelledWriterPath)
                    writersByResolution.removeValue(forKey: resolutionKey)
                    continue
                }

                writerState.frameCount += 1

                if writerState.width == 0 {
                    writerState.width = await writerState.writer.frameWidth
                    writerState.height = await writerState.writer.frameHeight
                }

                try await trackSessionChange(frame: frame)

                guard let appSegmentID = currentSegmentID else {
                    Log.warning("No current app segment ID for frame insertion", category: .app)
                    writersByResolution[resolutionKey] = writerState
                    continue
                }

                let frameIndexInSegment = writerState.frameCount - 1
                let frameRef = FrameReference(
                    id: FrameID(value: 0),
                    timestamp: frame.timestamp,
                    segmentID: AppSegmentID(value: appSegmentID),
                    videoID: VideoSegmentID(value: writerState.videoDBID),
                    frameIndexInSegment: frameIndexInSegment,
                    metadata: frame.metadata,
                    source: .native
                )
                let frameID = try await services.database.insertFrame(frameRef)

                let storedFrame = FrameReference(id: FrameID(value: frameID), timestamp: frame.timestamp,
                    segmentID: frameRef.segmentID, videoID: frameRef.videoID,
                    frameIndexInSegment: frameIndexInSegment, metadata: frame.metadata, source: .native)
                let storeID = try await services.database.activityStoreID()
                let snapshot = try await services.database.materializeScreenEvidence(frame: storedFrame, storeID: storeID,
                    width: frame.width, height: frame.height, text: nil)
                if let identity {
                    do {
                        _ = try await services.database.linkActivityScreen(eventID: identity.activityEventID,
                            screen: snapshot.ref, capturedAt: frame.timestamp, method: "bracketed-capture-window-generation-v1")
                    } catch {
                        // A late gap or focus transition can invalidate a once-current observer receipt.
                        Log.debug("[Activity] Recorded screen retained without an unproved activity link", category: .app)
                    }
                }

                // Persist WAL mapping for exact frameID -> raw frame lookup while segment is unfinalized.
                var didRegisterWALMapping = false
                if let storageManager = services.storage as? StorageManager {
                    let walVideoID = await writerState.writer.segmentID
                    let walManager = await storageManager.getWALManager()
                    do {
                        try await walManager.registerFrameID(
                            videoID: walVideoID,
                            frameID: frameID,
                            frameIndex: frameIndexInSegment
                        )
                        didRegisterWALMapping = true
                    } catch {
                        Log.warning(
                            "[WAL] Failed to register frameID mapping for frame \(frameID) (video \(walVideoID.value), index \(frameIndexInSegment)): \(error)",
                            category: .app
                        )
                    }
                }

                Log.verbose("[CAPTURE-DEBUG] Captured frameID=\(frameID), videoDBID=\(writerState.videoDBID), frameIndexInSegment=\(frameIndexInSegment), app=\(frame.metadata.appName)", category: .app)

                if writerState.frameCount % videoUpdateInterval == 0 {
                    let width = await writerState.writer.frameWidth
                    let height = await writerState.writer.frameHeight
                    let fileSize = await writerState.writer.currentFileSize
                    try await services.database.updateVideoSegment(
                        id: writerState.videoDBID,
                        width: width,
                        height: height,
                        fileSize: fileSize,
                        frameCount: writerState.frameCount
                    )
                }

                guard let processingQueue = await services.processingQueue else {
                    Log.error("Processing queue not initialized", category: .app)
                    writersByResolution[resolutionKey] = writerState
                    continue
                }

                // Track frame in pending buffer until it's confirmed flushed/readable.
                let bufferedFrame = BufferedFrame(frameID: frameID, frameIndexInSegment: frameIndexInSegment)

                if FrameReadinessPolicy.shouldMarkReadableAfterWALRegistration(didRegisterWALMapping) {
                    // The processing queue and live dashboard can read active frames from WAL.
                    // Waiting for encoded-video flush makes live capture appear stale.
                    try await services.database.markFrameReadable(frameID: frameID)
                    try await processingQueue.enqueue(frameID: frameID)
                } else if FrameReadinessPolicy.shouldBufferUntilVideoFlush(didRegisterWALMapping: didRegisterWALMapping) {
                    writerState.pendingFrames.append(bufferedFrame)
                }

                // Check if first fragment has been written (makes video readable at all)
                if !writerState.isReadable {
                    writerState.isReadable = await writerState.writer.hasFragmentWritten
                    if writerState.isReadable {
                        Log.info("First video fragment written for \(resolutionKey) - frames now readable from disk", category: .app)
                    }
                }

                // Get the count of frames confirmed flushed to disk
                // Frames with frameIndex < flushedCount are guaranteed to be readable
                let flushedCount = await writerState.writer.framesFlushedToDisk

                // Mark frames as readable and enqueue for OCR if they've been flushed to disk
                while let firstFrame = writerState.pendingFrames.first,
                      firstFrame.frameIndexInSegment < flushedCount {
                    let frameToEnqueue = writerState.pendingFrames.removeFirst()
                    // Mark frame as readable now that it's confirmed flushed to video file
                    try await services.database.markFrameReadable(frameID: frameToEnqueue.frameID)
                    try await processingQueue.enqueue(frameID: frameToEnqueue.frameID)
                }

                writersByResolution[resolutionKey] = writerState
                maybeLogPipelineMemory(reason: "steady-state")
                totalFramesProcessed += 1
                statusHolder.incrementFrames()

                if totalFramesProcessed % 10 == 0 {
                    Log.debug("Pipeline processed \(totalFramesProcessed) frames, \(writersByResolution.count) active writers", category: .app)
                }

            } catch let error as StorageError {
                totalErrors += 1
                statusHolder.incrementErrors()
                Log.error("[Pipeline] Error processing frame", category: .app, error: error)

                // If it's a file write failure, the writer is broken - remove it so a fresh one is created
                if case .fileWriteFailed = error {
                    let resolutionKey = "\(frame.width)x\(frame.height)"
                    if let brokenWriter = writersByResolution[resolutionKey] {
                        Log.warning("Removing broken writer for \(resolutionKey) due to write failure - will create fresh writer", category: .app)
                        try? await brokenWriter.writer.cancel()
                        let cancelledWriterPath = await brokenWriter.writer.relativePath
                        liveVideoWriterPaths.remove(cancelledWriterPath)
                        writersByResolution.removeValue(forKey: resolutionKey)
                    }
                }
                continue
            } catch {
                totalErrors += 1
                statusHolder.incrementErrors()
                Log.error("[Pipeline] Error processing frame", category: .app, error: error)
                continue
            }
        }

        logPipelineMemorySnapshot(writersByResolution: writersByResolution, reason: "pipeline-ending")

        // Save and finalize all remaining writers
        for (resolutionKey, var writerState) in writersByResolution {
            do {
                // Use finalizeWriter to properly mark video as finalized (processingState = 0)
                // This ensures frames can be OCR processed even if pipeline stops mid-video
                try await finalizeWriter(&writerState, processingQueue: await services.processingQueue)
                Log.info("Video segment for \(resolutionKey) finalized (\(writerState.frameCount) frames)", category: .app)
            } catch {
                Log.error("[Pipeline] Failed to finalize video segment for \(resolutionKey)", category: .app, error: error)
            }
        }

        if let segmentID = currentSegmentID {
            try? await services.database.updateSegmentEndDate(id: segmentID, endDate: Date())
            currentSegmentID = nil
        }

        Log.info("Pipeline processing completed. Total frames: \(totalFramesProcessed), Errors: \(totalErrors)", category: .app)
    }

    private func logPipelineMemorySnapshot(writersByResolution: [String: VideoWriterState], reason: String) {
        var totalPendingFrames = 0
        var totalPendingBytes: Int64 = 0
        var perResolutionParts: [String] = []

        for (resolutionKey, writerState) in writersByResolution {
            let pendingFrames = writerState.pendingFrames.count
            guard pendingFrames > 0 else { continue }

            let pendingBytes: Int64 = 0
            totalPendingFrames += pendingFrames
            totalPendingBytes += pendingBytes
            perResolutionParts.append("\(resolutionKey):\(pendingFrames)f/\(Self.formatBytes(pendingBytes))")
        }

        let perResolutionSummary = perResolutionParts.isEmpty ? "none" : perResolutionParts.sorted().joined(separator: ", ")

        Log.info(
            "[Pipeline-Memory] reason=\(reason) pendingRawFrames=\(totalPendingFrames) pendingRawBytes=\(Self.formatBytes(totalPendingBytes)) activeWriters=\(writersByResolution.count) byResolution=[\(perResolutionSummary)]",
            category: .app
        )
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(0, bytes))
    }

    /// Reserve ownership before publishing the DB placeholder. The first WAL
    /// session is created only when appendFrame runs after this method returns.
    func insertLiveVideoSegment(_ segment: VideoSegment) async throws -> Int64 {
        liveVideoWriterPaths.insert(segment.relativePath)
        do {
            try Task.checkCancellation()
            return try await services.database.insertVideoSegment(segment)
        } catch {
            liveVideoWriterPaths.remove(segment.relativePath)
            throw error
        }
    }

    private func createNewWriterState(width: Int, height: Int) async throws -> VideoWriterState {
        let writer = try await services.storage.createSegmentWriter()
        let relativePath = await writer.relativePath

        let placeholderSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date(),
            frameCount: 0,
            fileSizeBytes: 0,
            relativePath: relativePath,
            width: width,
            height: height
        )
        let videoDBID: Int64
        do {
            videoDBID = try await insertLiveVideoSegment(placeholderSegment)
        } catch {
            try? await writer.cancel()
            throw error
        }
        Log.debug("New video segment created with DB ID: \(videoDBID) for resolution \(width)x\(height)", category: .app)

        return VideoWriterState(
            writer: writer,
            videoDBID: videoDBID,
            frameCount: 0,
            isReadable: false,
            pendingFrames: [],
            width: width,
            height: height
        )
    }

    /// Inspect the interrupted chunk before rolling capture to a fresh writer.
    static func interruptedVideoFileSize(from unfinalised: UnfinalisedVideo, storageDir: URL) -> Int64 {
        // Get file size from filesystem for the old video.
        // Chunk files are stored extensionless under storageRoot/chunks/...; keep
        // the .mp4 fallback only for legacy/dev data.
        let primaryVideoPath = storageDir.appendingPathComponent(unfinalised.relativePath)
        let legacyVideoPath = primaryVideoPath.appendingPathExtension("mp4")
        let oldVideoPath = FileManager.default.fileExists(atPath: primaryVideoPath.path)
            ? primaryVideoPath
            : legacyVideoPath
        let fileSize: Int64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: oldVideoPath.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        } else {
            fileSize = 0
        }

        // A nonempty interrupted chunk can contain fewer frames than its WAL.
        // RecoveryManager owns source deletion after verifying all recovered
        // output, database mappings and enqueue checkpoints. Capture rollover
        // must leave that source untouched, including while recovery is running.
        return fileSize
    }

    private func resumeWriterState(from unfinalised: UnfinalisedVideo) async throws -> VideoWriterState {
        let writer = try await services.storage.createSegmentWriter()

        let storageDir = await services.storage.getStorageDirectory()
        let fileSize = Self.interruptedVideoFileSize(from: unfinalised, storageDir: storageDir)

        // Mark old video as finalized and start fresh
        // WARNING: This uses the frameCount from the database, which may differ from actual video file frames
        // if the app crashed before database was updated
        try await services.database.markVideoFinalized(id: unfinalised.id, frameCount: unfinalised.frameCount, fileSize: fileSize)
        Log.warning("[RESUME-DEBUG] Marked unfinalised video \(unfinalised.id) as finalized with DB frameCount=\(unfinalised.frameCount), fileSize=\(fileSize) bytes - NOTE: actual video frames may differ if app crashed!", category: .app)

        let relativePath = await writer.relativePath
        let placeholderSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date(),
            frameCount: 0,
            fileSizeBytes: 0,
            relativePath: relativePath,
            width: unfinalised.width,
            height: unfinalised.height
        )
        let videoDBID: Int64
        do {
            videoDBID = try await insertLiveVideoSegment(placeholderSegment)
        } catch {
            try? await writer.cancel()
            throw error
        }

        return VideoWriterState(
            writer: writer,
            videoDBID: videoDBID,
            frameCount: 0,
            isReadable: false,
            pendingFrames: [],
            width: unfinalised.width,
            height: unfinalised.height
        )
    }

    func finalizeLiveVideoWriter(_ writer: SegmentWriter, videoDBID: Int64, frameCount: Int) async throws {
        _ = try await writer.finalize()
        // Retain ownership while publishing metadata so a concurrent sweep cannot
        // overwrite it, but release even if that database publication fails.
        // Encoding has finished and this writer will not append more pixels.
        let finalizedWriterPath = await writer.relativePath
        defer { liveVideoWriterPaths.remove(finalizedWriterPath) }
        let fileSize = await writer.currentFileSize
        try await services.database.markVideoFinalized(id: videoDBID, frameCount: frameCount, fileSize: fileSize)
    }

    private func finalizeWriter(_ writerState: inout VideoWriterState, processingQueue: FrameProcessingQueue?) async throws {
        // IMPORTANT: Finalize writer FIRST to ensure file is fully flushed to disk,
        // THEN mark as finalized in database. This prevents a race condition where
        // the timeline reads an incomplete video file before it's fully written.

        // Log before finalization for debugging
        let encoderFrameCount = await writerState.writer.frameCount
        Log.info("[FINALIZE-DEBUG] About to finalize videoDBID=\(writerState.videoDBID), writerState.frameCount=\(writerState.frameCount), encoderFrameCount=\(encoderFrameCount)", category: .app)

        try await finalizeLiveVideoWriter(writerState.writer, videoDBID: writerState.videoDBID, frameCount: writerState.frameCount)
        let fileSize = await writerState.writer.currentFileSize
        Log.info("[FINALIZE-DEBUG] Marked videoDBID=\(writerState.videoDBID) as finalized with frameCount=\(writerState.frameCount), fileSize=\(fileSize) bytes", category: .app)

        // After finalization, all frames are now readable from the video file
        // Mark them as readable and enqueue for OCR processing
        if let processingQueue = processingQueue {
            // Enqueue any pending frames that weren't yet marked readable
            if !writerState.pendingFrames.isEmpty {
                Log.debug("Enqueueing \(writerState.pendingFrames.count) pending frames after finalization", category: .app)
                for bufferedFrame in writerState.pendingFrames {
                    try await services.database.markFrameReadable(frameID: bufferedFrame.frameID)
                    try await processingQueue.enqueue(frameID: bufferedFrame.frameID)
                }
                writerState.pendingFrames = []
            }
        }
    }

    /// Track app/window changes and create/close segments accordingly
    /// Also handles idle detection - if no frames for longer than idleThresholdSeconds,
    /// closes the current segment and creates a new one on the next frame
    private func trackSessionChange(frame: CapturedFrame) async throws {
        let metadata = frame.metadata
        let current: Segment?
        if let id = currentSegmentID { current = try await services.database.getSegment(id: id) }
        else { current = nil }
        let context = metadata.captureContext
        let identityChanged = context?.processGeneration != lastSegmentContext?.processGeneration
            || context?.windowID != lastSegmentContext?.windowID
            || context?.windowGeneration != lastSegmentContext?.windowGeneration
            || context?.documentID != lastSegmentContext?.documentID
            || context?.paneID != lastSegmentContext?.paneID
        let changed = current == nil || current?.bundleID != metadata.appBundleID
            || current?.windowName != metadata.windowName || current?.browserUrl != metadata.browserURL || identityChanged
        if changed {
            if let id = currentSegmentID, let lastFrameTimestamp {
                try await services.database.updateSegmentEndDate(id: id, endDate: lastFrameTimestamp)
            }
            currentSegmentID = try await services.database.insertSegment(
                bundleID: metadata.appBundleID ?? "unknown", startDate: frame.timestamp, endDate: frame.timestamp,
                windowName: metadata.windowName, browserUrl: metadata.browserURL, type: 0)
            lastSegmentContext = context
            Log.debug("[Segment] Started immutable captured-context segment", category: .app)
        }
        // Missing retained images do not establish inactivity. The independent stream owns coverage.
        lastFrameTimestamp = frame.timestamp
    }

    /// Audio pipeline: AudioCapture → AudioProcessing (whisper.cpp) → Database
    private func runAudioPipeline() async {
        Log.info("Audio pipeline processing started", category: .app)

        // Get the audio stream from capture
        let sourceAudioStream = await services.audioCapture.audioStream
        let dictationManager = services.dictation
        let (audioStream, continuation) = AudioPipelineBufferPolicy.makeStream()
        let bridgeTask = Task {
            for await audio in sourceAudioStream {
                if Task.isCancelled { break }
                await dictationManager.ingest(audio)
                continuation.yield(audio)
            }
            continuation.finish()
        }
        continuation.onTermination = { @Sendable _ in
            bridgeTask.cancel()
        }

        // Start processing the stream (this will run until the stream ends)
        await services.audioProcessing.startProcessing(audioStream: audioStream)
        bridgeTask.cancel()

        Log.info("Audio pipeline processing completed", category: .app)
    }

    // MARK: - Queue Monitoring

    /// Get current OCR processing queue statistics
    public func getQueueStatistics() async -> QueueStatistics? {
        guard let queue = await services.processingQueue else {
            return nil
        }
        return await queue.getStatistics()
    }

    /// Get current power state for monitoring display
    nonisolated public func getCurrentPowerState() -> (source: PowerStateMonitor.PowerSource, isPaused: Bool) {
        let snapshot = OCRPowerSettingsSnapshot.fromDefaults()
        let source = PowerStateMonitor.shared.getCurrentPowerSource()
        let isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        let isPaused =
            (snapshot.pauseOnBattery && source == .battery) ||
            (snapshot.pauseOnLowPowerMode && isLowPowerModeEnabled)
        return (source, isPaused)
    }

    /// Get frames processed per minute for the last N minutes
    /// Returns dictionary of [minuteOffset: count] where minuteOffset 0 = current minute
    public func getFramesProcessedPerMinute(lastMinutes: Int) async throws -> [Int: Int] {
        let db = await services.database
        return try await db.getFramesProcessedPerMinute(lastMinutes: lastMinutes)
    }

    // MARK: - Search Interface

    /// Get all distinct app bundle IDs from the database for filter UI
    /// Caller should use AppNameResolver.shared.resolveAll() to get display names
    public func getDistinctAppBundleIDs() async throws -> [String] {
        guard let adapter = await services.dataAdapter else {
            return []
        }
        return try await adapter.getDistinctAppBundleIDs()
    }

    /// Search for text across all captured frames
    public func search(query: String, limit: Int = 50) async throws -> SearchResults {
        let searchQuery = SearchQuery(text: query, filters: .none, limit: limit, offset: 0)
        return try await search(query: searchQuery)
    }

    /// Advanced search with filters
    /// Routes to DataAdapter which prioritizes Rewind data source
    public func search(query: SearchQuery) async throws -> SearchResults {
        guard let adapter = await services.dataAdapter else { throw DataAdapterError.notInitialized }
        return try await adapter.search(query: query)
    }

    // MARK: - Frame Retrieval

    /// Get a specific frame image by timestamp
    /// Uses real timestamps for accurate seeking (works correctly with deduplication)
    /// Automatically routes to appropriate source via DataAdapter
    public func getFrameImage(segmentID: VideoSegmentID, timestamp: Date) async throws -> Data {
        guard let adapter = await services.dataAdapter else {
            // Fallback to storage if adapter not available - need to query frame index from database
            let frames = try await services.database.getFrames(from: timestamp, to: timestamp, limit: 1)
            guard let frame = frames.first else {
                throw NSError(domain: "AppCoordinator", code: 404, userInfo: [NSLocalizedDescriptionKey: "Frame not found"])
            }
            return try await services.storage.readFrame(segmentID: segmentID, frameIndex: frame.frameIndexInSegment)
        }

        return try await adapter.getFrameImage(segmentID: segmentID, timestamp: timestamp)
    }

    /// Get video info for a frame (returns nil if not video-based)
    /// For Rewind frames, returns path/index to display video directly
    public func getFrameVideoInfo(segmentID: VideoSegmentID, timestamp: Date, source: FrameSource) async throws -> FrameVideoInfo? {
        guard let adapter = await services.dataAdapter else {
            return nil
        }

        return try await adapter.getFrameVideoInfo(segmentID: segmentID, timestamp: timestamp, source: source)
    }

    /// Get frame image by exact videoID and frameIndex (more reliable than timestamp matching)
    public func getFrameImageByIndex(videoID: VideoSegmentID, frameIndex: Int, source: FrameSource) async throws -> Data {
        guard let adapter = await services.dataAdapter else {
            throw NSError(domain: "AppCoordinator", code: 500, userInfo: [NSLocalizedDescriptionKey: "DataAdapter not initialized"])
        }

        return try await adapter.getFrameImageByIndex(videoID: videoID, frameIndex: frameIndex, source: source)
    }

    /// Get frame image as CGImage without JPEG encode/decode round-trips.
    public func getFrameCGImage(videoPath: String, frameIndex: Int, frameRate: Double?, source: FrameSource) async throws -> CGImage {
        guard let adapter = await services.dataAdapter else {
            throw NSError(domain: "AppCoordinator", code: 500, userInfo: [NSLocalizedDescriptionKey: "DataAdapter not initialized"])
        }

        return try await adapter.getFrameCGImage(
            videoPath: videoPath,
            frameIndex: frameIndex,
            frameRate: frameRate,
            source: source
        )
    }

    /// Get a dashboard-ready screenshot image for a frame, including active WAL-backed frames.
    public func getLiveFrameCGImage(frameWithInfo item: FrameWithVideoInfo) async throws -> CGImage {
        let frame = item.frame

        if let videoInfo = item.videoInfo {
            var firstError: Error?
            for source in LiveFrameReadPolicy.orderedSources(
                frameSource: frame.source,
                isVideoFinalized: videoInfo.isVideoFinalized
            ) {
                do {
                    switch source {
                    case .activeWAL:
                        return try await getActiveWALFrameCGImage(frame: frame, videoPath: videoInfo.videoPath)
                    case .video:
                        return try await getFrameCGImage(
                            videoPath: videoInfo.videoPath,
                            frameIndex: videoInfo.frameIndex,
                            frameRate: videoInfo.frameRate,
                            source: frame.source
                        )
                    }
                } catch {
                    firstError = firstError ?? error
                }
            }
            throw firstError ?? NSError(
                domain: "AppCoordinator",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No readable backing found for frame \(frame.id.value)"]
            )
        }

        let imageData = try await getFrameImageByIndex(
            videoID: frame.videoID,
            frameIndex: frame.frameIndexInSegment,
            source: frame.source
        )
        return try cgImage(fromEncodedImageData: imageData)
    }

    private func getActiveWALFrameCGImage(frame: FrameReference, videoPath: String) async throws -> CGImage {
        guard let storageManager = services.storage as? StorageManager else {
            throw NSError(
                domain: "AppCoordinator",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Storage manager does not expose WAL manager"]
            )
        }

        let activeSegmentID = try activeWALSegmentID(from: videoPath)
        let walManager = await storageManager.getWALManager()
        let capturedFrame = try await walManager.readFrame(
            videoID: activeSegmentID,
            frameID: frame.id.value,
            fallbackFrameIndex: frame.frameIndexInSegment
        )
        return try cgImage(fromRawBGRAFrame: capturedFrame)
    }

    private func activeWALSegmentID(from videoPath: String) throws -> VideoSegmentID {
        let lastPathComponent = (videoPath as NSString).lastPathComponent
        let stem = (lastPathComponent as NSString).deletingPathExtension
        guard let segmentID = Int64(stem) else {
            throw NSError(
                domain: "AppCoordinator",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Unable to parse active WAL segment ID from \(videoPath)"]
            )
        }
        return VideoSegmentID(value: segmentID)
    }

    private func cgImage(fromRawBGRAFrame frame: CapturedFrame) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
        )

        guard let provider = CGDataProvider(data: frame.imageData as CFData),
              let image = CGImage(
                  width: frame.width,
                  height: frame.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: frame.bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: bitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw NSError(
                domain: "AppCoordinator",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create CGImage from active WAL frame"]
            )
        }

        return image
    }

    private func cgImage(fromEncodedImageData data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(
                domain: "AppCoordinator",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Unable to decode frame image data"]
            )
        }
        return image
    }

    /// Get frame image directly using filename-based videoID (optimized, no database lookup)
    /// Use this when you already have the video filename from a JOIN query (e.g., FrameVideoInfo)
    /// - Parameters:
    ///   - filenameID: The Int64 filename (e.g., 1768624554519) extracted from the video path
    ///   - frameIndex: The frame index within the video segment
    /// - Returns: JPEG image data for the frame
    public func getFrameImageDirect(filenameID: Int64, frameIndex: Int) async throws -> Data {
        // Call storage directly with the filename-based ID - no database lookup needed!
        let videoSegmentID = VideoSegmentID(value: filenameID)
        return try await services.storage.readFrame(segmentID: videoSegmentID, frameIndex: frameIndex)
    }

    /// Get frame image from a full video path (used for Rewind frames with string-based IDs).
    /// When not explicitly provided, strict timestamp matching follows timeline visibility:
    /// strict while visible, relaxed while hidden.
    public func getFrameImageFromPath(
        videoPath: String,
        frameIndex: Int,
        enforceTimestampMatch: Bool? = nil
    ) async throws -> Data {
        let shouldEnforceTimestampMatch = enforceTimestampMatch ?? isTimelineVisible
        return try await services.storage.readFrameFromPath(
            videoPath: videoPath,
            frameIndex: frameIndex,
            enforceTimestampMatch: shouldEnforceTimestampMatch
        )
    }

    /// Get frames in a time range
    /// Seamlessly blends data from all sources via DataAdapter
    public func getFrames(from startDate: Date, to endDate: Date, limit: Int = 500, filters: FilterCriteria? = nil) async throws -> [FrameReference] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database if adapter not available
            return try await services.database.getFrames(from: startDate, to: endDate, limit: limit)
        }

        return try await adapter.getFrames(from: startDate, to: endDate, limit: limit, filters: filters)
    }

    /// Get frames with video info in a time range (optimized - single query with JOINs)
    /// This is the preferred method for timeline views to avoid N+1 queries
    public func getFramesWithVideoInfo(from startDate: Date, to endDate: Date, limit: Int = 500, filters: FilterCriteria? = nil) async throws -> [FrameWithVideoInfo] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database (no video info for native)
            let frames = try await services.database.getFrames(from: startDate, to: endDate, limit: limit)
            return frames.map { FrameWithVideoInfo(frame: $0, videoInfo: nil) }
        }

        return try await adapter.getFramesWithVideoInfo(from: startDate, to: endDate, limit: limit, filters: filters)
    }

    /// Get the most recent frames across all sources
    /// Returns frames sorted by timestamp descending (newest first)
    public func getMostRecentFrames(limit: Int = 500, filters: FilterCriteria? = nil) async throws -> [FrameReference] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database
            return try await services.database.getMostRecentFrames(limit: limit)
        }

        return try await adapter.getMostRecentFrames(limit: limit, filters: filters)
    }

    /// Get the most recent frames with video info (optimized - single query with JOINs)
    public func getMostRecentFramesWithVideoInfo(limit: Int = 500, filters: FilterCriteria? = nil) async throws -> [FrameWithVideoInfo] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database (no video info for native)
            let frames = try await services.database.getMostRecentFrames(limit: limit)
            return frames.map { FrameWithVideoInfo(frame: $0, videoInfo: nil) }
        }

        return try await adapter.getMostRecentFramesWithVideoInfo(limit: limit, filters: filters)
    }

    /// Get frames before a timestamp (for infinite scroll - loading older frames)
    /// Returns frames sorted by timestamp descending (newest first of the older batch)
    public func getFramesBefore(timestamp: Date, limit: Int = 300, filters: FilterCriteria? = nil) async throws -> [FrameReference] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database
            return try await services.database.getFramesBefore(timestamp: timestamp, limit: limit)
        }

        return try await adapter.getFramesBefore(timestamp: timestamp, limit: limit, filters: filters)
    }

    /// Get frames with video info before a timestamp (optimized - single query with JOINs)
    public func getFramesWithVideoInfoBefore(timestamp: Date, limit: Int = 300, filters: FilterCriteria? = nil) async throws -> [FrameWithVideoInfo] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database (no video info for native)
            let frames = try await services.database.getFramesBefore(timestamp: timestamp, limit: limit)
            return frames.map { FrameWithVideoInfo(frame: $0, videoInfo: nil) }
        }

        return try await adapter.getFramesWithVideoInfoBefore(timestamp: timestamp, limit: limit, filters: filters)
    }

    /// Get frames after a timestamp (for infinite scroll - loading newer frames)
    /// Returns frames sorted by timestamp ascending (oldest first of the newer batch)
    public func getFramesAfter(timestamp: Date, limit: Int = 300, filters: FilterCriteria? = nil) async throws -> [FrameReference] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database
            return try await services.database.getFramesAfter(timestamp: timestamp, limit: limit)
        }

        return try await adapter.getFramesAfter(timestamp: timestamp, limit: limit, filters: filters)
    }

    /// Get frames with video info after a timestamp (optimized - single query with JOINs)
    public func getFramesWithVideoInfoAfter(timestamp: Date, limit: Int = 300, filters: FilterCriteria? = nil) async throws -> [FrameWithVideoInfo] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database (no video info for native)
            let frames = try await services.database.getFramesAfter(timestamp: timestamp, limit: limit)
            return frames.map { FrameWithVideoInfo(frame: $0, videoInfo: nil) }
        }

        return try await adapter.getFramesWithVideoInfoAfter(timestamp: timestamp, limit: limit, filters: filters)
    }

    /// Get the timestamp of the most recent frame across all sources
    /// Returns nil if no frames exist in any source
    public func getMostRecentFrameTimestamp() async throws -> Date? {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database - get most recent frame
            let frames = try await services.database.getMostRecentFrames(limit: 1)
            return frames.first?.timestamp
        }

        return try await adapter.getMostRecentFrameTimestamp()
    }

    /// Get a single frame by ID with video info (optimized - single query with JOINs)
    public func getFrameWithVideoInfoByID(id: FrameID) async throws -> FrameWithVideoInfo? {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database
            return try await services.database.getFrameWithVideoInfoByID(id: id)
        }

        return try await adapter.getFrameWithVideoInfoByID(id: id)
    }

    /// Get processing status for multiple frames in a single query
    /// Returns dictionary of frameID -> processingStatus (0=pending, 1=processing, 2=completed, 3=failed, 4=not yet readable)
    public func getFrameProcessingStatuses(frameIDs: [Int64]) async throws -> [Int64: Int] {
        return try await services.database.getFrameProcessingStatuses(frameIDs: frameIDs)
    }

    // MARK: - Segment Retrieval

    /// Get segments in a time range
    /// Seamlessly blends data from all sources via DataAdapter
    public func getSegments(from startDate: Date, to endDate: Date) async throws -> [Segment] {
        guard let adapter = await services.dataAdapter else {
            // Fallback to database if adapter not available
            return try await services.database.getSegments(from: startDate, to: endDate)
        }

        return try await adapter.getSegments(from: startDate, to: endDate)
    }

    /// Get the most recent segment
    public func getMostRecentSegment() async throws -> Segment? {
        try await services.database.getMostRecentSegment()
    }

    /// Get segments for a specific app
    public func getSegments(bundleID: String, limit: Int = 100) async throws -> [Segment] {
        try await services.database.getSegments(bundleID: bundleID, limit: limit)
    }

    /// Get segments for a specific app within a time range with pagination
    public func getSegments(
        bundleID: String,
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        offset: Int
    ) async throws -> [Segment] {
        try await services.database.getSegments(
            bundleID: bundleID,
            from: startDate,
            to: endDate,
            limit: limit,
            offset: offset
        )
    }

    /// Get segments filtered by bundle ID, time range, and window name or domain with pagination
    /// For browsers, filters by domain extracted from browserUrl; for other apps, filters by windowName
    public func getSegments(
        bundleID: String,
        windowNameOrDomain: String,
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        offset: Int
    ) async throws -> [Segment] {
        try await services.database.getSegments(
            bundleID: bundleID,
            windowNameOrDomain: windowNameOrDomain,
            from: startDate,
            to: endDate,
            limit: limit,
            offset: offset
        )
    }

    /// Get aggregated app usage stats (duration and unique window/domain count) for a time range
    /// For browsers, counts unique domains; for other apps, counts unique windowNames
    public func getAppUsageStats(
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(bundleID: String, duration: TimeInterval, uniqueItemCount: Int)] {
        try await services.database.getAppUsageStats(from: startDate, to: endDate)
    }

    /// Get window usage aggregated by windowName or domain for a specific app
    /// For browsers: returns websites (from browserUrl) first, then windowName fallbacks, with tab counts per website
    /// For non-browsers: returns windows by windowName
    /// Returns items sorted by type (websites first) then duration descending
    public func getWindowUsageForApp(
        bundleID: String,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(windowName: String?, isWebsite: Bool, duration: TimeInterval, tabCount: Int?)] {
        try await services.database.getWindowUsageForApp(bundleID: bundleID, from: startDate, to: endDate)
    }

    /// Get browser tab usage aggregated by windowName (tab title) with full URL
    /// Returns tabs sorted by duration descending
    public func getBrowserTabUsage(
        bundleID: String,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(windowName: String?, browserUrl: String?, duration: TimeInterval)] {
        try await services.database.getBrowserTabUsage(bundleID: bundleID, from: startDate, to: endDate)
    }

    public func getBrowserTabUsageForDomain(
        bundleID: String,
        domain: String,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(windowName: String?, browserUrl: String?, duration: TimeInterval)] {
        try await services.database.getBrowserTabUsageForDomain(bundleID: bundleID, domain: domain, from: startDate, to: endDate)
    }

    // MARK: - Tag Operations

    /// Get all tags
    public func getAllTags() async throws -> [Tag] {
        try await services.database.getAllTags()
    }

    /// Create a new tag
    public func createTag(name: String) async throws -> Tag {
        try await services.database.createTag(name: name)
    }

    /// Get a tag by name
    public func getTag(name: String) async throws -> Tag? {
        try await services.database.getTag(name: name)
    }

    /// Add a tag to a segment
    public func addTagToSegment(segmentId: SegmentID, tagId: TagID) async throws {
        // Prevent tagging Rewind data
        if try await isRewindSegment(segmentId: segmentId) {
            Log.warning("[AppCoordinator] Cannot add tag to Rewind segment \(segmentId.value)", category: .app)
            return
        }
        try await services.database.addTagToSegment(segmentId: segmentId, tagId: tagId)
    }

    /// Add a tag to multiple segments
    public func addTagToSegments(segmentIds: [SegmentID], tagId: TagID) async throws {
        var addedCount = 0
        for segmentId in segmentIds {
            // Skip Rewind segments
            if try await isRewindSegment(segmentId: segmentId) {
                Log.debug("[AppCoordinator] Skipping tag add for Rewind segment \(segmentId.value)", category: .app)
                continue
            }
            try await services.database.addTagToSegment(segmentId: segmentId, tagId: tagId)
            addedCount += 1
        }
        Log.info("[AppCoordinator] Added tag \(tagId.value) to \(addedCount) segments (skipped \(segmentIds.count - addedCount) Rewind segments)", category: .app)
    }

    /// Remove a tag from a segment
    public func removeTagFromSegment(segmentId: SegmentID, tagId: TagID) async throws {
        // Prevent removing tags from Rewind data
        if try await isRewindSegment(segmentId: segmentId) {
            Log.warning("[AppCoordinator] Cannot remove tag from Rewind segment \(segmentId.value)", category: .app)
            return
        }
        try await services.database.removeTagFromSegment(segmentId: segmentId, tagId: tagId)
    }

    /// Remove a tag from multiple segments
    public func removeTagFromSegments(segmentIds: [SegmentID], tagId: TagID) async throws {
        var removedCount = 0
        for segmentId in segmentIds {
            // Skip Rewind segments
            if try await isRewindSegment(segmentId: segmentId) {
                Log.debug("[AppCoordinator] Skipping tag removal for Rewind segment \(segmentId.value)", category: .app)
                continue
            }
            try await services.database.removeTagFromSegment(segmentId: segmentId, tagId: tagId)
            removedCount += 1
        }
        Log.info("[AppCoordinator] Removed tag \(tagId.value) from \(removedCount) segments (skipped \(segmentIds.count - removedCount) Rewind segments)", category: .app)
    }

    /// Check if a segment is from Rewind data (before the cutoff date)
    private func isRewindSegment(segmentId: SegmentID) async throws -> Bool {
        guard let adapter = await services.dataAdapter else {
            return false // No Rewind source configured
        }

        guard let cutoffDate = await adapter.rewindCutoffDate else {
            return false // No cutoff date means no Rewind data
        }

        // Get segment to check its start date
        guard let segment = try await services.database.getSegment(id: segmentId.value) else {
            return false // Segment doesn't exist
        }

        // If segment starts before cutoff, it's from Rewind
        return segment.startDate < cutoffDate
    }

    /// Get the Rewind cutoff date (for UI to check if data is from Rewind)
    public func getRewindCutoffDate() async -> Date? {
        guard let adapter = await services.dataAdapter else {
            return nil
        }
        return await adapter.rewindCutoffDate
    }

    /// Get all tags for a segment
    public func getTagsForSegment(segmentId: SegmentID) async throws -> [Tag] {
        try await services.database.getTagsForSegment(segmentId: segmentId)
    }

    /// Delete a tag entirely
    public func deleteTag(tagId: TagID) async throws {
        try await services.database.deleteTag(tagId: tagId)
        Log.info("[AppCoordinator] Deleted tag \(tagId.value)", category: .app)
    }

    /// Get the count of segments that have a specific tag
    public func getSegmentCountForTag(tagId: TagID) async throws -> Int {
        try await services.database.getSegmentCountForTag(tagId: tagId)
    }

    /// Get all segment IDs that have the "hidden" tag
    public func getHiddenSegmentIds() async throws -> Set<SegmentID> {
        return try await services.database.getHiddenSegmentIds()
    }

    /// Get a map of segment IDs to their tag IDs for efficient filtering
    public func getSegmentTagsMap() async throws -> [Int64: Set<Int64>] {
        try await services.database.getSegmentTagsMap()
    }

    /// Get a map of segment IDs to linked comment counts for timeline comment indicators.
    public func getSegmentCommentCountsMap() async throws -> [Int64: Int] {
        try await services.database.getSegmentCommentCountsMap()
    }

    /// Hide a segment by adding the "hidden" tag
    public func hideSegment(segmentId: SegmentID) async throws {
        try await hideSegments(segmentIds: [segmentId])
    }

    /// Hide multiple segments by adding the "hidden" tag to each
    public func hideSegments(segmentIds: [SegmentID]) async throws {
        guard !segmentIds.isEmpty else { return }

        // Get or create the hidden tag
        let hiddenTag: Tag
        if let existing = try await services.database.getTag(name: Tag.hiddenTagName) {
            hiddenTag = existing
        } else {
            hiddenTag = try await services.database.createTag(name: Tag.hiddenTagName)
        }

        // Add the tag to all segments
        for segmentId in segmentIds {
            try await services.database.addTagToSegment(segmentId: segmentId, tagId: hiddenTag.id)
        }
        Log.info("[AppCoordinator] Hidden \(segmentIds.count) segments", category: .app)
    }

    // MARK: - Segment Comment Operations

    /// Create a comment and apply it to all provided segments (bulk by default)
    /// Rewind segments are skipped to preserve read-only semantics.
    public func createCommentForSegments(
        body: String,
        segmentIds: [SegmentID],
        attachments: [SegmentCommentAttachment] = [],
        frameID: FrameID? = nil,
        author: String? = nil
    ) async throws -> SegmentCommentCreateResult {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else {
            throw DatabaseError.constraintViolation(underlying: "Comment body cannot be empty")
        }

        let resolvedAuthor = resolvedCommentAuthor(author)
        let comment = try await services.database.createSegmentComment(
            body: trimmedBody,
            author: resolvedAuthor,
            attachments: attachments,
            frameID: frameID
        )

        var linkedSegmentIDs: [SegmentID] = []
        var skippedSegmentIDs: [SegmentID] = []
        var failedSegmentIDs: [SegmentID] = []

        for segmentId in segmentIds {
            do {
                if try await isRewindSegment(segmentId: segmentId) {
                    skippedSegmentIDs.append(segmentId)
                    continue
                }
                try await services.database.addCommentToSegment(segmentId: segmentId, commentId: comment.id)
                linkedSegmentIDs.append(segmentId)
            } catch {
                failedSegmentIDs.append(segmentId)
                Log.warning(
                    "[AppCoordinator] Failed linking comment \(comment.id.value) to segment \(segmentId.value): \(error)",
                    category: .app
                )
            }
        }

        if linkedSegmentIDs.isEmpty {
            // No eligible segments were linked, clean up the newly-created comment (and attachments).
            do {
                try await services.database.deleteSegmentComment(commentId: comment.id)
            } catch {
                Log.warning(
                    "[AppCoordinator] Failed cleanup for unlinked comment \(comment.id.value): \(error)",
                    category: .app
                )
            }
            throw DatabaseError.constraintViolation(underlying: "No eligible segments to attach comment")
        }

        Log.info(
            "[AppCoordinator] Created comment \(comment.id.value): linked=\(linkedSegmentIDs.count), skipped=\(skippedSegmentIDs.count), failed=\(failedSegmentIDs.count)",
            category: .app
        )
        return SegmentCommentCreateResult(
            comment: comment,
            linkedSegmentIDs: linkedSegmentIDs,
            skippedSegmentIDs: skippedSegmentIDs,
            failedSegmentIDs: failedSegmentIDs
        )
    }

    /// Link an existing comment to multiple segments
    public func addCommentToSegments(segmentIds: [SegmentID], commentId: SegmentCommentID) async throws {
        var linkedCount = 0
        for segmentId in segmentIds {
            if try await isRewindSegment(segmentId: segmentId) {
                continue
            }
            try await services.database.addCommentToSegment(segmentId: segmentId, commentId: commentId)
            linkedCount += 1
        }
        Log.info("[AppCoordinator] Linked comment \(commentId.value) to \(linkedCount) segments", category: .app)
    }

    /// Remove a comment link from multiple segments
    public func removeCommentFromSegments(segmentIds: [SegmentID], commentId: SegmentCommentID) async throws {
        var removedCount = 0
        for segmentId in segmentIds {
            if try await isRewindSegment(segmentId: segmentId) {
                continue
            }
            try await services.database.removeCommentFromSegment(segmentId: segmentId, commentId: commentId)
            removedCount += 1
        }
        Log.info("[AppCoordinator] Removed comment \(commentId.value) from \(removedCount) segments", category: .app)
    }

    /// Get comments linked to a segment
    public func getCommentsForSegment(segmentId: SegmentID) async throws -> [SegmentComment] {
        try await services.database.getCommentsForSegment(segmentId: segmentId)
    }

    /// Get all linked comments with representative segment context (Retrace DB only).
    public func getAllCommentTimelineEntries() async throws -> [(
        comment: SegmentComment,
        segmentID: SegmentID,
        appBundleID: String?,
        appName: String?,
        browserURL: String?,
        referenceTimestamp: Date
    )] {
        try await services.database.getAllCommentTimelineEntries()
    }

    /// Search comments by body text (server-side, capped result set).
    public func searchSegmentComments(query: String, limit: Int = 10, offset: Int = 0) async throws -> [SegmentComment] {
        try await services.database.searchSegmentComments(query: query, limit: limit, offset: offset)
    }

    /// Search comments with representative segment context (All Comments view).
    public func searchCommentTimelineEntries(
        query: String,
        limit: Int = 10,
        offset: Int = 0
    ) async throws -> [(
        comment: SegmentComment,
        segmentID: SegmentID,
        appBundleID: String?,
        appName: String?,
        browserURL: String?,
        referenceTimestamp: Date
    )] {
        try await services.database.searchCommentTimelineEntries(query: query, limit: limit, offset: offset)
    }

    /// Update an existing comment
    public func updateSegmentComment(
        commentId: SegmentCommentID,
        body: String,
        attachments: [SegmentCommentAttachment],
        author: String? = nil
    ) async throws {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else {
            throw DatabaseError.constraintViolation(underlying: "Comment body cannot be empty")
        }

        try await services.database.updateSegmentComment(
            commentId: commentId,
            body: trimmedBody,
            author: resolvedCommentAuthor(author),
            attachments: attachments
        )
    }

    /// Delete a comment and all of its segment links
    public func deleteSegmentComment(commentId: SegmentCommentID) async throws {
        try await services.database.deleteSegmentComment(commentId: commentId)
    }

    /// Get the number of linked segments for a comment
    public func getSegmentCountForComment(commentId: SegmentCommentID) async throws -> Int {
        try await services.database.getSegmentCountForComment(commentId: commentId)
    }

    /// Resolve the oldest linked segment for a comment.
    public func getFirstLinkedSegmentForComment(commentId: SegmentCommentID) async throws -> SegmentID? {
        try await services.database.getFirstLinkedSegmentForComment(commentId: commentId)
    }

    /// Resolve the oldest frame in a segment.
    public func getFirstFrameForSegment(segmentId: SegmentID) async throws -> FrameID? {
        try await services.database.getFirstFrameForSegment(segmentId: segmentId)
    }

    private nonisolated func resolvedCommentAuthor(_ proposedAuthor: String?) -> String {
        if let proposedAuthor {
            let trimmed = proposedAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        let fallback = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "Unknown User" : fallback
    }

    // MARK: - Text Region Retrieval

    /// Get text regions for a frame (OCR bounding boxes)
    public func getTextRegions(frameID: FrameID) async throws -> [TextRegion] {
        // Get frame dimensions first
        // For now, use default dimensions - this should be improved to get actual frame size
        let nodes = try await services.database.getNodes(frameID: frameID, frameWidth: 1920, frameHeight: 1080)

        // Convert OCRNode to TextRegion
        return nodes.map { node in
            TextRegion(
                id: node.id,
                frameID: frameID,
                text: "", // Text not available from getNodes, use getNodesWithText if needed
                bounds: node.bounds,
                confidence: nil,
                createdAt: Date() // Not stored in node
            )
        }
    }

    // MARK: - Frame Deletion

    /// Delete a single frame from the database
    /// Note: For Rewind data, this only removes the database entry. Video files remain on disk.
    public func deleteFrame(frameID: FrameID, timestamp: Date, source: FrameSource) async throws {
        if source == .native {
            // Keep native frame, OCR, search-index and queue cleanup atomic even
            // when the timeline has an adapter attached.
            try await services.database.deleteFrame(id: frameID)
            Log.info("[AppCoordinator] Deleted native frame \(frameID.stringValue)", category: .app)
            return
        }

        guard let adapter = await services.dataAdapter else {
            throw AppError.notInitialized
        }

        // For Rewind frames, use timestamp-based deletion (more reliable than synthetic UUIDs)
        if source == .rewind {
            try await adapter.deleteFrameByTimestamp(timestamp, source: source)
        } else {
            try await adapter.deleteFrame(frameID: frameID, source: source)
        }

        Log.info("[AppCoordinator] Deleted frame from \(source.displayName)", category: .app)
    }

    /// Delete multiple frames from the database
    /// Groups by source and uses appropriate deletion method for each
    public func deleteFrames(_ frames: [FrameReference]) async throws {
        guard !frames.isEmpty else { return }

        // For Rewind frames, delete by timestamp (more reliable)
        // For native frames, delete by ID
        for frame in frames {
            try await deleteFrame(
                frameID: frame.id,
                timestamp: frame.timestamp,
                source: frame.source
            )
        }

        Log.info("[AppCoordinator] Deleted \(frames.count) frames", category: .app)
    }

    // MARK: - URL Bounding Box Detection

    /// Get the bounding box of a browser URL on screen for a given frame
    /// Returns the bounding box with normalized coordinates (0.0-1.0) if found
    /// Use this to highlight clickable URLs in the timeline view
    public func getURLBoundingBox(timestamp: Date, source: FrameSource) async throws -> URLBoundingBox? {
        guard let adapter = await services.dataAdapter else {
            return nil
        }

        return try await adapter.getURLBoundingBox(timestamp: timestamp, source: source)
    }

    // MARK: - OCR Node Detection (for text selection)

    /// Get all OCR nodes for a given frame by timestamp
    /// Returns array of nodes with normalized bounding boxes (0.0-1.0) and text content
    /// Use this to enable text selection highlighting in the timeline view
    public func getAllOCRNodes(timestamp: Date, source: FrameSource) async throws -> [OCRNodeWithText] {
        guard let adapter = await services.dataAdapter else {
            return []
        }

        return try await adapter.getAllOCRNodes(timestamp: timestamp, source: source)
    }

    /// Get all OCR nodes for a given frame by frameID (more reliable than timestamp)
    /// Returns array of nodes with normalized bounding boxes (0.0-1.0) and text content
    /// Use this for search results where you have the exact frameID
    public func getAllOCRNodes(frameID: FrameID, source: FrameSource) async throws -> [OCRNodeWithText] {
        guard let adapter = await services.dataAdapter else {
            return []
        }

        return try await adapter.getAllOCRNodes(frameID: frameID, source: source)
    }

    // MARK: - OCR Status

    /// Get the OCR processing status for a specific frame
    /// Returns the processing status combined with queue information
    public func getOCRStatus(frameID: FrameID) async throws -> OCRProcessingStatus {
        let statusInt = try await services.database.getFrameProcessingStatus(frameID: frameID.value)

        guard let status = statusInt else {
            return .unknown
        }

        switch status {
        case 0: // pending
            // Check if in queue and get position
            let queuePosition = try await services.database.getFrameQueuePosition(frameID: frameID.value)
            if queuePosition != nil {
                return .queued(position: queuePosition, depth: nil)
            }
            return .pending
        case 1: // processing
            return .processing
        case 2: // completed
            return .completed
        case 3: // failed
            return .failed
        default:
            return .unknown
        }
    }

    // MARK: - OCR Reprocessing

    /// Reprocess OCR for a specific frame
    /// This clears existing OCR data and re-enqueues the frame for processing
    public func reprocessOCR(frameID: FrameID) async throws {
        Log.info("[OCR-REPROCESS] Starting reprocess for frame \(frameID.value)", category: .processing)

        // Record OCR reprocess metric
        try? await recordMetricEvent(metricType: .ocrReprocessRequests, metadata: "\(frameID.value)")

        // Clear existing OCR nodes for this frame
        try await services.database.deleteNodes(frameID: frameID)
        Log.info("[OCR-REPROCESS] Deleted nodes for frame \(frameID.value)", category: .processing)

        // Clear existing FTS entry for this frame
        try await services.database.deleteFTSContent(frameId: frameID.value)
        Log.info("[OCR-REPROCESS] Deleted FTS content for frame \(frameID.value)", category: .processing)

        // Reset processingStatus to 0 (pending) so frame can be re-enqueued
        try await services.database.updateFrameProcessingStatus(frameID: frameID.value, status: 0)
        Log.info("[OCR-REPROCESS] Reset processingStatus to pending for frame \(frameID.value)", category: .processing)

        // Enqueue for reprocessing with high priority
        guard let queue = await services.processingQueue else {
            Log.error("[OCR-REPROCESS] Processing queue not available!", category: .processing)
            throw AppError.processingQueueNotAvailable
        }

        // Check queue depth before enqueue
        let depthBefore = try await queue.getQueueDepth()
        Log.info("[OCR-REPROCESS] Queue depth before enqueue: \(depthBefore)", category: .processing)

        try await queue.enqueue(frameID: frameID.value, priority: 100)

        // Check queue depth after enqueue
        let depthAfter = try await queue.getQueueDepth()
        Log.info("[OCR-REPROCESS] Frame \(frameID.value) enqueued with priority 100, queue depth now: \(depthAfter)", category: .processing)
    }

    /// Run legacy maintenance only after recovery releases the capture database.
    /// Each tick visits a bounded, durable node page; empty pages do not mean the
    /// whole library has been repaired. The first delay leaves startup work first.
    func startLegacyOCRNodeTextMaintenance(interval: Duration = .seconds(60)) {
        guard legacyOCRNodeTextMaintenanceTask == nil else { return }
        legacyOCRNodeTextMaintenanceTask = Task(priority: .background) { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval, clock: .continuous)
                } catch { return }
                guard !Task.isCancelled, let self else { return }
                await self.enqueueLegacyOCRNodeTextBackfillIfNeeded()
            }
        }
    }

    func stopLegacyOCRNodeTextMaintenance() async {
        legacyOCRNodeTextMaintenanceTask?.cancel()
        await legacyOCRNodeTextMaintenanceTask?.value
        legacyOCRNodeTextMaintenanceTask = nil
    }

    /// Queue one bounded maintenance page without scanning/counting the library.
    func enqueueLegacyOCRNodeTextBackfillIfNeeded() async {
        do {
            try Task.checkCancellation()
            let limit = Self.startupOCRNodeTextBackfillBatchLimit
            try? await recordMetricEvent(
                metricType: .ocrNodeTextBackfillStarted,
                metadata: "mode=maintenance;limit=\(limit);nodePageSize=1000"
            )

            let frameIDs = try await services.database.enqueueLegacyOCRNodeTextBackfill(
                limit: limit,
                priority: Self.startupOCRNodeTextBackfillPriority,
                maxQueueDepth: Self.startupOCRNodeTextBackfillQueueCapacity,
                nodePageSize: 1000
            )
            try? await recordMetricEvent(
                metricType: .ocrNodeTextBackfillCompleted,
                metadata: "mode=maintenance;enqueued=\(frameIDs.count);status=page_checked"
            )

            Log.info("[OCR-BACKFILL] Bounded maintenance page checked; enqueued=\(frameIDs.count)", category: .processing)
        } catch is CancellationError {
            return
        } catch {
            Log.error("[OCR-BACKFILL] Bounded OCR node-text maintenance failed", category: .processing, error: error)
            try? await recordMetricEvent(
                metricType: .ocrNodeTextBackfillCompleted,
                metadata: "mode=maintenance;enqueued=0;status=failed;error=\(error.localizedDescription)"
            )
        }
    }

    // MARK: - Migration

    /// Import data from Rewind AI
    public func importFromRewind(
        chunkDirectory: String,
        progressHandler: @escaping @Sendable (MigrationProgress) -> Void
    ) async throws {
        Log.info("Starting Rewind import from: \(chunkDirectory)", category: .app)

        // Setup migration manager with default importers (includes RewindImporter)
        await services.migration.setupDefaultImporters()

        // Create delegate to forward progress
        let delegate = MigrationProgressDelegate(progressHandler: progressHandler)

        // Start import
        try await services.migration.startImport(
            source: .rewind,
            delegate: delegate
        )

        Log.info("Rewind import completed", category: .app)
    }

    // MARK: - Calendar Support

    /// Get all distinct dates that have frames (for calendar display)
    /// Uses filesystem (chunks folder structure) instead of slow database queries
    /// Checks both Retrace chunks and Rewind chunks (if Rewind is connected)
    public func getDistinctDates() async throws -> [Date] {
        var allDates = Set<Date>()

        // Get dates from Retrace chunks folder
        let retraceRoot = await services.storage.getStorageDirectory()
        let retraceDates = getDatesFromChunksFolder(at: retraceRoot.appendingPathComponent("chunks"))
        allDates.formUnion(retraceDates)

        // Get dates from Rewind chunks folder if connected
        // Uses rewindStorageRootPath which returns nil if Rewind not connected
        if let adapter = await services.dataAdapter,
           let rewindPath = await adapter.rewindStorageRootPath {
            let rewindChunks = URL(fileURLWithPath: rewindPath).appendingPathComponent("chunks")
            let rewindDates = getDatesFromChunksFolder(at: rewindChunks)
            allDates.formUnion(rewindDates)
        }

        return Array(allDates).sorted { $0 > $1 }
    }

    /// Extract dates from chunks folder structure (chunks/YYYYMM/DD/)
    private func getDatesFromChunksFolder(at chunksURL: URL) -> Set<Date> {
        var dates = Set<Date>()
        let fileManager = FileManager.default
        let calendar = Calendar.current

        guard let yearMonthFolders = try? fileManager.contentsOfDirectory(
            at: chunksURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return dates
        }

        for yearMonthFolder in yearMonthFolders {
            let yearMonthStr = yearMonthFolder.lastPathComponent
            guard yearMonthStr.count == 6,
                  let year = Int(yearMonthStr.prefix(4)),
                  let month = Int(yearMonthStr.suffix(2)) else {
                continue
            }

            guard let dayFolders = try? fileManager.contentsOfDirectory(
                at: yearMonthFolder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for dayFolder in dayFolders {
                let dayStr = dayFolder.lastPathComponent
                guard let day = Int(dayStr) else { continue }

                if let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) {
                    dates.insert(date)
                }
            }
        }

        return dates
    }

    // MARK: - Storage Statistics

    /// Get total storage used in bytes (Retrace + Rewind if enabled)
    public func getTotalStorageUsed() async throws -> Int64 {
        // Check if Rewind is enabled via DataAdapter
        let includeRewind = await services.dataAdapter?.rewindStorageRootPath != nil
        return try await services.storage.getTotalStorageUsed(includeRewind: includeRewind)
    }

    /// Get storage used for a specific date range
    public func getStorageUsedForDateRange(from startDate: Date, to endDate: Date) async throws -> Int64 {
        try await services.storage.getStorageUsedForDateRange(from: startDate, to: endDate)
    }

    /// Get total captured duration across all Retrace segments in seconds
    /// Only counts time captured by Retrace (excludes imported Rewind data)
    public func getTotalCapturedDuration() async throws -> TimeInterval {
        try await services.database.getTotalCapturedDuration()
    }

    /// Get captured duration for Retrace segments starting after a given date
    public func getCapturedDurationAfter(date: Date) async throws -> TimeInterval {
        try await services.database.getCapturedDurationAfter(date: date)
    }

    /// Get distinct hours for a specific date that have frames
    /// Uses DataAdapter to query the appropriate database (Retrace or Rewind) based on date
    public func getDistinctHoursForDate(_ date: Date) async throws -> [Date] {
        if let adapter = await services.dataAdapter {
            return try await adapter.getDistinctHoursForDate(date)
        }
        // Fallback to Retrace-only query
        return try await services.database.getDistinctHoursForDate(date)
    }

    // MARK: - Daily Metrics

    /// Record a single metric event (timeline open, search, text copy)
    public func recordMetricEvent(
        metricType: DailyMetricsQueries.MetricType,
        timestamp: Date = Date(),
        metadata: String? = nil
    ) async throws {
        try await services.database.recordMetricEvent(
            metricType: metricType,
            timestamp: timestamp,
            metadata: metadata
        )
    }

    /// Get daily counts for a metric type (for 7-day graphs)
    /// Returns array of (date, count) tuples sorted by date ascending
    public func getDailyMetrics(
        metricType: DailyMetricsQueries.MetricType,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(date: Date, value: Int64)] {
        try await services.database.getDailyMetrics(
            metricType: metricType,
            from: startDate,
            to: endDate
        )
    }

    /// Get daily screen time totals (for 7-day graphs)
    /// Returns array of (date, totalSeconds) tuples sorted by date ascending
    public func getDailyScreenTime(
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(date: Date, value: Int64)] {
        try await services.database.getDailyScreenTime(
            from: startDate,
            to: endDate
        )
    }

    // MARK: - Statistics & Monitoring

    /// Check if screen capture is currently active
    public func isCapturing() async -> Bool {
        await services.capture.isCapturing
    }

    /// Get comprehensive app statistics
    public func getStatistics() async throws -> AppStatistics {
        let dbStats = try await services.getDatabaseStats()
        let searchStats = await services.getSearchStats()
        let captureStats = await services.getCaptureStats()
        let processingStats = await services.getProcessingStats()

        let uptime: TimeInterval?
        if let startTime = pipelineStartTime {
            uptime = Date().timeIntervalSince(startTime)
        } else {
            uptime = nil
        }

        return AppStatistics(
            isRunning: isRunning,
            uptime: uptime,
            totalFramesProcessed: totalFramesProcessed,
            totalErrors: totalErrors,
            database: dbStats,
            search: searchStats,
            capture: captureStats,
            processing: processingStats
        )
    }

    /// Get database statistics for feedback/diagnostics
    public func getDatabaseStatistics() async throws -> DatabaseStatistics {
        try await services.getDatabaseStats()
    }

    /// Get app session count (distinct from video segment count)
    public func getAppSessionCount() async throws -> Int {
        try await services.getAppSessionCount()
    }

    /// Get quick database statistics (single query, for feedback diagnostics)
    public func getDatabaseStatisticsQuick() async throws -> (frameCount: Int, sessionCount: Int) {
        try await services.getDatabaseStatsQuick()
    }

    /// Get current pipeline status
    public func getStatus() -> PipelineStatus {
        PipelineStatus(
            isRunning: isRunning,
            framesProcessed: totalFramesProcessed,
            errors: totalErrors,
            startTime: pipelineStartTime
        )
    }

    // MARK: - Maintenance

    /// Cleanup old data (older than specified date)
    public func cleanupOldData(olderThan date: Date) async throws -> CleanupResult {
        Log.info("Starting cleanup for data older than \(date)", category: .app)

        // Delete old frames from database
        let deletedFrameCount = try await services.database.deleteFrames(olderThan: date)

        // Delete old segments from storage
        let deletedSegmentIDs = try await services.storage.cleanupOldSegments(olderThan: date)

        // Delete corresponding segments from database
        for segmentID in deletedSegmentIDs {
            try await services.database.deleteVideoSegment(id: segmentID)
        }

        // Vacuum database to reclaim space
        try await services.database.vacuum()

        Log.info("Cleanup complete. Deleted \(deletedFrameCount) frames, \(deletedSegmentIDs.count) segments", category: .app)

        return CleanupResult(
            deletedFrames: deletedFrameCount,
            deletedSegments: deletedSegmentIDs.count,
            reclaimedBytes: 0 // TODO: Calculate actual reclaimed space
        )
    }

    /// Delete recent data (newer than specified date) - used for quick delete feature
    /// This deletes all frames captured after the cutoff date
    public func deleteRecentData(newerThan date: Date) async throws -> CleanupResult {
        Log.info("Starting quick delete for data newer than \(date)", category: .app)

        // Delete recent frames from database
        let deletedFrameCount = try await services.database.deleteFrames(newerThan: date)

        // Note: Video segments are not deleted here because they may contain older frames too
        // The storage cleanup based on retention policy will handle orphaned segments

        // Vacuum database to reclaim space
        try await services.database.vacuum()

        Log.info("Quick delete complete. Deleted \(deletedFrameCount) frames", category: .app)

        return CleanupResult(
            deletedFrames: deletedFrameCount,
            deletedSegments: 0, // Segments are not deleted in quick delete
            reclaimedBytes: 0
        )
    }

    /// Rebuild the search index
    public func rebuildSearchIndex() async throws {
        Log.info("Rebuilding search index...", category: .app)
        try await services.search.rebuildIndex()
        Log.info("Search index rebuild complete", category: .app)
    }

    /// Run database maintenance (checkpoint WAL, analyze)
    public func runDatabaseMaintenance() async throws {
        Log.info("Running database maintenance...", category: .app)

        try await services.database.checkpoint()
        try await services.database.analyze()

        Log.info("Database maintenance complete", category: .app)
    }

    /// Get database schema description for debugging
    public func getDatabaseSchemaDescription() async throws -> String {
        try await services.database.getSchemaDescription()
    }
}

// MARK: - Supporting Types

public struct AppStatistics: Sendable {
    public let isRunning: Bool
    public let uptime: TimeInterval?
    public let totalFramesProcessed: Int
    public let totalErrors: Int
    public let database: DatabaseStatistics
    public let search: SearchStatistics
    public let capture: CaptureStatistics
    public let processing: ProcessingStatistics
}

public struct PipelineStatus: Sendable {
    public let isRunning: Bool
    public let framesProcessed: Int
    public let errors: Int
    public let startTime: Date?
}

public struct CleanupResult: Sendable {
    public let deletedFrames: Int
    public let deletedSegments: Int
    public let reclaimedBytes: Int64
}

/// OCR processing status for a frame
/// Provides detailed status information for UI display
public struct OCRProcessingStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// OCR completed successfully - text is available
        case completed
        /// Frame is pending but not yet in processing queue
        case pending
        /// Frame is in the processing queue waiting to be processed
        case queued
        /// Frame is currently being processed (OCR in progress)
        case processing
        /// OCR failed permanently
        case failed
        /// Frame not found or status unknown
        case unknown
    }

    public let state: State
    /// Position in queue (1 = next to be processed), nil if not in queue
    public let queuePosition: Int?
    /// Total items in the queue
    public let queueDepth: Int?

    public init(state: State, queuePosition: Int? = nil, queueDepth: Int? = nil) {
        self.state = state
        self.queuePosition = queuePosition
        self.queueDepth = queueDepth
    }

    /// Human-readable description for display
    public var displayText: String {
        switch state {
        case .completed: return "OCR Complete"
        case .pending: return "Indexing text..."
        case .queued:
            if let position = queuePosition {
                return "Queued #\(position)"
            }
            return "Queued"
        case .processing: return "Indexing..."
        case .failed: return "OCR Failed"
        case .unknown: return ""
        }
    }

    /// Whether OCR is still in progress (queued or processing)
    public var isInProgress: Bool {
        switch state {
        case .queued, .processing, .pending:
            return true
        case .completed, .failed, .unknown:
            return false
        }
    }

    // Convenience static constructors
    public static let completed = OCRProcessingStatus(state: .completed)
    public static let pending = OCRProcessingStatus(state: .pending)
    public static let processing = OCRProcessingStatus(state: .processing)
    public static let failed = OCRProcessingStatus(state: .failed)
    public static let unknown = OCRProcessingStatus(state: .unknown)

    public static func queued(position: Int?, depth: Int?) -> OCRProcessingStatus {
        OCRProcessingStatus(state: .queued, queuePosition: position, queueDepth: depth)
    }
}

public enum AppError: Error {
    case permissionDenied(permission: String)
    case notInitialized
    case alreadyRunning
    case notRunning
    case processingQueueNotAvailable
}

// MARK: - Migration Delegate

/// Simple delegate wrapper to forward progress updates to a closure
private final class MigrationProgressDelegate: MigrationDelegate, @unchecked Sendable {
    private let progressHandler: @Sendable (MigrationProgress) -> Void

    init(progressHandler: @escaping @Sendable (MigrationProgress) -> Void) {
        self.progressHandler = progressHandler
    }

    func migrationDidUpdateProgress(_ progress: MigrationProgress) {
        progressHandler(progress)
    }

    func migrationDidStartProcessingVideo(at path: String, index: Int, total: Int) {
        Log.debug("Started processing video \(index)/\(total): \(path)", category: .app)
    }

    func migrationDidFinishProcessingVideo(at path: String, framesImported: Int) {
        Log.debug("Finished processing video: \(path) (\(framesImported) frames)", category: .app)
    }

    func migrationDidFailProcessingVideo(at path: String, error: Error) {
        Log.error("[Migration] Failed processing video: \(path)", category: .app, error: error)
    }

    func migrationDidComplete(result: MigrationResult) {
        Log.info("Migration completed: \(result.framesImported) frames imported", category: .app)
    }

    func migrationDidFail(error: Error) {
        Log.error("[Migration] Failed", category: .app, error: error)
    }
}
