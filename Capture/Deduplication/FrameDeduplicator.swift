import Foundation
import simd
import Shared

/// Sampled frame deduplication with a local high-contrast edit safeguard.
/// Conforms to DeduplicationProtocol from Shared/Protocols
public struct FrameDeduplicator: DeduplicationProtocol {

    // MARK: - Initialization

    public init() {}

    // MARK: - DeduplicationProtocol

    /// Check if a frame should be kept based on similarity to reference frame
    /// - Parameters:
    ///   - frame: The new frame to evaluate
    ///   - reference: The reference frame to compare against (nil means always keep)
    ///   - threshold: Similarity threshold (0-1, where 1.0 means identical)
    /// - Returns: True if frame should be kept, false if it's basically the same (duplicate)
    public func shouldKeepFrame(
        _ frame: CapturedFrame,
        comparedTo reference: CapturedFrame?,
        threshold: Double
    ) -> Bool {
        // Always keep if there's no reference
        guard let reference = reference else { return true }

        // Quick size check - if dimensions changed, definitely keep
        if frame.width != reference.width || frame.height != reference.height {
            return true
        }

        // Check if frames are basically identical
        let similarity = computeSimilarity(frame, reference)

        if similarity <= threshold { return true }

        // The coarse grid can entirely miss a changed digit. At normal/high
        // sensitivity, check nearby high-contrast pixel changes before discarding.
        // Deliberately lower sensitivity retains its existing slider semantics.
        guard threshold >= CaptureConfig.defaultDeduplicationThreshold else { return false }
        return hasLocalHighContrastChange(frame, reference)
    }

    /// Compute a perceptual hash for a frame
    /// - Parameter frame: The frame to hash
    /// - Returns: 64-bit hash value
    public func computeHash(for frame: CapturedFrame) -> UInt64 {
        guard hasValidPixelLayout(frame) else { return 0 }
        // Simple checksum of sampled pixels
        var hash: UInt64 = 0
        let sampleSize = 64

        frame.imageData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }
            let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)

            let totalPixels = frame.width * frame.height
            let step = max(1, totalPixels / sampleSize)

            for i in stride(from: 0, to: totalPixels, by: step).prefix(sampleSize) {
                let offset = (i / frame.width) * frame.bytesPerRow + (i % frame.width) * 4
                if offset + 2 < frame.imageData.count {
                    let r = UInt64(pixels[offset + 2])
                    let g = UInt64(pixels[offset + 1])
                    let b = UInt64(pixels[offset])
                    hash = hash &+ (r &+ g &+ b)
                }
            }
        }

        return hash
    }

    /// Compute similarity score between two frames
    /// - Parameters:
    ///   - frame1: First frame
    ///   - frame2: Second frame
    /// - Returns: Similarity score from 0.0 (completely different) to 1.0 (identical)
    public func computeSimilarity(
        _ frame1: CapturedFrame,
        _ frame2: CapturedFrame
    ) -> Double {
        // Quick size check
        if frame1.width != frame2.width || frame1.height != frame2.height {
            return 0.0 // Completely different
        }
        guard hasValidPixelLayout(frame1), hasValidPixelLayout(frame2) else { return 0 }

        // Sample pixels across the image in a uniform 2D grid
        let sampleSize = 10000 // Target number of samples
        var matchingPixels = 0
        var totalSamples = 0

        // Calculate grid dimensions for uniform 2D distribution
        let aspectRatio = Double(frame1.width) / Double(frame1.height)
        let gridRows = max(1, Int(sqrt(Double(sampleSize) / aspectRatio)))
        let gridCols = max(1, Int(Double(gridRows) * aspectRatio))

        let stepX = max(1, frame1.width / gridCols)
        let stepY = max(1, frame1.height / gridRows)

        frame1.imageData.withUnsafeBytes { bytes1 in
            frame2.imageData.withUnsafeBytes { bytes2 in
                guard let base1 = bytes1.baseAddress,
                      let base2 = bytes2.baseAddress else { return }

                let pixels1 = base1.assumingMemoryBound(to: UInt8.self)
                let pixels2 = base2.assumingMemoryBound(to: UInt8.self)

                for row in stride(from: 0, to: frame1.height, by: stepY) {
                    for col in stride(from: 0, to: frame1.width, by: stepX) {
                        let offset1 = row * frame1.bytesPerRow + col * 4
                        let offset2 = row * frame2.bytesPerRow + col * 4

                        if offset1 + 2 < frame1.imageData.count && offset2 + 2 < frame2.imageData.count {
                            let r1 = pixels1[offset1 + 2]
                            let g1 = pixels1[offset1 + 1]
                            let b1 = pixels1[offset1]

                            let r2 = pixels2[offset2 + 2]
                            let g2 = pixels2[offset2 + 1]
                            let b2 = pixels2[offset2]

                            // Check if pixels are very similar (within 5% tolerance)
                            let rDiff = abs(Int(r1) - Int(r2))
                            let gDiff = abs(Int(g1) - Int(g2))
                            let bDiff = abs(Int(b1) - Int(b2))

                            if rDiff < 13 && gDiff < 13 && bDiff < 13 { // 13 ≈ 5% of 255
                                matchingPixels += 1
                            }
                            totalSamples += 1
                        }
                    }
                }
            }
        }

        guard totalSamples > 0 else { return 0.0 }
        return Double(matchingPixels) / Double(totalSamples)
    }

    /// Ignore padding and reject malformed buffers before any pointer access.
    private func hasValidPixelLayout(_ frame: CapturedFrame) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        let (visibleRowBytes, widthOverflow) = frame.width.multipliedReportingOverflow(by: 4)
        guard !widthOverflow, frame.bytesPerRow >= visibleRowBytes else { return false }
        let (lastRowOffset, rowOverflow) = (frame.height - 1).multipliedReportingOverflow(by: frame.bytesPerRow)
        let (requiredBytes, countOverflow) = lastRowOffset.addingReportingOverflow(visibleRowBytes)
        return !rowOverflow && !countOverflow && requiredBytes <= frame.imageData.count
    }

    /// A 32px tile needs six adjacent changed pixel pairs across three rows.
    /// This catches small glyph edits missed by the grid while ignoring low
    /// contrast changes and isolated pixel noise. No OCR/model runs here.
    /// Scratch space is bounded by the number of horizontal tiles, not image area.
    private func hasLocalHighContrastChange(_ first: CapturedFrame, _ second: CapturedFrame) -> Bool {
        guard hasValidPixelLayout(first), hasValidPixelLayout(second) else { return true }
        if first.bytesPerRow == second.bytesPerRow && first.imageData == second.imageData { return false }
        let tileWidth = 32
        let tileCount = (first.width + tileWidth - 1) / tileWidth
        var pairCounts = [UInt16](repeating: 0, count: tileCount)
        var changedRows = [UInt8](repeating: 0, count: tileCount)
        // Captured pixels are little-endian BGRA. A vector processes four
        // pixels, ignoring alpha exactly as the sampled path does. Each bit
        // below represents one qualifying pixel in the current 32px tile row.
        let rgbMask = SIMD4<UInt32>(repeating: 0x00ff_ffff)
        let contrastFloor = SIMD16<UInt8>(repeating: 47)

        return first.imageData.withUnsafeBytes { firstBytes in
            second.imageData.withUnsafeBytes { secondBytes in
                guard let firstBase = firstBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let secondBase = secondBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return true }
                for row in 0..<first.height {
                    if row % tileWidth == 0 {
                        for tile in 0..<tileCount {
                            pairCounts[tile] = 0
                            changedRows[tile] = 0
                        }
                    }
                    let firstRow = firstBase + row * first.bytesPerRow
                    let secondRow = secondBase + row * second.bytesPerRow
                    for tile in 0..<tileCount {
                        let startColumn = tile * tileWidth
                        let endColumn = min(startColumn + tileWidth, first.width)
                        let vectorCount = (endColumn - startColumn) / 4
                        var vectorBits = SIMD4<UInt32>(repeating: 0)
                        var weights = SIMD4<UInt32>(1, 2, 4, 8)
                        for block in 0..<vectorCount {
                            let offset = startColumn * 4 + block * 16
                            let firstPixels = UnsafeRawPointer(firstRow).loadUnaligned(
                                fromByteOffset: offset, as: SIMD16<UInt8>.self)
                            let secondPixels = UnsafeRawPointer(secondRow).loadUnaligned(
                                fromByteOffset: offset, as: SIMD16<UInt8>.self)
                            let difference = simd_max(firstPixels, secondPixels) &- simd_min(firstPixels, secondPixels)
                            // Positive exactly when a channel differs by >=48.
                            // Platform intrinsics keep this operation vectorized.
                            let qualifying = simd_max(difference, contrastFloor) &- contrastFloor
                            let rgb = unsafeBitCast(qualifying, to: SIMD4<UInt32>.self) & rgbMask
                            vectorBits |= SIMD4<UInt32>(repeating: 0).replacing(with: weights, where: rgb .!= 0)
                            weights &<<= 4
                        }
                        // The lanes contain disjoint bits, so addition combines
                        // them without carrying. Read only visible tail pixels.
                        var changedBits = simd_reduce_add(vectorBits)
                        for column in (startColumn + vectorCount * 4)..<endColumn {
                            let offset = column * 4
                            let changed = abs(Int(firstRow[offset]) - Int(secondRow[offset])) >= 48
                                || abs(Int(firstRow[offset + 1]) - Int(secondRow[offset + 1])) >= 48
                                || abs(Int(firstRow[offset + 2]) - Int(secondRow[offset + 2])) >= 48
                            if changed { changedBits |= 1 << (column - startColumn) }
                        }
                        // Bit zero cannot pair with the preceding tile. Pairs
                        // spanning two vectors within this tile remain adjacent.
                        let rowPairs = UInt16((changedBits & (changedBits << 1)).nonzeroBitCount)
                        if rowPairs > 0 {
                            pairCounts[tile] += rowPairs
                            changedRows[tile] += 1
                            if pairCounts[tile] >= 6 && changedRows[tile] >= 3 { return true }
                        }
                    }
                }
                return false
            }
        }
    }
}
