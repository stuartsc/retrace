import Foundation
import Shared
import Database
import Storage
import Search
import AppKit
import Darwin

struct FrameProcessingMemorySnapshot: Equatable {
    let residentBytes: UInt64
    let ownedHeapBytes: UInt64?
}

enum FrameProcessingMemoryBackoffPolicy {
    static func shouldBackOff(
        snapshot: FrameProcessingMemorySnapshot?,
        residentLimitBytes: UInt64,
        ownedHeapLimitBytes: UInt64
    ) -> Bool {
        guard let snapshot, snapshot.residentBytes >= residentLimitBytes else {
            return false
        }

        guard let ownedHeapBytes = snapshot.ownedHeapBytes else {
            return true
        }

        return ownedHeapBytes >= ownedHeapLimitBytes
    }
}

/// Asynchronous frame processing queue with SQLite-backed durability
///
/// Features:
/// - Durable queue (survives app restarts)
/// - Concurrent worker pool for OCR processing
/// - Automatic retry on failure
/// - Backpressure monitoring
public actor FrameProcessingQueue {

    // MARK: - Properties

    private let databaseManager: DatabaseManager
    private let storage: StorageProtocol
    private let processing: ProcessingProtocol
    private let search: SearchProtocol
    private let governor: (any BackgroundProcessingProtocol)?
    private var pendingAdmissions: [FrameProcessingLane: (id: UUID, task: Task<Void, Never>)] = [:]
    private var readyAdmissions: [FrameProcessingLane: BackgroundProcessingPermit] = [:]
    private var consecutiveFreshAdmissions = 0

    private let config: ProcessingQueueConfig
    private var workers: [Task<Void, Never>] = []
    private var isRunning = false
    private var memoryReportTask: Task<Void, Never>?
    private let wakeSignal = FrameProcessingWakeSignal()

    // Statistics
    private var totalProcessed: Int = 0
    private var totalFailed: Int = 0
    private var currentQueueDepth: Int = 0
    private var pendingCount: Int = 0      // Frames with status 0
    private var processingCount: Int = 0   // Frames with status 1

    private let memoryReportIntervalNs: UInt64 = 5_000_000_000
    private let startupBackfillDelaySeconds: TimeInterval = 15
    private let softResidentMemoryLimitBytes: UInt64 = 2_000_000_000
    private let softOwnedHeapMemoryLimitBytes: UInt64 = 2_000_000_000
    private let memoryBackoffSeconds: TimeInterval = 5

    // MARK: - Power-Aware Processing Control

    /// Whether OCR processing is enabled globally
    private var ocrEnabled = true

    /// Whether to pause OCR when on battery power
    private var pauseOnBattery = false

    /// Whether to pause OCR when Low Power Mode is enabled
    private var pauseOnLowPowerMode = false

    /// Current power source (updated by AppCoordinator)
    private var currentPowerSource: PowerStateMonitor.PowerSource = .unknown

    /// Whether Low Power Mode is currently enabled
    private var isLowPowerModeEnabled = false

    /// Whether OCR is currently paused due to battery or low power mode policy
    private var isPausedForPowerState: Bool {
        (pauseOnBattery && currentPowerSource == .battery) ||
        (pauseOnLowPowerMode && isLowPowerModeEnabled)
    }

    /// Minimum delay between processing frames (for rate limiting)
    /// 0 = no delay (unlimited), otherwise nanoseconds between frames
    private var minDelayBetweenFramesNs: UInt64 = 0

    /// Task priority for worker tasks
    private var workerPriority: TaskPriority = .utility

    /// Bundle IDs to exclude from OCR (when ocrAppFilterMode == .allExceptTheseApps)
    private var ocrExcludedBundleIDs: Set<String> = []

    /// Bundle IDs to include for OCR (when ocrAppFilterMode == .onlyTheseApps)
    /// Empty set means all apps (default behavior)
    private var ocrIncludedBundleIDs: Set<String> = []

    // MARK: - Initialization

    public init(
        database: DatabaseManager,
        storage: StorageProtocol,
        processing: ProcessingProtocol,
        search: SearchProtocol,
        config: ProcessingQueueConfig = .default,
        governor: (any BackgroundProcessingProtocol)? = nil
    ) {
        self.databaseManager = database
        self.storage = storage
        self.processing = processing
        self.search = search
        self.config = config
        self.governor = governor
    }

    // MARK: - Power Configuration

    /// Update power-aware processing configuration
    /// Called by AppCoordinator when power state or settings change
    public func updatePowerConfig(
        ocrEnabled: Bool,
        pauseOnBattery: Bool,
        pauseOnLowPowerMode: Bool,
        isLowPowerModeEnabled: Bool,
        currentPowerSource: PowerStateMonitor.PowerSource,
        maxFPS: Double,
        workerCount: Int,
        taskPriority: TaskPriority,
        excludedBundleIDs: Set<String>,
        includedBundleIDs: Set<String>
    ) {
        self.ocrEnabled = ocrEnabled
        self.pauseOnBattery = pauseOnBattery
        self.pauseOnLowPowerMode = pauseOnLowPowerMode
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.currentPowerSource = currentPowerSource
        self.ocrExcludedBundleIDs = excludedBundleIDs
        self.ocrIncludedBundleIDs = includedBundleIDs

        // Convert FPS to nanosecond delay (0 = unlimited)
        if maxFPS > 0 {
            self.minDelayBetweenFramesNs = UInt64(1_000_000_000.0 / maxFPS)
        } else {
            self.minDelayBetweenFramesNs = 0
        }

        // Update priority and restart workers if priority changed
        // Governed OCR has one stable worker. Preference changes must not replace
        // an in-flight native worker and lose its joined shutdown ownership.
        let effectivePriority: TaskPriority = governor == nil ? taskPriority : .utility
        let effectiveCount = governor == nil ? workerCount : 1
        let priorityChanged = self.workerPriority != effectivePriority
        self.workerPriority = effectivePriority

        // Adjust worker count or restart if priority changed
        if isRunning {
            if priorityChanged {
                // Must restart all workers to apply new priority
                restartWorkers(count: effectiveCount)
            } else if workers.count != effectiveCount {
                adjustWorkerCount(to: effectiveCount)
            }
        }

        Log.info(
            "[Queue] Power config updated: ocrEnabled=\(ocrEnabled), pauseOnBattery=\(pauseOnBattery), pauseOnLowPowerMode=\(pauseOnLowPowerMode), isLowPowerModeEnabled=\(isLowPowerModeEnabled), power=\(currentPowerSource), maxFPS=\(maxFPS), workers=\(workers.count), priority=\(taskPriority), paused=\(isPausedForPowerState)",
            category: .processing
        )
    }

    /// Adjust the number of running workers to the desired count
    private func adjustWorkerCount(to desired: Int) {
        let current = workers.count
        if desired > current {
            // Spawn additional workers
            for workerID in current..<desired {
                let priority = workerPriority
                let task = Task(priority: priority) {
                    await runWorker(id: workerID)
                }
                workers.append(task)
            }
            Log.info("[Queue] Scaled up workers: \(current) → \(desired)", category: .processing)
        } else if desired < current {
            // Cancel excess workers from the end
            for _ in desired..<current {
                workers.removeLast().cancel()
            }
            Log.info("[Queue] Scaled down workers: \(current) → \(desired)", category: .processing)
        }
    }

    /// Restart all workers with current priority and desired count
    private func restartWorkers(count: Int) {
        // Cancel all existing workers
        for worker in workers {
            worker.cancel()
        }
        workers.removeAll()

        // Spawn new workers with updated priority
        let priority = workerPriority
        for workerID in 0..<count {
            let task = Task(priority: priority) {
                await runWorker(id: workerID)
            }
            workers.append(task)
        }
        Log.info("[Queue] Restarted \(count) workers with priority \(priority)", category: .processing)
    }

    /// Check if OCR should be processed for a specific bundle ID
    private func shouldProcessOCR(forBundleID bundleID: String?) -> Bool {
        guard let bundleID = bundleID else {
            Log.debug("[Queue-Filter] bundleID is nil, allowing OCR", category: .processing)
            return true
        }

        // If inclusion list is set (onlyTheseApps mode), only process those apps
        if !ocrIncludedBundleIDs.isEmpty {
            let allowed = ocrIncludedBundleIDs.contains(bundleID)
            Log.debug("[Queue-Filter] Include mode: bundleID=\(bundleID), allowed=\(allowed), includedApps=\(ocrIncludedBundleIDs)", category: .processing)
            return allowed
        }

        // Otherwise, process all except excluded apps
        let allowed = !ocrExcludedBundleIDs.contains(bundleID)
        if !ocrExcludedBundleIDs.isEmpty {
            Log.debug("[Queue-Filter] Exclude mode: bundleID=\(bundleID), allowed=\(allowed), excludedApps=\(ocrExcludedBundleIDs)", category: .processing)
        }
        return allowed
    }

    // MARK: - Queue Operations

    /// Enqueue a frame for processing
    /// - Parameters:
    ///   - frameID: The database ID of the frame
    ///   - priority: Processing priority (higher = processed first)
    public func enqueue(frameID: Int64, priority: Int = 10) async throws {
        let inserted = try await databaseManager.enqueueFrameForProcessing(frameID: frameID, priority: priority)
        if inserted { currentQueueDepth += 1 }
        await wakeSignal.notify()
        // Log.info("[Queue-DIAG] Successfully enqueued frame \(frameID), local depth: \(currentQueueDepth), isRunning: \(isRunning)", category: .processing)
    }

    /// Enqueue multiple frames (batch operation)
    public func enqueueBatch(frameIDs: [Int64], priority: Int = 0) async throws {
        for frameID in frameIDs {
            try await enqueue(frameID: frameID, priority: priority)
        }
    }

    /// Dequeue the next frame for processing
    private func dequeue() async throws -> QueuedFrame? {
        guard let result = try await databaseManager.dequeueFrameForProcessing() else {
            return nil // Queue empty
        }
        currentQueueDepth = max(0, currentQueueDepth - 1)
        return QueuedFrame(queueID: result.queueID, frameID: result.frameID, retryCount: result.retryCount)
    }

    private func dequeueAdmitted() async throws -> (QueuedFrame, BackgroundProcessingPermit?)? {
        guard let governor else { return try await dequeue().map { ($0, nil) } }
        let available = try await databaseManager.pendingFrameProcessingLanes()
        for lane in Array(pendingAdmissions.keys) where !available.contains(lane) {
            let pending = pendingAdmissions.removeValue(forKey: lane)
            pending?.task.cancel()
            if let permit = readyAdmissions.removeValue(forKey: lane) {
                permit.cancellation.cancel()
                await governor.release(permit)
            }
            await pending?.task.value
        }
        let lanes: [FrameProcessingLane] = consecutiveFreshAdmissions >= 3
            ? [.manual, .historical, .current] : [.manual, .current, .historical]
        for lane in lanes where available.contains(lane) {
            try Task.checkCancellation()
            guard let permit = readyAdmissions.removeValue(forKey: lane) else {
                if pendingAdmissions[lane] == nil {
                    let id = UUID()
                    let kind: BackgroundProcessingKind = lane == .current ? .freshOCR : .historicalOCR
                    let task = Task { [weak self] in
                        do {
                            let permit = try await BackgroundProcessingContext.$explicitRequest.withValue(lane == .manual) {
                                try await governor.acquire(kind)
                            }
                            guard let self else { await governor.release(permit); return }
                            await self.receiveAdmission(permit, lane: lane, id: id)
                        } catch {
                            await self?.admissionFailed(lane: lane, id: id)
                        }
                    }
                    pendingAdmissions[lane] = (id, task)
                }
                continue
            }
            let admitted = pendingAdmissions.removeValue(forKey: lane)
            await admitted?.task.value
            do {
                try Task.checkCancellation()
                guard !permit.cancellation.isCancelled else { throw CancellationError() }
                guard let result = try await databaseManager.dequeueFrameForProcessing(lane: lane) else {
                    await governor.release(permit)
                    continue
                }
                currentQueueDepth = max(0, currentQueueDepth - 1)
                if lane == .current { consecutiveFreshAdmissions = min(3, consecutiveFreshAdmissions + 1) }
                if lane == .historical { consecutiveFreshAdmissions = 0 }
                return (QueuedFrame(queueID: result.queueID, frameID: result.frameID,
                                    retryCount: result.retryCount, lane: lane), permit)
            } catch {
                await governor.release(permit)
                if error is CancellationError, !Task.isCancelled { continue }
                throw error
            }
        }
        return nil
    }

    private func receiveAdmission(_ permit: BackgroundProcessingPermit, lane: FrameProcessingLane, id: UUID) async {
        guard isRunning, pendingAdmissions[lane]?.id == id, !Task.isCancelled else {
            permit.cancellation.cancel()
            await governor?.release(permit)
            return
        }
        readyAdmissions[lane] = permit
        await wakeSignal.notify()
    }

    private func admissionFailed(lane: FrameProcessingLane, id: UUID) async {
        if pendingAdmissions[lane]?.id == id { pendingAdmissions.removeValue(forKey: lane) }
        // A closed/full governor retries on the worker's bounded one-second
        // cadence, never a failure-notify-retry loop that burns the CPU budget.
    }

    private func clearAdmissions() async {
        let requests = Array(pendingAdmissions.values)
        let permits = Array(readyAdmissions.values)
        pendingAdmissions.removeAll(); readyAdmissions.removeAll()
        requests.forEach { $0.task.cancel() }
        for permit in permits {
            permit.cancellation.cancel()
            await governor?.release(permit)
        }
        for request in requests { await request.task.value }
    }

    private func processAdmittedFrame(_ frame: QueuedFrame, permit: BackgroundProcessingPermit?) async throws -> ProcessFrameResult {
        do {
            let result = try await BackgroundProcessingContext.$permit.withValue(permit) {
                try BackgroundProcessingContext.checkCancellation()
                return try await processFrame(frame)
            }
            if let permit { await governor?.release(permit) }
            return result
        } catch {
            if let permit { await governor?.release(permit) }
            throw error
        }
    }

    /// Get current queue depth
    public func getQueueDepth() async throws -> Int {
        return try await databaseManager.getProcessingQueueDepth()
    }

    // MARK: - Worker Pool

    /// Start processing workers
    public func startWorkers() async {
        guard !isRunning else {
            // Log.warning("[Queue-DIAG] Workers already running, skipping startWorkers()", category: .processing)
            return
        }

        isRunning = true

        // Initialize counts from actual frame statuses
        if let counts = try? await databaseManager.getFrameStatusCounts() {
            pendingCount = counts.pending
            processingCount = counts.processing
            currentQueueDepth = counts.pending + counts.processing
        }

        let priority = workerPriority
        for workerID in 0..<(governor == nil ? config.workerCount : 1) {
            let task = Task(priority: priority) {
                await runWorker(id: workerID)
            }
            workers.append(task)
        }

        startMemoryReporting()

        Log.info("[Queue] Started \(workers.count) workers (priority=\(priority))", category: .processing)
    }

    /// Stop processing workers
    public func stopWorkers() async {
        guard isRunning else { return }

        isRunning = false

        Log.info("[Queue] Stopping workers...", category: .processing)

        let stoppingWorkers = workers
        for worker in stoppingWorkers {
            worker.cancel()
        }

        workers.removeAll()
        await wakeSignal.notify()
        for worker in stoppingWorkers { await worker.value }
        await clearAdmissions()
        memoryReportTask?.cancel()
        memoryReportTask = nil

        Log.info("[Queue] Workers stopped", category: .processing)
    }

    /// Worker loop - processes frames from queue
    private func runWorker(id: Int) async {
        Log.info("[Queue] Worker \(id) STARTED (total workers: \(workers.count))", category: .processing)

        // Give capture/audio/dictation startup priority. OCR backlog is durable and can
        // lag briefly; launching every heavyweight pipeline at once causes memory spikes.
        try? await Task.sleep(for: .seconds(startupBackfillDelaySeconds), clock: .continuous)

        while isRunning && !Task.isCancelled {
            // Check if OCR is disabled globally
            guard ocrEnabled else {
                await clearAdmissions()
                try? await Task.sleep(for: .nanoseconds(Int64(1_000_000_000)), clock: .continuous) // 1s poll when disabled
                if Task.isCancelled { break }
                continue
            }

            // Check if paused due to battery/low-power policy
            guard !isPausedForPowerState else {
                await clearAdmissions()
                try? await Task.sleep(for: .nanoseconds(Int64(2_000_000_000)), clock: .continuous) // 2s poll when paused by power policy
                if Task.isCancelled { break }
                continue
            }

            // Wait for database to be ready before attempting any operations
            guard await databaseManager.isReady() else {
                await clearAdmissions()
                // Log.debug("[Queue-DIAG] Worker \(id) waiting for database to be ready", category: .processing)
                try? await Task.sleep(for: .nanoseconds(Int64(500_000_000)), clock: .continuous) // 500ms
                if Task.isCancelled { break }
                continue
            }

            if shouldBackOffForResidentMemory() {
                await clearAdmissions()
                try? await Task.sleep(for: .seconds(memoryBackoffSeconds), clock: .continuous)
                if Task.isCancelled { break }
                continue
            }

            do {
                // Snapshot before the database await so an enqueue cannot be lost.
                let generation = await wakeSignal.snapshot()
                guard let (queuedFrame, permit) = try await dequeueAdmitted() else {
                    await wakeSignal.wait(after: generation, timeout: .seconds(1))
                    continue
                }

                // Log.info("[Queue-DIAG] Worker \(id) dequeued frame \(queuedFrame.frameID) for processing", category: .processing)

                // Process the frame
                let startTime = Date()
                let pacingStart = ContinuousClock.now
                do {
                    let result = try await processAdmittedFrame(queuedFrame, permit: permit)

                    // Handle deferred processing result
                    if case .deferredSourceNotReady = result {
                        // Keep fresh captures eligible when their pixels arrive.
                        // The database expires automatic priority after 60 seconds
                        // of capture age, so old sources still join historical FIFO.
                        try await databaseManager.releaseFrameProcessingClaim(
                            frameID: queuedFrame.frameID, priority: queuedFrame.retryPriority, retryCount: queuedFrame.retryCount
                        )
                        currentQueueDepth += 1
                        try? await Task.sleep(for: .nanoseconds(Int64(500_000_000)), clock: .continuous) // 500ms before next attempt
                        continue
                    }

                    totalProcessed += 1
                    relieveMallocPressure()

                    let elapsed = Date().timeIntervalSince(startTime)
                    Log.info("[Queue-DIAG] Worker \(id) COMPLETED frame \(queuedFrame.frameID) in \(String(format: "%.2f", elapsed))s", category: .processing)

                    // Apply rate limiting delay after successful processing
                    if minDelayBetweenFramesNs > 0 {
                        let deadline = pacingStart.advanced(by: .nanoseconds(Int64(minDelayBetweenFramesNs)))
                        try await Task.sleep(until: deadline, clock: .continuous)
                    }

                } catch is CancellationError {
                    try await databaseManager.releaseFrameProcessingClaim(
                        frameID: queuedFrame.frameID, priority: queuedFrame.retryPriority, retryCount: queuedFrame.retryCount
                    )
                    if Task.isCancelled { break }
                    continue
                } catch {
                    totalFailed += 1
                    relieveMallocPressure()

                    // Check if this is an unrecoverable error (damaged/missing video file)
                    // These errors won't be fixed by retrying, so fail immediately
                    let isUnrecoverableError = isUnrecoverableVideoError(error)

                    if isUnrecoverableError {
                        try await markFrameAsFailed(queuedFrame.frameID, error: error, skipRetries: true)
                    } else if queuedFrame.retryCount < config.maxRetryAttempts {
                        // Retry if under limit for recoverable errors
                        try await retryFrame(queuedFrame, error: error)
                    } else {
                        // Mark as failed permanently
                        try await markFrameAsFailed(queuedFrame.frameID, error: error)
                    }
                }

            } catch is CancellationError {
                Log.debug("[Queue] Worker \(id) cancelled", category: .processing)
                break
            } catch {
                Log.error("[Queue-DIAG] Worker \(id) error: \(error)", category: .processing)
                try? await Task.sleep(for: .nanoseconds(Int64(1_000_000_000)), clock: .continuous) // 1s backoff
            }
        }

        Log.debug("[Queue] Worker \(id) stopped", category: .processing)
    }

    // MARK: - Frame Processing

    /// Process a single frame (OCR + FTS + Nodes)
    /// Returns ProcessFrameResult indicating success, skip, or deferral
    private func processFrame(_ queuedFrame: QueuedFrame) async throws -> ProcessFrameResult {
        let frameID = queuedFrame.frameID
        let t0 = CFAbsoluteTimeGetCurrent()

        // Get frame with video info (includes isVideoFinalized and bundleID in metadata)
        guard let frameWithInfo = try await databaseManager.getFrameWithVideoInfoByID(id: FrameID(value: frameID)) else {
            Log.error("[Queue-DIAG] Frame \(frameID) not found in database!", category: .processing)
            throw DatabaseError.queryFailed(query: "getFrame", underlying: "Frame \(frameID) not found")
        }
        let frameRef = try await databaseManager.originalFrameForProcessing(frameWithInfo.frame)

        // Check app filter - skip OCR for excluded apps (bundleID is in metadata from JOIN)
        let bundleID = frameRef.metadata.appBundleID
        if !shouldProcessOCR(forBundleID: bundleID) {
            // Durable policy skip is distinct from an empty OCR result. It may
            // release originals only after the same exact archive is verified.
            try await databaseManager.recordOriginalExtractionSkipped(
                frameID: FrameID(value: frameID), expectedAppBundleID: bundleID)
            Log.debug("[Queue] Frame \(frameID) skipped - app \(bundleID ?? "unknown") excluded from OCR", category: .processing)
            return .skippedByAppFilter
        }

        // Get video segment for dimensions (needed for node insertion)
        guard let videoSegment = try await databaseManager.getVideoSegment(id: frameRef.videoID) else {
            Log.error("[Queue-DIAG] Video segment \(frameRef.videoID.value) not found!", category: .processing)
            throw DatabaseError.queryFailed(query: "getVideoSegment", underlying: "Video segment \(frameRef.videoID) not found")
        }

        let tPrep = CFAbsoluteTimeGetCurrent()

        // Resolve segment ID encoded in the video file path (WAL and storage use this ID).
        let actualSegmentID = try parseActualSegmentID(from: videoSegment.relativePath)

        // The exact-ID WAL is authoritative while present. Finalized metadata
        // can race active capture, and the HEVC container can still be empty or
        // return an earlier frame until the encoder finishes writing it.
        let capturedFrame: CapturedFrame
        let isVideoFinalized = frameWithInfo.videoInfo?.isVideoFinalized ?? true
        let storageRoot = await storage.getStorageDirectory()
        // Recovery can move the archive into a new video while the original
        // remains in its source WAL. Locate original pixels by verified frame
        // identity, not the mutable archive path or an ordinal fallback.
        let walFrame: CapturedFrame?
        do {
            if let pathID = try await databaseManager.originalFrameLocation(frameID: frameRef.id) {
                walFrame = try await storage.readOriginalFrameForProcessing(
                    sourceStoreID: databaseManager.originalStoreID(), frame: frameRef,
                    originalVideoPathID: pathID,
                    expectedWidth: videoSegment.width, expectedHeight: videoSegment.height)
            } else {
                // Legacy archive rows have no immutable original alias; do not
                // scan today's original sessions looking for an unrelated ID.
                walFrame = nil
            }
        } catch let error as ExactFrameReadError {
            switch error {
            case .cancelled: throw CancellationError()
            case .frameFinalising: return .deferredSourceNotReady
            case .recordingMissing: throw FrameProcessingFailure.mediaUnavailable(.recordingMissing)
            case .integrityFailure: throw FrameProcessingFailure.mediaUnavailable(.integrityFailure)
            }
        }
        if let walFrame {
            capturedFrame = walFrame
        } else {
            var isLiveWAL = false
            if let storageManager = storage as? StorageManager {
                let walManager = await storageManager.getWALManager()
                isLiveWAL = await walManager.isLiveSession(videoID: actualSegmentID)
            }
            // Recovery retains damaged historical WALs. Once their video is
            // finalized, an unreadable non-live WAL must not force endless
            // deferral: try strict encoded pixels or the bounded failure path.
            guard isVideoFinalized && !isLiveWAL else { return .deferredSourceNotReady }

            // Verify finalized video file exists before attempting extraction
            let videoFullPath = storageRoot.appendingPathComponent(videoSegment.relativePath).path
            if !FileManager.default.fileExists(atPath: videoFullPath) {
                throw FrameProcessingFailure.mediaUnavailable(.recordingMissing)
            }

            do {
                capturedFrame = try await storage.readFrameForProcessing(frame: frameRef, video: videoSegment)
            } catch let error as ExactFrameReadError {
                switch error {
                case .cancelled: throw CancellationError()
                case .recordingMissing: throw FrameProcessingFailure.mediaUnavailable(.recordingMissing)
                case .frameFinalising: throw FrameProcessingFailure.mediaUnavailable(.frameFinalising)
                case .integrityFailure: throw FrameProcessingFailure.mediaUnavailable(.integrityFailure)
                }
            }
        }

        // The database already claimed the frame atomically when it was dequeued.
        try BackgroundProcessingContext.checkCancellation()

        let tFrame = CFAbsoluteTimeGetCurrent()

        // Run OCR
        let extractedText = try await processing.extractText(from: capturedFrame)
        try BackgroundProcessingContext.checkCancellation()

        let tOCR = CFAbsoluteTimeGetCurrent()

        // Search text, highlight regions and completion become visible together.
        _ = try await databaseManager.commitFrameOCR(
            frameID: FrameID(value: frameID), text: extractedText,
            frameWidth: videoSegment.width, frameHeight: videoSegment.height
        )

        let tDone = CFAbsoluteTimeGetCurrent()
        Log.recordLatency("ocr_frame_processing", valueMs: (tDone - t0) * 1000, category: .processing)
        // Separate the backlog from current capture latency; timestamps contain no screen text.
        let ageMs = max(0, Date().timeIntervalSince(frameRef.timestamp) * 1000)
        Log.recordLatency("capture_to_search_all_completed", valueMs: ageMs, category: .processing)
        Log.recordLatency(ageMs < 60_000 ? "capture_to_search_recent" : "capture_to_search_backlog",
                          valueMs: ageMs, category: .processing)
        Log.info("[Queue-TIMING] Frame \(frameID): prep=\(String(format: "%.0f", (tPrep-t0)*1000))ms frame=\(String(format: "%.0f", (tFrame-tPrep)*1000))ms ocr=\(String(format: "%.0f", (tOCR-tFrame)*1000))ms index=\(String(format: "%.0f", (tDone-tOCR)*1000))ms total=\(String(format: "%.0f", (tDone-t0)*1000))ms size=\(capturedFrame.width)x\(capturedFrame.height)", category: .processing)

        return .success
    }

    private func parseActualSegmentID(from relativePath: String) throws -> VideoSegmentID {
        let pathComponents = relativePath.split(separator: "/")
        guard let lastComponent = pathComponents.last,
              let actualSegmentID = Int64(lastComponent) else {
            throw ProcessingError.invalidVideoPath(path: relativePath)
        }
        return VideoSegmentID(value: actualSegmentID)
    }

    // MARK: - Status Management

    /// Update frame processing status
    private func updateFrameProcessingStatus(_ frameID: Int64, status: FrameProcessingStatus) async throws {
        try await databaseManager.updateFrameProcessingStatus(frameID: frameID, status: status.rawValue)
    }

    /// Retry a failed frame
    private func retryFrame(_ queuedFrame: QueuedFrame, error: Error) async throws {
        try await databaseManager.releaseFrameProcessingClaim(
            frameID: queuedFrame.frameID, priority: 0,
            retryCount: queuedFrame.retryCount + 1,
            errorMessage: error.localizedDescription
        )
        Log.warning("[Queue] Retrying frame \(queuedFrame.frameID), attempt \(queuedFrame.retryCount + 1)", category: .processing)
    }

    /// A failed repair changes availability, never ownership of retained evidence.
    private func markFrameAsFailed(_ frameID: Int64, error: Error, skipRetries: Bool = false) async throws {
        if skipRetries {
            let reason = mediaUnavailableReason(for: error)
            try await databaseManager.recordFrameMediaUnavailable(frameID: FrameID(value: frameID), reason: reason)
            Log.warning("[Queue] Frame \(frameID) media unavailable (\(reason.rawValue)); retained text and provenance preserved", category: .processing)
        } else {
            // Actual processing failure after retries - mark as failed
            try await updateFrameProcessingStatus(frameID, status: .failed)
            Log.error("[Queue] Frame \(frameID) marked as failed after max retries: \(error)", category: .processing)
        }
    }

    private func mediaUnavailableReason(for error: Error) -> EvidenceUnavailableReason {
        if let failure = error as? FrameProcessingFailure,
           case .mediaUnavailable(let reason) = failure { return reason }
        if let storageError = error as? StorageError,
           case .fileNotFound = storageError { return .recordingMissing }
        let description = error.localizedDescription.lowercased()
        if description.contains("video file is empty") || description.contains("file not found")
            || description.contains("no such file") {
            return .recordingMissing
        }
        return .integrityFailure
    }

    /// Re-enqueue frames that were processing during a crash
    /// Only re-enqueues frames whose video files are readable (finalized)
    public func requeueCrashedFrames() async throws {
        try Task.checkCancellation()
        let frameIDs = try await databaseManager.getCrashedProcessingFrameIDs()

        guard !frameIDs.isEmpty else {
            return
        }

        Log.warning("[Queue] Found \(frameIDs.count) frames that crashed during processing, verifying video files...", category: .processing)

        var validFrameIDs: [Int64] = []
        var invalidFrameIDs: [Int64] = []

        for frameID in frameIDs {
            try Task.checkCancellation()
            // Get the frame reference to find its video segment
            guard let frameRef = try await databaseManager.getFrame(id: FrameID(value: frameID)) else {
                Log.warning("[Queue] Crashed frame \(frameID) not found in database, marking as failed", category: .processing)
                invalidFrameIDs.append(frameID)
                continue
            }

            // Get the video segment to check if the file is readable
            guard let videoSegment = try await databaseManager.getVideoSegment(id: frameRef.videoID) else {
                Log.warning("[Queue] Video segment \(frameRef.videoID.value) not found for crashed frame \(frameID), marking as failed", category: .processing)
                invalidFrameIDs.append(frameID)
                continue
            }

            // Check if the video file exists and is readable
            // Extract the actual segment ID from the path (last path component is the timestamp-based ID)
            let pathComponents = videoSegment.relativePath.split(separator: "/")
            guard let lastComponent = pathComponents.last,
                  let actualSegmentID = Int64(lastComponent) else {
                Log.warning("[Queue] Invalid video path for crashed frame \(frameID): \(videoSegment.relativePath), marking as failed", category: .processing)
                invalidFrameIDs.append(frameID)
                continue
            }

            // Try to verify the video file exists and is accessible
            let videoExists = try await storage.segmentExists(id: VideoSegmentID(value: actualSegmentID))

            if !videoExists {
                Log.warning("[Queue] Video file missing for crashed frame \(frameID) (segment \(actualSegmentID)), marking as failed", category: .processing)
                invalidFrameIDs.append(frameID)
                continue
            }

            validFrameIDs.append(frameID)
        }

        // Mark invalid frames as failed (they can't be processed without valid video)
        for frameID in invalidFrameIDs {
            try Task.checkCancellation()
            try await updateFrameProcessingStatus(frameID, status: .failed)
        }

        if !invalidFrameIDs.isEmpty {
            Log.warning("[Queue] Marked \(invalidFrameIDs.count) crashed frames as failed (video files missing/unreadable)", category: .processing)
        }

        if !validFrameIDs.isEmpty {
            // Reset valid crashed frames back to pending status before re-enqueueing
            for frameID in validFrameIDs {
                try Task.checkCancellation()
                try await updateFrameProcessingStatus(frameID, status: .pending)
            }
            Log.info("[Queue] Reset \(validFrameIDs.count) crashed frames to pending status", category: .processing)

            Log.info("[Queue] Re-enqueueing \(validFrameIDs.count) crashed frames with valid video files", category: .processing)
            try Task.checkCancellation()
            try await enqueueBatch(frameIDs: validFrameIDs)
        }
    }

    /// Check if an error indicates an unrecoverable video file issue
    /// These errors (damaged/missing files) won't be fixed by retrying
    private func isUnrecoverableVideoError(_ error: Error) -> Bool {
        if error is FrameProcessingFailure { return true }
        let errorDescription = error.localizedDescription.lowercased()
        let nsError = error as NSError

        // AVFoundation error codes for damaged/unreadable media
        // -11829 = AVErrorFileFormatNotRecognized / Cannot Open
        // -12848 = NSOSStatusErrorDomain - file format issue
        if nsError.domain == "AVFoundationErrorDomain" && nsError.code == -11829 {
            return true
        }

        // NSCocoaErrorDomain Code=516 = file already exists (temp symlink conflict)
        // This happens when multiple workers try to extract from same video simultaneously
        // Retrying won't help - need to fix the temp file handling, but don't spam retries
        if nsError.domain == "NSCocoaErrorDomain" && nsError.code == 516 {
            return true
        }

        // Check error message for common indicators
        if errorDescription.contains("cannot open") ||
           errorDescription.contains("media may be damaged") ||
           errorDescription.contains("file not found") ||
           errorDescription.contains("no such file") ||
           errorDescription.contains("file with the same name already exists") {
            return true
        }

        // Check for StorageError.fileNotFound
        if let storageError = error as? StorageError {
            switch storageError {
            case .fileNotFound, .fileReadFailed:
                return true
            default:
                break
            }
        }

        return false
    }

    // MARK: - Statistics

    public func getStatistics() async -> QueueStatistics {
        // Query live counts from database for accuracy
        var pending = pendingCount
        var processing = processingCount
        if let counts = try? await databaseManager.getFrameStatusCounts() {
            pending = counts.pending
            processing = counts.processing
        }

        return QueueStatistics(
            queueDepth: pending + processing,
            pendingCount: pending,
            processingCount: processing,
            totalProcessed: totalProcessed,
            totalFailed: totalFailed,
            workerCount: workers.count
        )
    }

    // MARK: - Memory Reporting

    private func startMemoryReporting() {
        memoryReportTask?.cancel()
        let intervalNs = Int64(memoryReportIntervalNs)
        memoryReportTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .nanoseconds(intervalNs), clock: .continuous)
                guard !Task.isCancelled else { break }
                await self?.logMemorySnapshot()
            }
        }
    }

    private func logMemorySnapshot() {
        let queueDepth = pendingCount + processingCount
        let snapshot = currentMemorySnapshot()
        let rss = Self.formatBytes(Int64(snapshot?.residentBytes ?? 0))
        let ownedHeap = snapshot?.ownedHeapBytes.map { Self.formatBytes(Int64($0)) } ?? "unknown"

        Log.info(
            "[Queue-Memory] rss=\(rss) ownedHeap=\(ownedHeap) rawCacheFrames=0 rawCacheBytes=0 KB queueDepth=\(queueDepth) pending=\(pendingCount) processing=\(processingCount) workers=\(workers.count)",
            category: .processing
        )
    }

    private func shouldBackOffForResidentMemory() -> Bool {
        let beforeRelief = currentMemorySnapshot()
        guard FrameProcessingMemoryBackoffPolicy.shouldBackOff(
            snapshot: beforeRelief,
            residentLimitBytes: softResidentMemoryLimitBytes,
            ownedHeapLimitBytes: softOwnedHeapMemoryLimitBytes
        ) else {
            return false
        }

        let reclaimed = relieveMallocPressure()
        let afterRelief = currentMemorySnapshot() ?? beforeRelief
        guard FrameProcessingMemoryBackoffPolicy.shouldBackOff(
            snapshot: afterRelief,
            residentLimitBytes: softResidentMemoryLimitBytes,
            ownedHeapLimitBytes: softOwnedHeapMemoryLimitBytes
        ) else {
            return false
        }

        let residentText = Self.formatBytes(Int64(afterRelief?.residentBytes ?? 0))
        let ownedHeapText = afterRelief?.ownedHeapBytes.map { Self.formatBytes(Int64($0)) } ?? "unknown"
        Log.warning(
            "[Queue-Memory] Pausing OCR worker because resident=\(residentText), ownedHeap=\(ownedHeapText) (reclaimed \(Self.formatBytes(Int64(reclaimed))))",
            category: .processing
        )
        return true
    }

    private func currentMemorySnapshot() -> FrameProcessingMemorySnapshot? {
        guard let residentBytes = currentResidentMemoryBytes() else { return nil }
        return FrameProcessingMemorySnapshot(
            residentBytes: residentBytes,
            ownedHeapBytes: currentOwnedHeapMemoryBytes()
        )
    }

    private func currentResidentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }

    private func currentOwnedHeapMemoryBytes() -> UInt64? {
        guard let zone = malloc_default_zone() else { return nil }
        var stats = malloc_statistics_t()
        malloc_zone_statistics(zone, &stats)
        return UInt64(stats.size_in_use)
    }

    @discardableResult
    private func relieveMallocPressure() -> UInt64 {
        UInt64(malloc_zone_pressure_relief(nil, 0))
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(0, bytes))
    }
}

// MARK: - Models

public struct ProcessingQueueConfig: Sendable {
    public let workerCount: Int
    public let maxRetryAttempts: Int
    public let maxQueueSize: Int

    public init(workerCount: Int = 1, maxRetryAttempts: Int = 3, maxQueueSize: Int = 1000) {
        self.workerCount = workerCount
        self.maxRetryAttempts = maxRetryAttempts
        self.maxQueueSize = maxQueueSize
    }

    public static let `default` = ProcessingQueueConfig()
}

private struct QueuedFrame {
    let queueID: Int64
    let frameID: Int64
    let retryCount: Int
    var lane: FrameProcessingLane? = nil
    var retryPriority: Int { lane == .manual ? 75 : 10 }
}

private enum FrameProcessingFailure: Error, Sendable {
    case mediaUnavailable(EvidenceUnavailableReason)
}

public enum FrameProcessingStatus: Int, Sendable {
    case pending = 0
    case processing = 1
    case completed = 2
    case failed = 3
    // Note: 4 = "not yet readable" (used elsewhere, don't add new values here)
}

/// Internal result of processing a frame
private enum ProcessFrameResult {
    case success
    case skippedByAppFilter      // Frame skipped due to app filter, mark as completed (no OCR)
    case deferredSourceNotReady  // Source payload not readable yet (WAL write in progress), re-queue for later
}

public struct QueueStatistics: Sendable {
    public let queueDepth: Int
    public let pendingCount: Int      // Frames waiting in queue (status 0)
    public let processingCount: Int   // Frames currently being processed (status 1)
    public let totalProcessed: Int
    public let totalFailed: Int
    public let workerCount: Int
}
