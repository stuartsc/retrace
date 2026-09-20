import Accelerate
import CoreGraphics
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
            for quality: Float in [0.7, 0.9] {
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
            "scope": "Four sparse authored 4K scenes; three OCR repetitions. Eight identical frames per codec sample. Not foreground latency, representative compression ratios or installed acceptance.",
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
