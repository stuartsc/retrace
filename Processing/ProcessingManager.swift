import Foundation
import Shared

// MARK: - ProcessingManager

/// Coordinates retained-frame OCR and explicit live Accessibility operations.
/// Saved-frame extraction is delegated to a pixel-only actor with no AX dependency.
public actor ProcessingManager: ProcessingProtocol {

    // MARK: - Dependencies

    private let retainedText: RetainedFrameTextExtractor
    private let accessibility: any AccessibilityProtocol

    // MARK: - State

    private var config: ProcessingConfig

    // Processing queue
    private var processingQueue: [(CapturedFrame, (Result<ExtractedText, ProcessingError>) -> Void)] = []
    private var isProcessing = false

    // Statistics
    private var framesProcessed = 0
    private var totalOCRTimeMs: Double = 0
    private var totalTextLength = 0
    private var errorCount = 0

    // MARK: - Initialization

    public init(
        config: ProcessingConfig = .default,
        accessibility: any AccessibilityProtocol = AccessibilityService()
    ) {
        self.config = config
        self.retainedText = RetainedFrameTextExtractor(recognitionLanguages: config.recognitionLanguages)
        self.accessibility = accessibility
    }

    // MARK: - ProcessingProtocol

    public func initialize(config: ProcessingConfig) async throws {
        self.config = config
    }


    public func extractText(from frame: CapturedFrame) async throws -> ExtractedText {
        let startTime = Date()
        let text = try await retainedText.extractText(from: frame, config: config)
        framesProcessed += 1
        totalOCRTimeMs += Date().timeIntervalSince(startTime) * 1000
        totalTextLength += text.wordCount
        return text
    }

    public func extractTextViaOCR(from frame: CapturedFrame) async throws -> [TextRegion] {
        try await retainedText.extractTextViaOCR(from: frame, config: config)
    }

    public func extractTextViaAccessibility() async throws -> [TextRegion] {
        guard config.accessibilityEnabled else {
            return []
        }

        guard await accessibility.hasPermission() else {
            throw ProcessingError.accessibilityPermissionDenied
        }

        let result = try await accessibility.getFocusedAppText()

        // Convert accessibility text elements to TextRegions
        // Note: We use a dummy FrameID since AX text is not tied to a specific frame
        let dummyFrameID = FrameID(value: 0)
        return result.textElements.map { element in
            TextRegion(
                frameID: dummyFrameID,
                text: element.text,
                bounds: .zero,  // AX doesn't provide spatial info
                confidence: 1.0  // AX text is always accurate
            )
        }
    }

    // MARK: - Processing Queue

    public func queueFrame(
        _ frame: CapturedFrame,
        completion: @escaping @Sendable (Result<ExtractedText, ProcessingError>) -> Void
    ) async {
        processingQueue.append((frame, completion))

        // Start processing if not already running
        if !isProcessing {
            await processQueue()
        }
    }

    public var queuedFrameCount: Int {
        return processingQueue.count
    }

    public func waitForQueueDrain() async {
        while !processingQueue.isEmpty || isProcessing {
            try? await Task.sleep(for: .nanoseconds(Int64(100_000_000)), clock: .continuous)  // 100ms
        }
    }

    // MARK: - Configuration

    public func updateConfig(_ config: ProcessingConfig) async {
        self.config = config
    }

    public func getConfig() async -> ProcessingConfig {
        return config
    }

    // MARK: - Statistics

    public func getStatistics() async -> ProcessingStatistics {
        return ProcessingStatistics(
            framesProcessed: framesProcessed,
            averageOCRTimeMs: framesProcessed > 0 ? totalOCRTimeMs / Double(framesProcessed) : 0,
            averageTextLength: framesProcessed > 0 ? totalTextLength / framesProcessed : 0,
            errorCount: errorCount
        )
    }

    /// Get region-based OCR statistics. Work-area savings are estimates, not energy measurements.
    public func getRegionOCRStats() async -> (averageEnergySavings: Double, frameCount: Int, cacheStats: (hits: Int, misses: Int, size: Int, hitRate: Double)?) {
        await retainedText.getRegionOCRStats()
    }

    // MARK: - Region-Based OCR Configuration

    public func setRegionBasedOCR(enabled: Bool) async {
        await retainedText.setRegionBasedOCR(enabled: enabled)
    }

    public func isRegionBasedOCREnabled() async -> Bool {
        await retainedText.isRegionBasedOCREnabled()
    }

    public func invalidateTileCache() async {
        await retainedText.invalidateTileCache()
    }

    // MARK: - Private Methods

    private func processQueue() async {
        isProcessing = true

        while !processingQueue.isEmpty {
            let (frame, completion) = processingQueue.removeFirst()

            do {
                let text = try await extractText(from: frame)
                completion(.success(text))
            } catch let error as ProcessingError {
                errorCount += 1
                Log.error("[ProcessingManager] Queue processing failed for frame: \(error)", category: .processing)
                completion(.failure(error))
            } catch {
                errorCount += 1
                Log.error("[ProcessingManager] Queue processing failed for frame: \(error.localizedDescription)", category: .processing, error: error)
                completion(.failure(.ocrFailed(underlying: error.localizedDescription)))
            }
        }

        isProcessing = false
    }
}

// MARK: - Accessibility Helpers

extension ProcessingManager {

    /// Check if Accessibility permission is granted
    public func hasAccessibilityPermission() async -> Bool {
        return await accessibility.hasPermission()
    }

    /// Request Accessibility permission (opens System Settings)
    public func requestAccessibilityPermission() async {
        await accessibility.requestPermission()
    }

    /// Get information about the frontmost application
    public func getFrontmostAppInfo() async throws -> AppInfo {
        return try await accessibility.getFrontmostAppInfo()
    }
}

// MARK: - Retained Pixel Extraction

/// This actor deliberately has no Accessibility or frontmost-app dependency.
/// Its complete evidence input is the retained frame and saved capture metadata;
/// enabling live AX elsewhere cannot change historical extraction or provenance.
private actor RetainedFrameTextExtractor {
    private let ocr: VisionOCR
    private var fullFrameCache: FullFrameOCRCache?
    private var previousFrame: CapturedFrame?
    private var useRegionBasedOCR = true
    private var totalWorkAreaSavings: Double = 0
    private var regionOCRFrameCount = 0
    private var extractionTail: Task<ExtractedText, Error>?
    private var extractionSequence: UInt64 = 0

    init(recognitionLanguages: [String]) {
        ocr = VisionOCR(recognitionLanguages: recognitionLanguages)
    }

    func extractText(from frame: CapturedFrame, config: ProcessingConfig) async throws -> ExtractedText {
        // Actor reentrancy alone does not protect the frame/cache pair across
        // Vision awaits. Order complete extractions without blocking a thread;
        // this also avoids saturating the cooperative executor with Vision's
        // synchronous internal waits when multiple workers arrive together.
        let predecessor = extractionTail
        extractionSequence &+= 1
        let sequence = extractionSequence
        let task = Task {
            if let predecessor { _ = await predecessor.result }
            try Task.checkCancellation()
            return try await self.extractRetainedFrame(from: frame, config: config)
        }
        extractionTail = task
        defer {
            if extractionSequence == sequence { extractionTail = nil }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func extractRetainedFrame(from frame: CapturedFrame, config: ProcessingConfig) async throws -> ExtractedText {
        if fullFrameCache == nil { fullFrameCache = FullFrameOCRCache() }
        let regions: [TextRegion]
        if useRegionBasedOCR, let cache = fullFrameCache {
            let result = try await ocr.recognizeTextRegionBased(
                frame: frame, previousFrame: previousFrame, cache: cache, config: config
            )
            regions = result.regions
            regionOCRFrameCount += 1
            totalWorkAreaSavings += result.stats.energySavings
            if result.stats.energySavings > 0.1 {
                Log.debug("[ProcessingManager] Region OCR: \(result.stats.tilesOCRed)/\(result.stats.totalTiles) tiles, \(Int(result.stats.energySavings * 100))% estimated crop work avoided, \(String(format: "%.1f", result.stats.totalTimeMs))ms", category: .processing)
            }
        } else {
            regions = try await extractTextViaOCR(from: frame, config: config)
        }
        previousFrame = frame

        let topChromeThreshold = CGFloat(frame.height) * 0.05
        let bottomChromeThreshold = CGFloat(frame.height) * 0.95
        var mainRegions: [TextRegion] = []
        var chromeRegions: [TextRegion] = []
        for region in regions {
            if region.bounds.maxY <= topChromeThreshold || region.bounds.minY >= bottomChromeThreshold {
                chromeRegions.append(region)
            } else {
                mainRegions.append(region)
            }
        }

        // Flatten the same ordered regions used for offsets/highlights. Never
        // inject text from a different surface, timestamp or extraction method.
        return ExtractedText(
            frameID: FrameID(value: 0), timestamp: frame.timestamp,
            regions: mainRegions, chromeRegions: chromeRegions, metadata: frame.metadata
        )
    }

    func extractTextViaOCR(from frame: CapturedFrame, config: ProcessingConfig) async throws -> [TextRegion] {
        try await ocr.recognizeText(
            imageData: frame.imageData, width: frame.width, height: frame.height,
            bytesPerRow: frame.bytesPerRow, config: config
        )
    }

    func getRegionOCRStats() async -> (averageEnergySavings: Double, frameCount: Int, cacheStats: (hits: Int, misses: Int, size: Int, hitRate: Double)?) {
        let average = regionOCRFrameCount > 0 ? totalWorkAreaSavings / Double(regionOCRFrameCount) : 0
        if let cache = fullFrameCache {
            let stats = await cache.getStats()
            return (average, regionOCRFrameCount, (stats.hits, stats.misses, stats.regionCount, stats.hitRate))
        }
        return (average, regionOCRFrameCount, nil)
    }

    func setRegionBasedOCR(enabled: Bool) async {
        useRegionBasedOCR = enabled
        if !enabled { await invalidateTileCache() }
    }

    func isRegionBasedOCREnabled() -> Bool { useRegionBasedOCR }

    func invalidateTileCache() async {
        await fullFrameCache?.invalidateAll()
        previousFrame = nil
    }
}
