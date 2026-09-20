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

    /// Fast-mode scale and native crop work budgets. Accurate OCR never downsizes pixels.
    private static let maxOCRScaleFactor: CGFloat = 1.0
    private static let minOCRScaleFactor: CGFloat = 0.30
    private static let targetMegapixelsAccurate: CGFloat = 1.75
    private static let targetMegapixelsFast: CGFloat = 2.25
    private static let maxNativeObservations = 512

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
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let image = createCGImage(from: imageData, width: width, height: height, bytesPerRow: bytesPerRow) else {
                throw ProcessingError.imageConversionFailed
            }
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            var discovered = try recognize(image, in: bounds, config: config)
            guard config.ocrAccuracyLevel == .accurate,
                  CGFloat(width) * CGFloat(height) > Self.targetMegapixelsAccurate * 1_000_000 else {
                return discovered
            }

            discovered = try discoverInNativeCrops(image, data: imageData, bytesPerRow: bytesPerRow,
                                                   initial: discovered, config: config)

            try Task.checkCancellation()
            return Self.readingOrder(discovered)
        }
    }

    /// Full-display text detection can miss small text even at native resolution.
    /// Overlapping crops expose it at a useful detector scale. Complete initial
    /// lines extend a crop across its grid boundary; seam reads cover previously
    /// undetected lines. Solid-colour crops need no Vision request.
    private func discoverInNativeCrops(_ image: CGImage, data: Data, bytesPerRow: Int,
                                      initial: [TextRegion], config: ProcessingConfig) throws -> [TextRegion] {
        let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard initial.count <= Self.maxNativeObservations else { return initial }
        var local: [TextRegion] = []
        var observed: [TextRegion] = []
        var seams: [CGRect] = []
        var requests = 0
        var inspected = 0
        var processedPixels: CGFloat = 0
        captureCrops: for y in stride(from: 0, to: image.height, by: 720) {
            for x in stride(from: 0, to: image.width, by: 1280) {
                try Task.checkCancellation()
                guard inspected < 128, requests < 12 else { break captureCrops }
                inspected += 1
                let core = CGRect(x: x, y: y, width: 1280, height: 720).intersection(frame)
                var crop = core.insetBy(dx: -64, dy: -64).intersection(frame)
                if initial.count <= 128 {
                    for region in initial where crop.intersects(region.bounds) {
                        let expanded = crop.union(region.bounds.insetBy(dx: -16, dy: -16).integral.intersection(frame))
                        if expanded.width * expanded.height <= 2_250_000 { crop = expanded }
                    }
                }
                guard processedPixels + crop.width * crop.height <= 12_000_000,
                      !Self.isUniform(data, bytesPerRow: bytesPerRow, bounds: crop),
                      let pixels = image.cropping(to: crop) else { continue }
                requests += 1
                processedPixels += crop.width * crop.height
                let regions = try recognize(pixels, in: crop, config: config)
                guard observed.count + regions.count <= Self.maxNativeObservations else { return initial }
                observed += regions
                for region in regions {
                    if (crop.minX > 0 && region.bounds.minX < crop.minX + 32)
                        || (crop.maxX < frame.maxX && region.bounds.maxX > crop.maxX - 32) {
                        let strip = CGRect(x: 0, y: region.bounds.minY - 16,
                                           width: frame.width, height: region.bounds.height + 32).integral.intersection(frame)
                        if let index = seams.firstIndex(where: { $0.intersects(strip) }) {
                            seams[index] = seams[index].union(strip)
                        } else if seams.count < 4 { seams.append(strip) }
                    }
                    if core.contains(CGPoint(x: region.bounds.midX, y: region.bounds.midY)) { local.append(region) }
                }
            }
        }
        for strip in seams where strip.width * strip.height <= 1_750_000 {
            try Task.checkCancellation()
            // Tighten the horizontal crop to all observed fragments on this
            // line. A full-width mostly blank strip can defeat text detection.
            let fragments = observed.filter { strip.intersects($0.bounds) }
            guard !fragments.isEmpty else { continue }
            let crop = fragments.reduce(CGRect.null) { $0.union($1.bounds) }
                .insetBy(dx: -32, dy: -16).integral.intersection(frame)
            guard crop.width * crop.height <= 1_750_000,
                  let pixels = image.cropping(to: crop) else { continue }
            let existing = local.filter { crop.intersects($0.bounds) }
            let refined = try recognize(pixels, in: crop, config: config)
            guard refined.count <= Self.maxNativeObservations else { continue }
            let replacement = Self.completeRefinement(refined, replacing: existing)
            guard local.count - existing.count + replacement.count <= Self.maxNativeObservations else { continue }
            local.removeAll { crop.intersects($0.bounds) }
            local += replacement
        }
        // A local detector may omit a line that the full display recognized.
        // Preserve it unless the local observations provide a complete replacement.
        let retained = try initial.filter { original in
            try Task.checkCancellation()
            let candidates = local.filter { $0.bounds.intersects(original.bounds) }
            return !Self.refinementIsComplete(candidates, replacing: [original])
        }
        local = try local.filter { candidate in
            try Task.checkCancellation()
            return !retained.contains { $0.bounds.intersects(candidate.bounds) }
        }
        return local.count + retained.count <= Self.maxNativeObservations ? local + retained : initial
    }

    private static func isUniform(_ data: Data, bytesPerRow: Int, bounds: CGRect) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            let first = base.advanced(by: Int(bounds.minY) * bytesPerRow + Int(bounds.minX) * 4)
            let rowBytes = Int(bounds.width) * 4
            for offset in stride(from: 4, to: rowBytes, by: 4) {
                if memcmp(first, first.advanced(by: offset), 4) != 0 { return false }
            }
            for row in 1..<Int(bounds.height) {
                if memcmp(first, first.advanced(by: row * bytesPerRow), rowBytes) != 0 { return false }
            }
            return true
        }
    }

    static func completeRefinement(_ refined: [TextRegion], replacing original: [TextRegion]) -> [TextRegion] {
        // A nonempty response is not proof that Vision read every line. Keep
        // discovery intact unless the new observations cover every original line.
        refinementIsComplete(refined, replacing: original) ? refined : original
    }

    private static func refinementIsComplete(_ refined: [TextRegion], replacing original: [TextRegion]) -> Bool {
        !refined.isEmpty && original.allSatisfy { region in
            let matches = refined.filter { candidate in
                let overlap = candidate.bounds.intersection(region.bounds)
                return !overlap.isNull && overlap.height >= min(candidate.bounds.height, region.bounds.height) * 0.5
            }
            let extent = matches.reduce(CGRect.null) { $0.union($1.bounds) }
            let covered = extent.insetBy(dx: -3, dy: -3).intersection(region.bounds)
            // Full-display detection can include substantial vertical padding.
            // A sharper line need not reproduce that padding to cover its text.
            let matchedHeight = matches.map { $0.bounds.height }.max() ?? 0
            let originalText = region.text.filter { !$0.isWhitespace }
            let refinedText = matches.sorted { $0.bounds.minX < $1.bounds.minX }
                .map(\.text).joined().filter { !$0.isWhitespace }
            let estimatedGlyphWidth = region.bounds.width / CGFloat(max(1, originalText.count))
            // Whole-display boxes can pad either end by roughly one glyph.
            // If text becomes shorter, require tighter coverage: that allowance
            // must not hide a lost final digit alongside an earlier OCR change.
            let edgeTolerance: CGFloat = refinedText.count < originalText.count ? 2
                : max(2, min(12, max(region.bounds.height * 0.1, estimatedGlyphWidth)))
            // A short missing suffix can fit within detector padding. Never
            // replace a complete line with just its literal prefix or suffix.
            if refinedText.count < originalText.count,
               originalText.hasPrefix(refinedText) || originalText.hasSuffix(refinedText) { return false }
            return !covered.isNull && covered.width >= region.bounds.width * 0.8
                && extent.minX <= region.bounds.minX + edgeTolerance
                && extent.maxX >= region.bounds.maxX - edgeTolerance
                && covered.height >= min(region.bounds.height, matchedHeight) * 0.5
                && matches.reduce(0, { $0 + $1.text.count }) >= Int(Double(region.text.count) * 0.8)
        }
    }

    private static func readingOrder(_ regions: [TextRegion]) -> [TextRegion] {
        let topDown = regions.sorted { $0.bounds.minY == $1.bounds.minY
            ? $0.bounds.minX < $1.bounds.minX : $0.bounds.minY < $1.bounds.minY }
        var rows: [[TextRegion]] = []
        for region in topDown {
            if let anchor = rows.last?.first {
                let overlap = anchor.bounds.intersection(region.bounds)
                let shorter = min(anchor.bounds.height, region.bounds.height)
                if !overlap.isNull && overlap.height >= shorter * 0.5 {
                    rows[rows.count - 1].append(region)
                    continue
                }
                // Horizontally separated words have no rectangle intersection,
                // but their vertical spans can still be on exactly the same line.
                let vertical = min(anchor.bounds.maxY, region.bounds.maxY) - max(anchor.bounds.minY, region.bounds.minY)
                if vertical >= shorter * 0.5 && abs(anchor.bounds.midY - region.bounds.midY) <= max(3, shorter * 0.5) {
                    rows[rows.count - 1].append(region)
                    continue
                }
            }
            rows.append([region])
        }
        return rows.flatMap { $0.sorted { $0.bounds.minX < $1.bounds.minX } }
    }

    /// Read one image, mapping Vision's normalized coordinates into original pixels.
    private func recognize(_ image: CGImage, in bounds: CGRect, config: ProcessingConfig) throws -> [TextRegion] {
        try Task.checkCancellation()
        let scale = Self.calculateOCRScaleFactor(width: image.width, height: image.height, config: config)
        let input = scale < 1 ? (downscaleImage(image, scale: scale) ?? image) : image
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = Self.recognitionLevel(for: config)
        request.recognitionLanguages = recognitionLanguages
        request.usesLanguageCorrection = false
        request.preferBackgroundProcessing = config.preferBackgroundProcessing
        do { try VNImageRequestHandler(cgImage: input, options: [:]).perform([request]) }
        catch { throw ProcessingError.ocrFailed(underlying: error.localizedDescription) }
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { observation in
            guard observation.confidence >= config.minimumConfidence,
                  let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let box = observation.boundingBox
            return TextRegion(frameID: FrameID(value: 0), text: candidate.string,
                bounds: CGRect(x: bounds.minX + box.minX * bounds.width,
                               y: bounds.minY + (1 - box.maxY) * bounds.height,
                               width: box.width * bounds.width, height: box.height * bounds.height),
                confidence: Double(observation.confidence))
        }
    }

    // MARK: - Live Screenshot OCR

    /// Perform OCR directly on a CGImage (for live screenshot use case)
    /// Separate one-shot .accurate request; saved-frame discovery/caching is not used here.
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
        mergedRegions = Self.readingOrder(mergedRegions)
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
    /// Accurate full-frame discovery retains the native image when crop work exceeds this budget.
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

            return try recognize(cropImage, in: cropBounds, config: config)
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

    /// The fast setting bounds pixel cost; accurate recognition preserves native detail.
    private static func calculateOCRScaleFactor(
        width: Int,
        height: Int,
        config: ProcessingConfig
    ) -> CGFloat {
        guard width > 0, height > 0 else { return maxOCRScaleFactor }
        // Accurate recognition must see the original letter strokes. Resizing a
        // 4K display to 1.75 MP removes small glyph details before Vision runs.
        guard config.ocrAccuracyLevel == .fast else { return maxOCRScaleFactor }

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
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (size, sizeOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !rowOverflow, !sizeOverflow,
              bytesPerRow >= rowBytes, size <= 256 * 1024 * 1024, data.count >= size else { return nil }
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
