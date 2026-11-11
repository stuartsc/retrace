import Accelerate
import CoreGraphics
import Compression
import CryptoKit
import CoreText
import Foundation
import Darwin
import Shared
import Storage
import Vision
import XCTest
@testable import Processing

/// Opt-in, authored/offscreen comparisons. No personal screenshots or live store.
final class ScreenTextQualityBenchmarkTests: XCTestCase {
    func testAuthoredChangedTilesReplayCriticalChangesAndRejectWrongBaseOrTruncation() throws {
        let first = try render(lines: ["Invoice ZX842619 total 47000.00", "Approval NOT GRANTED"],
            font: "Menlo", size: 14, dark: false, coloured: false)
        let changed = try render(lines: ["Invoice ZX842619 total 48000.00", "Approval GRANTED"],
            font: "Menlo", size: 14, dark: false, coloured: false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tile-replay-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var previous: Data?
        for (index, frame) in [first, first, changed, first].enumerated() {
            let patch = try AuthoredChangedTilePatch.make(previous: previous, current: frame.imageData,
                width: frame.width, height: frame.height)
            let encoded = try JSONEncoder().encode(patch)
            let file = root.appendingPathComponent("\(index).json")
            try encoded.write(to: file, options: .withoutOverwriting)
            let reloaded = try JSONDecoder().decode(AuthoredChangedTilePatch.self, from: Data(contentsOf: file))
            let decoded = try reloaded.replay(previous: previous)
            XCTAssertEqual(decoded, frame.imageData, "Every pixel must survive digit/status changes and reversion")
            if index == 1 { XCTAssertTrue(reloaded.tiles.isEmpty, "Unchanged pixels need no tile payload") }
            if index == 2 {
                XCTAssertThrowsError(try reloaded.replay(previous: changed.imageData), "Wrong base cannot yield a plausible wrong frame")
                try Data(encoded.dropLast()).write(to: file)
                XCTAssertThrowsError(try JSONDecoder().decode(AuthoredChangedTilePatch.self, from: Data(contentsOf: file)))
            }
            previous = decoded
        }
    }

    func testAuthoredScreenTextAndCompressionComparison() async throws {
        guard let path = ProcessInfo.processInfo.environment["RETRACE_OCR_QUALITY_EXPORT"] else {
            throw XCTSkip("Set RETRACE_OCR_QUALITY_EXPORT to run the authored quality/codec comparison")
        }
        let output = URL(fileURLWithPath: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "Do not overwrite a comparison")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-quality-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = ProcessingConfig(accessibilityEnabled: false, minimumConfidence: 0.5)
        let native = VisionOCR()
        let legacy = LegacyScaledOCRBaseline()
        var samples: [[String: Any]] = []
        var legacyErrors = 0
        var nativeErrors = 0
        // Document, dark editor, proportional text and coloured identifiers.
        for (name, font, size, dark, coloured) in [
            ("small-monospace", "Menlo", 12.0, false, false),
            ("dark-editor", "Menlo", 14.0, true, false),
            ("proportional-document", "Helvetica", 16.0, false, false),
            ("coloured-code", "Menlo", 14.0, true, true)
        ] {
            let lines = [
                "Reference ZX842619 amount 9876.54",
                "Invoice ABC12345 total 4200.00 payable Friday",
                "Cedar proposal amount 47000.00",
                "https://example.test/invoices/ZX842619",
                "const invoice_id = 842619; total = 9876.54;",
                "Approved on 2026-09-20 for account 17002468"
            ]
            let source = try render(lines: lines, font: font, size: size, dark: dark, coloured: coloured)
            let expected = lines.joined(separator: " ")
            var row: [String: Any] = ["fixture": name, "expected": expected, "width": source.width, "height": source.height]
            for (label, recognizer) in [("previous-scaled", legacy as any OCRProtocol), ("native-refined", native as any OCRProtocol)] {
                var times: [Double] = []
                var cpuTimes: [Double] = []
                var recognized = ""
                for _ in 0..<3 {
                    let cpuStart = cpuMilliseconds()
                    let start = ContinuousClock.now
                    let regions = try await recognizer.recognizeText(imageData: source.imageData, width: source.width,
                        height: source.height, bytesPerRow: source.bytesPerRow, config: config)
                    times.append(milliseconds(start.duration(to: .now)))
                    cpuTimes.append(cpuMilliseconds() - cpuStart)
                    recognized = regions.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                }
                let errors = editDistance(expected, recognized)
                row[label] = ["text": recognized, "characterEdits": errors, "milliseconds": times, "processCPUMilliseconds": cpuTimes]
                if label == "previous-scaled" { legacyErrors += errors } else { nativeErrors += errors }
            }
            if #available(macOS 26, *) {
                var request = RecognizeDocumentsRequest()
                request.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: "en-US")]
                request.textRecognitionOptions.useLanguageCorrection = false
                let image = try XCTUnwrap(native.createCGImage(from: source.imageData, width: source.width,
                    height: source.height, bytesPerRow: source.bytesPerRow))
                let start = ContinuousClock.now
                let documents = try await request.perform(on: image)
                let elapsed = milliseconds(start.duration(to: .now))
                let text = documents.map { $0.document.text.transcript }.joined(separator: " ")
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                row["native-documents"] = ["text": text, "characterEdits": editDistance(expected, text), "milliseconds": elapsed]
            }
            let compressionStart = ContinuousClock.now
            let lossless = try (source.imageData as NSData).compressed(using: .lzfse) as Data
            let compressionTime = compressionStart.duration(to: .now)
            let decompressionStart = ContinuousClock.now
            let restored = try (lossless as NSData).decompressed(using: .lzfse) as Data
            let decompressionTime = decompressionStart.duration(to: .now)
            XCTAssertEqual(restored, source.imageData, "LZFSE must preserve every source byte")
            row["lzfse"] = ["rawBytes": source.imageData.count, "compressedBytes": lossless.count,
                "compressMs": milliseconds(compressionTime), "decompressMs": milliseconds(decompressionTime)]
            let changedLines = lines.map { $0.replacingOccurrences(of: "47000.00", with: "48000.00")
                .replacingOccurrences(of: "Approved on", with: "NOT approved on") }
            let changed = try render(lines: changedLines, font: font, size: size, dark: dark, coloured: coloured)
            var tilePrevious: Data?, tileBytes = 0, tileChangedCounts: [Int] = []
            var tileEncodeMs: [Double] = [], tileDecodeMs: [Double] = []
            let tileCPUStart = cpuMilliseconds()
            for (index, image) in [source, source, changed, source].enumerated() {
                let tileStart = ContinuousClock.now
                let patch = try AuthoredChangedTilePatch.make(previous: tilePrevious, current: image.imageData,
                    width: image.width, height: image.height)
                let bytes = try JSONEncoder().encode(patch)
                let file = root.appendingPathComponent("\(name)-tile-\(index).json")
                try bytes.write(to: file, options: .withoutOverwriting)
                tileEncodeMs.append(milliseconds(tileStart.duration(to: .now)))
                tileBytes += bytes.count; tileChangedCounts.append(patch.tiles.count)
                let readStart = ContinuousClock.now
                let reopened = try JSONDecoder().decode(AuthoredChangedTilePatch.self, from: Data(contentsOf: file))
                tilePrevious = try reopened.replay(previous: tilePrevious)
                tileDecodeMs.append(milliseconds(readStart.duration(to: .now)))
                XCTAssertEqual(tilePrevious, image.imageData)
            }
            row["lossless-changed-tiles-prototype"] = ["bytesForFourObservationsIncludingJSON": tileBytes,
                "changedTiles": tileChangedCounts, "encodeAndWriteMs": tileEncodeMs,
                "readAndDecodeMs": tileDecodeMs, "processCPUMilliseconds": cpuMilliseconds() - tileCPUStart,
                "pattern": "base, unchanged, critical digit/status change, revert", "pixelExact": true]
            for quality: Float in [0.5, 0.7, 0.9] {
                let directory = root.appendingPathComponent("\(name)-\(quality)")
                let storage = StorageManager(storageRoot: directory, encoderConfig: VideoEncoderConfig(quality: quality))
                try await storage.initialize(config: StorageConfig(storageRootPath: directory.path))
                let writer = try await storage.createRecoverySegmentWriter()
                let encodeStart = ContinuousClock.now
                // Eight equal observations exercise interframe coding as well as the keyframe.
                for _ in 0..<8 { try await writer.appendFrame(source) }
                let video = try await writer.finalize()
                let encodeTime = encodeStart.duration(to: .now)
                let reference = FrameReference(id: FrameID(value: 1), timestamp: source.timestamp,
                    segmentID: AppSegmentID(value: 1), videoID: video.id, frameIndexInSegment: 7, metadata: source.metadata)
                let decodeStart = ContinuousClock.now
                let decoded = try await storage.readFrameForProcessing(frame: reference, video: video)
                let decodeTime = decodeStart.duration(to: .now)
                let text = try await native.recognizeText(imageData: decoded.imageData, width: decoded.width,
                    height: decoded.height, bytesPerRow: decoded.bytesPerRow, config: config)
                let recognized = text.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                row["hevc-\(quality)"] = ["bytesForEightIdenticalFrames": video.fileSizeBytes,
                    "encodeMs": milliseconds(encodeTime), "decodeMs": milliseconds(decodeTime),
                    "characterEdits": editDistance(expected, recognized), "text": recognized]
            }
            samples.append(row)
        }
        let report: [String: Any] = ["schema": 1, "authoredOnly": true,
            "baselineSource": "d1b367f", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "legacyCharacterEdits": legacyErrors, "nativeCharacterEdits": nativeErrors,
            "scope": "Four sparse authored 4K scenes; three OCR repetitions. Eight identical HEVC frames versus four changed-tile observations are separate workloads, not a codec winner comparison. Includes default 0.5 and candidate 0.7/0.9 HEVC; tile prototype requires a prior image and has no production index/recovery implementation. Not foreground latency, energy, representative compression ratios or installed acceptance.",
            "samples": samples]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .withoutOverwriting)
        XCTAssertLessThan(nativeErrors, legacyErrors, "Native pixels should improve the authored comparison; inspect per-scene regressions too")
    }

    private func cpuMilliseconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private func render(lines: [String], font: String, size: Double, dark: Bool, coloured: Bool) throws -> CapturedFrame {
        let width = 3840, height = 2160
        var pixels = Data(count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.setFillColor(CGColor(gray: dark ? 0.075 : 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for (index, text) in lines.enumerated() {
                let color = coloured ? CGColor(red: 0.3, green: 0.85, blue: 1, alpha: 1) : CGColor(gray: dark ? 0.95 : 0, alpha: 1)
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
                context.textPosition = CGPoint(x: 800, y: 2160 - 300 - index * 250)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
            }
        }
        return CapturedFrame(timestamp: Date(timeIntervalSince1970: 1_700_000_000), imageData: pixels,
            width: width, height: height, bytesPerRow: width * 4)
    }

    private func editDistance(_ expected: String, _ actual: String) -> Int {
        let lhs = Array(expected), rhs = Array(actual)
        var previous = Array(0...rhs.count)
        for (row, a) in lhs.enumerated() {
            var current = [row + 1] + Array(repeating: 0, count: rhs.count)
            for (column, b) in rhs.enumerated() {
                current[column + 1] = min(previous[column + 1] + 1, current[column] + 1,
                                           previous[column] + (a == b ? 0 : 1))
            }
            previous = current
        }
        return previous.last ?? lhs.count
    }
}

// Frozen pre-change full-frame algorithm; copied from d1b367f for paired measurement only.
private final class LegacyScaledOCRBaseline: OCRProtocol, @unchecked Sendable {

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

// Test/developer comparison only; never used as an archive reader or writer.
// Each small tile is decoded into an exactly bounded buffer, then the complete
// frame hash and prior-frame hash reject corruption, omissions and wrong bases.
private struct AuthoredChangedTilePatch: Codable {
    struct Tile: Codable { let index: Int; let bytes: Data }
    let version: Int
    let width: Int
    let height: Int
    let previousSHA256: String?
    let currentSHA256: String
    let tiles: [Tile]
    private static let side = 128
    private enum Invalid: Error { case dimensions, base, tile, checksum }

    static func make(previous: Data?, current: Data, width: Int, height: Int) throws -> Self {
        let size = try byteCount(width, height)
        guard current.count == size, previous == nil || previous?.count == size else { throw Invalid.dimensions }
        let columns = (width + side - 1) / side, rows = (height + side - 1) / side
        var tiles: [Tile] = []
        for index in 0..<(columns * rows) {
            let new = tileBytes(current, index: index, width: width, height: height)
            if let previous, tileBytes(previous, index: index, width: width, height: height) == new { continue }
            tiles.append(Tile(index: index, bytes: try (new as NSData).compressed(using: .lzfse) as Data))
        }
        return Self(version: 1, width: width, height: height, previousSHA256: previous.map(hash),
            currentSHA256: hash(current), tiles: tiles)
    }

    func replay(previous: Data?) throws -> Data {
        let size = try Self.byteCount(width, height)
        guard version == 1, previousSHA256 == previous.map(Self.hash),
              previous == nil || previous?.count == size else { throw Invalid.base }
        let columns = (width + Self.side - 1) / Self.side, rows = (height + Self.side - 1) / Self.side
        let count = columns * rows
        guard tiles.count <= count, Set(tiles.map(\.index)).count == tiles.count,
              tiles.allSatisfy({ (0..<count).contains($0.index) }),
              previous != nil || tiles.count == count else { throw Invalid.tile }
        var result = previous ?? Data(count: size)
        for tile in tiles {
            let x = tile.index % columns * Self.side, y = tile.index / columns * Self.side
            let tileWidth = min(Self.side, width - x), tileHeight = min(Self.side, height - y)
            let rawSize = tileWidth * tileHeight * 4
            guard !tile.bytes.isEmpty, tile.bytes.count <= rawSize + 1_024 else { throw Invalid.tile }
            var restored = Data(count: rawSize)
            let written = restored.withUnsafeMutableBytes { output in
                tile.bytes.withUnsafeBytes { input in
                    compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, rawSize,
                        input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_LZFSE)
                }
            }
            guard written == rawSize else { throw Invalid.tile }
            for row in 0..<tileHeight {
                let destination = ((y + row) * width + x) * 4
                let source = row * tileWidth * 4
                result.replaceSubrange(destination..<(destination + tileWidth * 4),
                    with: restored[source..<(source + tileWidth * 4)])
            }
        }
        guard Self.hash(result) == currentSHA256 else { throw Invalid.checksum }
        return result
    }

    private static func byteCount(_ width: Int, _ height: Int) throws -> Int {
        guard (1...8_192).contains(width), (1...8_192).contains(height), width * height <= 67_108_864 else {
            throw Invalid.dimensions
        }
        return width * height * 4
    }
    private static func tileBytes(_ data: Data, index: Int, width: Int, height: Int) -> Data {
        let columns = (width + side - 1) / side, x = index % columns * side, y = index / columns * side
        let tileWidth = min(side, width - x), tileHeight = min(side, height - y)
        var result = Data(); result.reserveCapacity(tileWidth * tileHeight * 4)
        for row in 0..<tileHeight {
            let offset = ((y + row) * width + x) * 4
            result.append(data[offset..<(offset + tileWidth * 4)])
        }
        return result
    }
    private static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}
