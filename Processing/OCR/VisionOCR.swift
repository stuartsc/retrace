import Foundation
import Vision
import CoreGraphics
import Accelerate
import Shared

// MARK: - VisionOCR

/// Vision framework implementation of OCRProtocol
public final class VisionOCR: OCRProtocol, @unchecked Sendable {

    /// Recognition languages for OCR
    private let recognitionLanguages: [String]

    /// OCR scale settings for adaptive downscaling.
    /// Frames above the target megapixel budget are downscaled to cap OCR cost.
    private static let maxOCRScaleFactor: CGFloat = 1.0
    private static let minOCRScaleFactor: CGFloat = 0.30
    private static let targetMegapixelsAccurate: CGFloat = 1.75
    private static let targetMegapixelsFast: CGFloat = 2.25

    public init(recognitionLanguages: [String] = ["en-US"]) {
        self.recognitionLanguages = recognitionLanguages
    }

    public func recognizeText(
        imageData: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        config: ProcessingConfig
    ) async throws -> [TextRegion] {
        try autoreleasepool {
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = Self.recognitionLevel(for: config)
            textRequest.recognitionLanguages = recognitionLanguages
            textRequest.usesLanguageCorrection = false
            textRequest.preferBackgroundProcessing = config.preferBackgroundProcessing

            guard let cgImage = createCGImage(from: imageData, width: width, height: height, bytesPerRow: bytesPerRow) else {
                throw ProcessingError.imageConversionFailed
            }

            let ocrImage: CGImage
            let ocrScaleFactor = Self.calculateOCRScaleFactor(
                width: width,
                height: height,
                config: config
            )
            if ocrScaleFactor < Self.maxOCRScaleFactor {
                ocrImage = downscaleImage(cgImage, scale: ocrScaleFactor) ?? cgImage
            } else {
                ocrImage = cgImage
            }

            let handler = VNImageRequestHandler(cgImage: ocrImage, options: [:])
            do {
                try handler.perform([textRequest])
            } catch {
                throw ProcessingError.ocrFailed(underlying: error.localizedDescription)
            }

            guard let observations = textRequest.results else {
                return []
            }

            return observations.compactMap { observation -> TextRegion? in
                guard observation.confidence >= config.minimumConfidence else { return nil }
                guard let topCandidate = observation.topCandidates(1).first else { return nil }
                let text = topCandidate.string
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

                // Vision uses bottom-left origin; Retrace stores top-left pixel coordinates.
                let box = observation.boundingBox
                let flippedY = 1.0 - box.origin.y - box.height
                let pixelBox = CGRect(
                    x: box.origin.x * CGFloat(width),
                    y: flippedY * CGFloat(height),
                    width: box.width * CGFloat(width),
                    height: box.height * CGFloat(height)
                )

                return TextRegion(
                    frameID: FrameID(value: 0), // Placeholder - updated by caller.
                    text: text,
                    bounds: pixelBox,
                    confidence: Double(observation.confidence)
                )
            }
        }
    }

    // MARK: - Live Screenshot OCR

    /// Perform OCR directly on a CGImage (for live screenshot use case)
    /// Uses the same .accurate pipeline as frame processing
    /// Returns TextRegions with **normalized coordinates** (0.0-1.0) for direct use with OCRNodeWithText
    public func recognizeTextFromCGImage(_ cgImage: CGImage) async throws -> [TextRegion] {
        try autoreleasepool {
            // No downscaling for live screenshot - it's a one-shot operation
            // and downscaling can introduce subtle bounding box drift from integer rounding.
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.recognitionLanguages = recognitionLanguages
            textRequest.usesLanguageCorrection = true
            textRequest.preferBackgroundProcessing = true

            do {
                try handler.perform([textRequest])
            } catch {
                throw ProcessingError.ocrFailed(underlying: error.localizedDescription)
            }

            guard let observations = textRequest.results else {
                return []
            }

            return observations.compactMap { observation -> TextRegion? in
                guard observation.confidence >= 0.5 else { return nil }
                guard let topCandidate = observation.topCandidates(1).first else { return nil }
                let text = topCandidate.string
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

                let box = observation.boundingBox
                let flippedY = 1.0 - box.origin.y - box.height
                let normalizedBox = CGRect(
                    x: box.origin.x,
                    y: flippedY,
                    width: box.width,
                    height: box.height
                )

                return TextRegion(
                    frameID: FrameID(value: 0),
                    text: text,
                    bounds: normalizedBox,
                    confidence: Double(observation.confidence)
                )
            }
        }
    }

    // MARK: - Image Processing

    /// Downscale a CGImage using vImage (hardware-accelerated, high quality)
    /// Returns nil if downscaling fails, caller should fall back to original image
    private func downscaleImage(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let newWidth = Int(CGFloat(image.width) * scale)
        let newHeight = Int(CGFloat(image.height) * scale)

        guard newWidth > 0, newHeight > 0 else { return nil }

        // Create source vImage buffer from CGImage
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: nil,  // Uses image's color space
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )

        var sourceBuffer = vImage_Buffer()
        var error = vImageBuffer_InitWithCGImage(&sourceBuffer, &format, nil, image, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { return nil }
        defer { free(sourceBuffer.data) }

        // Create destination buffer
        var destBuffer = vImage_Buffer()
        error = vImageBuffer_Init(&destBuffer, vImagePixelCount(newHeight), vImagePixelCount(newWidth), 32, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { return nil }
        defer { free(destBuffer.data) }

        // Scale using high-quality Lanczos resampling
        error = vImageScale_ARGB8888(&sourceBuffer, &destBuffer, nil, vImage_Flags(kvImageHighQualityResampling))
        guard error == kvImageNoError else { return nil }

        // Create CGImage from scaled buffer
        return vImageCreateCGImageFromBuffer(&destBuffer, &format, nil, nil, vImage_Flags(kvImageNoFlags), &error)?.takeRetainedValue()
    }

    // MARK: - Region-Based OCR

    /// Region-based OCR - uses tiles for CHANGE DETECTION only, not for OCR bounding boxes
    /// Preserves paragraph-level bounding boxes from full-frame OCR
    /// Only re-OCRs regions that touch changed tiles
    ///
    /// - Parameters:
    ///   - frame: Current frame to process
    ///   - previousFrame: Previous frame for change detection (nil = full OCR)
    ///   - cache: Full-frame OCR cache for storing/retrieving results
    ///   - config: Processing configuration
    /// - Returns: RegionOCRResult with merged regions and statistics
    public func recognizeTextRegionBased(
        frame: CapturedFrame,
        previousFrame: CapturedFrame?,
        cache: FullFrameOCRCache,
        config: ProcessingConfig
    ) async throws -> RegionOCRResult {
        let totalStartTime = Date()

        // Check if cache is valid for this frame (resolution/app change invalidates)
        let cacheInvalidated = await cache.validateForFrame(
            width: frame.width,
            height: frame.height,
            appBundleID: frame.metadata.appBundleID
        )

        let tileConfig = TileGridConfig.default
        let changeDetector = TileChangeDetector(config: tileConfig)

        // Check if we have cached regions (must await before condition)
        let hasCached = await cache.hasCachedRegions()

        // If cache was invalidated or no previous frame, do full-frame OCR
        if cacheInvalidated || previousFrame == nil || !hasCached {
            let ocrStartTime = Date()

            // Do standard full-frame OCR (preserves paragraph-level bounding boxes)
            let regions = try await recognizeText(
                imageData: frame.imageData,
                width: frame.width,
                height: frame.height,
                bytesPerRow: frame.bytesPerRow,
                config: config
            )
            let ocrTime = Date().timeIntervalSince(ocrStartTime) * 1000

            // Create tile grid and store in cache for future change detection
            let allTiles = changeDetector.createTileGrid(frameWidth: frame.width, frameHeight: frame.height)
            await cache.setFullFrameResults(regions: regions, tileGrid: allTiles)

            return RegionOCRResult(
                regions: regions,
                stats: RegionOCRStats(
                    tilesOCRed: allTiles.count,
                    tilesCached: 0,
                    totalTiles: allTiles.count,
                    changeDetectionTimeMs: 0,
                    ocrTimeMs: ocrTime,
                    mergeTimeMs: 0
                )
            )
        }

        // Detect changed tiles using original frame dimensions
        guard let changeResult = changeDetector.detectChanges(
            current: frame,
            previous: previousFrame!
        ) else {
            // Dimensions changed (shouldn't happen after validation, but handle gracefully)
            let regions = try await recognizeText(
                imageData: frame.imageData,
                width: frame.width,
                height: frame.height,
                bytesPerRow: frame.bytesPerRow,
                config: config
            )
            let allTiles = changeDetector.createTileGrid(frameWidth: frame.width, frameHeight: frame.height)
            await cache.setFullFrameResults(regions: regions, tileGrid: allTiles)
            return RegionOCRResult(
                regions: regions,
                stats: RegionOCRStats.fullFrame(
                    totalTiles: allTiles.count,
                    ocrTimeMs: Date().timeIntervalSince(totalStartTime) * 1000
                )
            )
        }

        // If nothing changed, return all cached results
        if changeResult.changedTiles.isEmpty {
            let cachedRegions = await cache.getCachedRegions()

            return RegionOCRResult(
                regions: cachedRegions,
                stats: RegionOCRStats(
                    tilesOCRed: 0,
                    tilesCached: changeResult.totalTiles,
                    totalTiles: changeResult.totalTiles,
                    changeDetectionTimeMs: changeResult.detectionTimeMs,
                    ocrTimeMs: 0,
                    mergeTimeMs: 0
                )
            )
        }

        // A changed tile can intersect only part of a line. Expand each crop to
        // complete cached text bounds, including any text touched by that expansion.
        let cachedRegions = await cache.getCachedRegions()
        let reOCRBounds = Self.incrementalCropBounds(
            changedTiles: changeResult.changedTiles,
            cachedRegions: cachedRegions,
            width: frame.width,
            height: frame.height,
            config: config
        )
        let (_, unaffectedRegions) = await cache.findAffectedRegions(intersecting: reOCRBounds)

        let ocrStartTime = Date()
        var newRegions: [TextRegion] = []
        for bounds in reOCRBounds {
            try Task.checkCancellation()
            newRegions += try await recognizeTextInRegion(
                imageData: frame.imageData,
                width: frame.width,
                height: frame.height,
                bytesPerRow: frame.bytesPerRow,
                region: bounds,
                config: config
            )
        }
        let ocrTime = Date().timeIntervalSince(ocrStartTime) * 1000

        // Every cached region intersecting a final crop was invalidated, so fresh
        // text cannot be suppressed by a stale overlapping cached observation.
        let mergeStartTime = Date()
        var mergedRegions = unaffectedRegions + newRegions

        // Sort by reading order: top-to-bottom, then left-to-right
        mergedRegions.sort { a, b in
            if abs(a.bounds.origin.y - b.bounds.origin.y) < 20 {
                return a.bounds.origin.x < b.bounds.origin.x
            }
            return a.bounds.origin.y < b.bounds.origin.y
        }
        let mergeTime = Date().timeIntervalSince(mergeStartTime) * 1000

        // Update cache with merged results
        let allTiles = changeDetector.createTileGrid(frameWidth: frame.width, frameHeight: frame.height)
        await cache.setFullFrameResults(regions: mergedRegions, tileGrid: allTiles)
        let rereadTileCount = allTiles.filter { tile in
            reOCRBounds.contains { $0.intersects(tile.pixelBounds) }
        }.count

        return RegionOCRResult(
            regions: mergedRegions,
            stats: RegionOCRStats(
                tilesOCRed: rereadTileCount,
                tilesCached: allTiles.count - rereadTileCount,
                totalTiles: changeResult.totalTiles,
                changeDetectionTimeMs: changeResult.detectionTimeMs,
                ocrTimeMs: ocrTime,
                mergeTimeMs: mergeTime
            )
        )
    }

    /// Plan disjoint native-resolution crops with bounded request and pixel costs.
    /// The full-frame discovery pass keeps its existing adaptive pixel budget.
    static func incrementalCropBounds(
        changedTiles: [TileInfo],
        cachedRegions: [TextRegion],
        width: Int,
        height: Int,
        config: ProcessingConfig
    ) -> [CGRect] {
        guard width > 0, height > 0, !changedTiles.isEmpty else { return [] }
        let frameBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let pixelBudget = (config.ocrAccuracyLevel == .fast ? targetMegapixelsFast : targetMegapixelsAccurate) * 1_000_000
        let changedArea = changedTiles.reduce(CGFloat.zero) { $0 + $1.pixelBounds.width * $1.pixelBounds.height }
        guard changedArea <= pixelBudget else { return [frameBounds] }

        // First group adjacent changed tiles. This avoids bridging distant edits
        // while keeping the grouping linear in the number of changed tiles.
        var remaining: [String: TileInfo] = [:]
        for tile in changedTiles { remaining[tile.cacheKey] = tile }
        var crops: [CGRect] = []
        let padding: CGFloat = 8
        while let seed = remaining.values.first {
            remaining.removeValue(forKey: seed.cacheKey)
            var queue = [seed]
            var next = 0
            var bounds = seed.pixelBounds
            while next < queue.count {
                let tile = queue[next]
                next += 1
                for row in (tile.row - 1)...(tile.row + 1) {
                    for col in (tile.col - 1)...(tile.col + 1) {
                        if let neighbor = remaining.removeValue(forKey: "\(col)_\(row)") {
                            queue.append(neighbor)
                            bounds = bounds.union(neighbor.pixelBounds)
                        }
                    }
                }
            }
            crops.append(bounds.insetBy(dx: -padding, dy: -padding).integral.intersection(frameBounds))
            // Too many requests can cost more than one ordinary discovery pass.
            if crops.count > 4 { return [frameBounds] }
        }

        // Reach a fixed point: expansion can touch another cached line or crop.
        // Include that complete line as well, and coalesce overlapping requests.
        var expanded = true
        while expanded {
            expanded = false
            for index in crops.indices {
                for region in cachedRegions where crops[index].intersects(region.bounds) {
                    let completeBounds = region.bounds.insetBy(dx: -padding, dy: -padding).integral.intersection(frameBounds)
                    let bounds = crops[index].union(completeBounds)
                    if bounds != crops[index] {
                        crops[index] = bounds
                        expanded = true
                    }
                }
            }
            var index = 0
            while index < crops.count {
                var other = index + 1
                while other < crops.count {
                    if crops[index].intersects(crops[other]) {
                        crops[index] = crops[index].union(crops.remove(at: other))
                        expanded = true
                    } else {
                        other += 1
                    }
                }
                index += 1
            }
            let cropArea = crops.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
            if cropArea > pixelBudget { return [frameBounds] }
        }
        return crops.sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
    }

    /// Crop the original pixels before resizing; return bounds in full-frame coordinates.
    /// Returns TextRegions with bounds in full frame coordinates
    private func recognizeTextInRegion(
        imageData: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        region: CGRect,
        config: ProcessingConfig
    ) async throws -> [TextRegion] {
        // If region covers the full frame, use standard OCR
        if region.minX <= 0 && region.minY <= 0 &&
           region.maxX >= CGFloat(width) && region.maxY >= CGFloat(height) {
            return try await recognizeText(
                imageData: imageData,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                config: config
            )
        }

        return try autoreleasepool {
            guard let cgImage = createCGImage(from: imageData, width: width, height: height, bytesPerRow: bytesPerRow) else {
                throw ProcessingError.imageConversionFailed
            }

            let frameBounds = CGRect(x: 0, y: 0, width: width, height: height)
            let cropBounds = region.integral.intersection(frameBounds)
            guard !cropBounds.isEmpty, !cropBounds.isNull else { return [] }
            guard let cropImage = cgImage.cropping(to: cropBounds) else {
                throw ProcessingError.imageConversionFailed
            }

            let ocrScaleFactor = Self.calculateOCRScaleFactor(
                width: cropImage.width,
                height: cropImage.height,
                config: config
            )
            let ocrImage = ocrScaleFactor < Self.maxOCRScaleFactor
                ? (downscaleImage(cropImage, scale: ocrScaleFactor) ?? cropImage)
                : cropImage

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = Self.recognitionLevel(for: config)
            request.recognitionLanguages = recognitionLanguages
            // Match the full-frame path: preserve identifiers and source spelling.
            request.usesLanguageCorrection = false
            request.preferBackgroundProcessing = config.preferBackgroundProcessing

            let handler = VNImageRequestHandler(cgImage: ocrImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                throw ProcessingError.ocrFailed(underlying: error.localizedDescription)
            }

            guard let observations = request.results else {
                return []
            }

            return observations.compactMap { observation -> TextRegion? in
                guard observation.confidence >= config.minimumConfidence else { return nil }
                guard let topCandidate = observation.topCandidates(1).first else { return nil }
                let text = topCandidate.string
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

                // Vision sees only the cropped image, so its normalized bounds
                // map once into the integral crop's original top-left pixel bounds.
                let box = observation.boundingBox
                let pixelBounds = CGRect(
                    x: cropBounds.minX + box.minX * cropBounds.width,
                    y: cropBounds.minY + (1.0 - box.maxY) * cropBounds.height,
                    width: box.width * cropBounds.width,
                    height: box.height * cropBounds.height
                )

                return TextRegion(
                    frameID: FrameID(value: 0),
                    text: text,
                    bounds: pixelBounds,
                    confidence: Double(observation.confidence)
                )
            }
        }
    }

    /// Map app OCR config to Vision recognition mode.
    private static func recognitionLevel(for config: ProcessingConfig) -> VNRequestTextRecognitionLevel {
        switch config.ocrAccuracyLevel {
        case .fast:
            return .fast
        case .accurate:
            return .accurate
        }
    }

    /// Compute an adaptive OCR scale based on frame size.
    /// This caps OCR pixel workload on large/ultrawide displays to reduce CPU spikes.
    private static func calculateOCRScaleFactor(
        width: Int,
        height: Int,
        config: ProcessingConfig
    ) -> CGFloat {
        guard width > 0, height > 0 else { return maxOCRScaleFactor }

        let frameMegapixels = (CGFloat(width) * CGFloat(height)) / 1_000_000.0
        let targetMegapixels: CGFloat = (config.ocrAccuracyLevel == .fast) ? targetMegapixelsFast : targetMegapixelsAccurate

        guard frameMegapixels > targetMegapixels else {
            return maxOCRScaleFactor
        }

        // Keep OCR near the target megapixel budget: scale^2 * frameMP ~= targetMP.
        let scale = sqrt(targetMegapixels / frameMegapixels)
        return min(maxOCRScaleFactor, max(minOCRScaleFactor, scale))
    }

    /// Create a CapturedFrame-like structure from a CGImage for change detection
    private func createScaledFrame(from cgImage: CGImage, originalFrame: CapturedFrame) -> CapturedFrame {
        // Extract pixel data from CGImage
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        let dataSize = bytesPerRow * height

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
        )

        var pixelData = Data(count: dataSize)
        pixelData.withUnsafeMutableBytes { ptr in
            guard let context = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else { return }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        return CapturedFrame(
            timestamp: originalFrame.timestamp,
            imageData: pixelData,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            metadata: originalFrame.metadata
        )
    }

    // MARK: - Image Conversion

    /// Convert raw pixel data to CGImage for Vision framework
    /// Assumes BGRA format (typical from ScreenCaptureKit)
    func createCGImage(from data: Data, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // BGRA format: premultiplied alpha, little endian
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
        )

        guard let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,  // Use actual bytesPerRow (may include padding for alignment)
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
