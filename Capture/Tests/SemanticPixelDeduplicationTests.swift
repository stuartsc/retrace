import CoreGraphics
import CoreText
import Darwin
import ImageIO
import XCTest
import Shared
@testable import Capture

/// Exercise actual capture admission before OCR with independently reviewed JPEGs
/// and native text rendering. These fixtures contain only fictional test content.
final class SemanticPixelDeduplicationTests: XCTestCase {
    private let deduplicator: any DeduplicationProtocol = FrameDeduplicator()

    func testReviewedAmountAndDecisionChangeIsRetainedBeforeOCR() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/fixtures/progressive-recall", isDirectory: true)
        let original = try decode(directory.appendingPathComponent("1700000000.jpeg"))
        let changed = try decode(directory.appendingPathComponent("1700000002.jpeg"))
        assertAdmission(original: original, changed: changed, label: "reviewed JPEG amount and decision")
        let independentDuplicate = try decode(directory.appendingPathComponent("1700000000.jpeg"))
        XCTAssertFalse(deduplicator.shouldKeepFrame(independentDuplicate, comparedTo: original,
            threshold: CaptureConfig.defaultDeduplicationThreshold))
    }

    func testOneDigitChangeIsRetainedAtOneAndTwoPixelScales() throws {
        for scale in [1, 2] {
            let original = try renderInvoice(amount: "$42,000", scale: scale)
            let changed = try renderInvoice(amount: "$47,000", scale: scale)
            assertAdmission(original: original, changed: changed, label: "single digit scale \(scale)")
        }
    }

    func testLowContrastChangesAndIsolatedPixelNoiseRemainDeduplicated() throws {
        let original = try renderCanvas(width: 1280, height: 800, gray: 0.5)
        let lowContrast = try renderCanvas(width: 1280, height: 800, gray: 0.52)
        let noise = try renderCanvas(width: 1280, height: 800, gray: 0.5, isolatedNoise: true)
        for candidate in [lowContrast, noise] {
            XCTAssertFalse(deduplicator.shouldKeepFrame(candidate, comparedTo: original,
                threshold: CaptureConfig.defaultDeduplicationThreshold))
        }
    }

    func testPaddedRowsDoNotChangeAdmissionOrHash() throws {
        let original = try renderInvoice(amount: "$42,000", scale: 1)
        let changed = try renderInvoice(amount: "$47,000", scale: 1)
        let firstPadding = repack(original, paddingByte: 0)
        let differentPadding = repack(original, paddingByte: 255)
        XCTAssertEqual(deduplicator.computeSimilarity(firstPadding, differentPadding), 1)
        XCTAssertEqual(deduplicator.computeHash(for: original), deduplicator.computeHash(for: firstPadding))
        XCTAssertEqual(deduplicator.computeHash(for: firstPadding), deduplicator.computeHash(for: differentPadding))
        XCTAssertFalse(deduplicator.shouldKeepFrame(differentPadding, comparedTo: firstPadding,
            threshold: CaptureConfig.defaultDeduplicationThreshold))
        XCTAssertTrue(deduplicator.shouldKeepFrame(repack(changed, paddingByte: 0), comparedTo: firstPadding,
            threshold: CaptureConfig.defaultDeduplicationThreshold))
    }

    func testContrastBoundaryInEachColorChannelAndAlphaOnlyChanges() throws {
        let original = try renderColoredPatch(color: CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for channel in 0..<3 {
            for level in [47, 48, 255] {
                var channels = [CGFloat](repeating: 0, count: 3)
                channels[channel] = CGFloat(level) / 255
                let color = try XCTUnwrap(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(),
                    components: channels + [1]))
                let changed = try renderColoredPatch(color: color)
                XCTAssertEqual(changed.imageData[(changed.height - 68) * changed.bytesPerRow + 67 * 4 + 2 - channel], UInt8(level),
                    "Verify the real raster contrast before testing admission")
                XCTAssertGreaterThan(deduplicator.computeSimilarity(original, changed),
                    CaptureConfig.defaultDeduplicationThreshold, "The local safeguard must decide this fixture")
                for (candidate, reference) in [(changed, original), (original, changed)] {
                    XCTAssertEqual(deduplicator.shouldKeepFrame(candidate, comparedTo: reference,
                        threshold: CaptureConfig.defaultDeduplicationThreshold), level >= 48,
                        "Channel \(channel), contrast \(level)")
                }
            }
        }
        let alphaOnly = try renderColoredPatch(color: CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        XCTAssertNotEqual(original.imageData, alphaOnly.imageData)
        XCTAssertFalse(deduplicator.shouldKeepFrame(alphaOnly, comparedTo: original,
            threshold: CaptureConfig.defaultDeduplicationThreshold))
    }

    func testAdjacentPairRuleAtVectorAndTileBoundariesWithUnalignedRows() throws {
        // Each 3x3 stroke supplies six adjacent pairs across three rows. Two
        // strokes keep six pairs in one tile even when split across a boundary.
        // Move through all tile/vector alignments with unaligned row padding.
        let original = try renderStrokes(width: 257, height: 257, rectangles: [])
        for offset in 0..<32 {
            let strokes = [CGRect(x: 64 + offset, y: 65, width: 3, height: 3),
                           CGRect(x: 64 + offset, y: 69, width: 3, height: 3)]
            let changed = try renderStrokes(width: 257, height: 257, rectangles: strokes)
            for padding in [0, 1, 3, 17] {
                XCTAssertTrue(deduplicator.shouldKeepFrame(repack(changed, paddingByte: 255, padding: padding),
                    comparedTo: repack(original, paddingByte: 0, padding: padding),
                    threshold: CaptureConfig.defaultDeduplicationThreshold), "Offset \(offset), padding \(padding)")
            }
        }
        for rect in [CGRect(x: 31, y: 65, width: 2, height: 6),
                     CGRect(x: 65, y: 31, width: 3, height: 4),
                     CGRect(x: 65, y: 65, width: 7, height: 2)] {
            let changed = try renderStrokes(width: 257, height: 257, rectangles: [rect])
            XCTAssertFalse(deduplicator.shouldKeepFrame(changed, comparedTo: original,
                threshold: CaptureConfig.defaultDeduplicationThreshold),
                "Pairs cannot cross a tile boundary or count fewer than three rows: \(rect)")
        }
    }

    func testPartialRowsAndLastVisiblePixelIgnorePaddingAndDoNotOverread() throws {
        for width in [1, 2, 3, 4, 5, 7, 8, 31, 32, 33, 127, 129] {
            let original = try renderStrokes(width: width, height: 1024, rectangles: [])
            let changed = try renderStrokes(width: width, height: 1024,
                rectangles: [CGRect(x: max(0, width - 3), y: 65, width: min(3, width), height: 3)])
            // At widths 33/129 the final stroke crosses a 32px tile boundary,
            // leaving only three adjacent pairs in either tile. Narrower
            // canvases can also be retained by the original sampled grid.
            let expected = width != 33 && width != 129
            XCTAssertEqual(deduplicator.shouldKeepFrame(changed, comparedTo: original,
                threshold: CaptureConfig.defaultDeduplicationThreshold), expected)
            for padding in [1, 3, 17] {
                let paddedOriginal = repack(original, paddingByte: 0, padding: padding, omitLastPadding: true)
                let paddedChanged = repack(changed, paddingByte: 255, padding: padding, omitLastPadding: true)
                XCTAssertEqual(deduplicator.shouldKeepFrame(paddedChanged, comparedTo: paddedOriginal,
                    threshold: CaptureConfig.defaultDeduplicationThreshold), expected, "Width \(width), padding \(padding)")
                XCTAssertFalse(deduplicator.shouldKeepFrame(repack(original, paddingByte: 255,
                    padding: padding, omitLastPadding: true), comparedTo: paddedOriginal,
                    threshold: CaptureConfig.defaultDeduplicationThreshold))
            }
        }
    }

    func testMalformedPixelLayoutsFailOpenForCaptureWithoutUnsafeReads() {
        for (width, height, bytesPerRow, count) in [
            (0, 1, 4, 4), (1, 0, 4, 4), (-1, 1, 4, 4),
            (2, 2, 7, 14), (2, 2, 8, 15), (1, 1, 4, 0),
            (Int.max, 1, Int.max, 0), (1, Int.max, 8, 0), (1, 2, Int.max, 0)
        ] {
            let frame = CapturedFrame(timestamp: Date(timeIntervalSince1970: 0),
                imageData: Data(count: count), width: width, height: height,
                bytesPerRow: bytesPerRow, metadata: .empty)
            XCTAssertEqual(deduplicator.computeHash(for: frame), 0)
            XCTAssertEqual(deduplicator.computeSimilarity(frame, frame), 0)
            XCTAssertTrue(deduplicator.shouldKeepFrame(frame, comparedTo: frame,
                threshold: CaptureConfig.defaultDeduplicationThreshold))
        }
    }

    func testConcurrentComparisonsKeepIndependentAdmissionDecisions() async throws {
        let original = try renderInvoice(amount: "$42,000", scale: 1)
        let changed = try renderInvoice(amount: "$47,000", scale: 1)
        let duplicate = try renderInvoice(amount: "$42,000", scale: 1)
        let detector = deduplicator
        await withTaskGroup(of: Bool.self) { group in
            for iteration in 0..<64 {
                let shouldKeep = iteration.isMultiple(of: 2)
                group.addTask {
                    detector.shouldKeepFrame(shouldKeep ? changed : duplicate, comparedTo: original,
                        threshold: CaptureConfig.defaultDeduplicationThreshold) == shouldKeep
                }
            }
            for await correct in group { XCTAssertTrue(correct) }
        }
    }

    func testAdmissionCPUAndWallTimeAtOneTwoAndFourKResolutions() throws {
        let enforceTarget = ProcessInfo.processInfo.environment["RETRACE_DEDUP_PERFORMANCE"] == "1"
        // Opt-in optimized runs disturb caches with 128 MiB before each cold
        // sample. This is benchmark-only memory and never enters capture code.
        var cacheDisturbance = Data(count: enforceTarget ? 128 * 1024 * 1024 : 0)
        for (width, height) in [(1280, 800), (2560, 1600), (3840, 2160)] {
            let original = try renderCanvas(width: width, height: height, gray: 0.5)
            let independentDuplicate = try renderCanvas(width: width, height: height, gray: 0.5)
            let lowContrast = try renderCanvas(width: width, height: height, gray: 0.52)
            let isolatedHighContrast = try renderCanvas(width: width, height: height, gray: 0.5,
                alternatingColumns: true)
            for (label, candidate) in [("independent-duplicate", independentDuplicate),
                                       ("low-contrast-full-scan", lowContrast),
                                       ("isolated-high-contrast-full-scan", isolatedHighContrast)] {
                var cold: [(cpu: Double, wall: Double)] = []
                if enforceTarget {
                    for iteration in 0..<3 {
                        _ = cacheDisturbance.withUnsafeMutableBytes { bytes in
                            bytes.initializeMemory(as: UInt8.self, repeating: UInt8(iteration))
                        }
                        cold.append(timedAdmission(candidate, comparedTo: original))
                    }
                }
                let warm = (0..<(enforceTarget ? 20 : 3)).map { _ in timedAdmission(candidate, comparedTo: original) }
                for (state, samples) in [("cold-128MiB-disturbance", cold), ("warm", warm)] where !samples.isEmpty {
                    let cpu = samples.map(\.cpu).sorted(), wall = samples.map(\.wall).sorted()
                    let p95Index = Int(ceil(Double(samples.count) * 0.95)) - 1
                    print("[DEDUP-PERF] \(width)x\(height) \(label) \(state): cpu-p50-ms=\(cpu[cpu.count / 2]), cpu-p95-ms=\(cpu[p95Index]), wall-p50-ms=\(wall[wall.count / 2]), wall-p95-ms=\(wall[p95Index]), repetitions=\(samples.count)")
                    if enforceTarget {
                        XCTAssertLessThan(cpu[p95Index], 5, "Capture detector target: \(width)x\(height) \(label) \(state)")
                    }
                }
            }
            XCTAssertEqual(deduplicator.computeSimilarity(original, isolatedHighContrast), 1,
                "The sampled grid misses these isolated columns, so the complete local scan must reject them")
        }
    }

    private func timedAdmission(_ candidate: CapturedFrame, comparedTo original: CapturedFrame) -> (cpu: Double, wall: Double) {
        var startCPU = timespec(), endCPU = timespec()
        var startUsage = rusage(), endUsage = rusage()
        getrusage(RUSAGE_SELF, &startUsage)
        let startWall = DispatchTime.now().uptimeNanoseconds
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &startCPU)
        let kept = deduplicator.shouldKeepFrame(candidate, comparedTo: original,
            threshold: CaptureConfig.defaultDeduplicationThreshold)
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &endCPU)
        let elapsedWall = DispatchTime.now().uptimeNanoseconds - startWall
        getrusage(RUSAGE_SELF, &endUsage)
        XCTAssertFalse(kept)
        let cpu = Double(endCPU.tv_sec - startCPU.tv_sec) * 1_000 + Double(endCPU.tv_nsec - startCPU.tv_nsec) / 1_000_000
        if endUsage.ru_minflt != startUsage.ru_minflt || endUsage.ru_majflt != startUsage.ru_majflt {
            print("[DEDUP-FAULTS] \(original.width)x\(original.height): cpu-ms=\(cpu), minor=\(endUsage.ru_minflt - startUsage.ru_minflt), major=\(endUsage.ru_majflt - startUsage.ru_majflt)")
        }
        return (cpu, Double(elapsedWall) / 1_000_000)
    }

    private func assertAdmission(original: CapturedFrame, changed: CapturedFrame, label: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let similarity = deduplicator.computeSimilarity(original, changed)
        print("[DEDUP-FIXTURE] \(label): similarity=\(similarity), threshold=\(CaptureConfig.defaultDeduplicationThreshold)")
        XCTAssertNotEqual(original.imageData, changed.imageData, file: file, line: line)
        XCTAssertTrue(deduplicator.shouldKeepFrame(changed, comparedTo: original,
            threshold: CaptureConfig.defaultDeduplicationThreshold),
            "A meaningful rendered text edit must reach OCR; similarity=\(similarity)", file: file, line: line)
        XCTAssertFalse(deduplicator.shouldKeepFrame(original, comparedTo: original,
            threshold: CaptureConfig.defaultDeduplicationThreshold), file: file, line: line)
    }

    private func decode(_ url: URL) throws -> CapturedFrame {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try makeContext(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try frame(context)
    }

    private func renderInvoice(amount: String, scale: Int) throws -> CapturedFrame {
        let context = try makeContext(width: 1280 * scale, height: 800 * scale)
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.setFillColor(CGColor(gray: 0.94, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1280, height: 800))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 170, y: 80, width: 940, height: 630))
        let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
        for (text, y) in [("Invoice 0042", 650), ("Example Project", 590),
                          ("Amount due: \(amount)", 480), ("Status: DRAFT", 425)] {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1)]
            context.textPosition = CGPoint(x: 230, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
        }
        if let path = ProcessInfo.processInfo.environment["RETRACE_DEDUP_FIXTURE_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let label = amount == "$42,000" ? "a" : "b"
            let url = directory.appendingPathComponent("scale-\(scale)-\(label).png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        return try frame(context)
    }

    private func renderCanvas(width: Int, height: Int, gray: CGFloat, isolatedNoise: Bool = false,
                              alternatingColumns: Bool = false) throws -> CapturedFrame {
        let context = try makeContext(width: width, height: height)
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if isolatedNoise {
            context.setShouldAntialias(false)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            for index in 0..<30 {
                context.fill(CGRect(x: 5 + (index * 37) % width, y: 7 + (index * 29) % height, width: 1, height: 1))
            }
        }
        if alternatingColumns {
            context.setShouldAntialias(false)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            for column in stride(from: 1, to: width, by: 2) {
                context.fill(CGRect(x: column, y: 0, width: 1, height: height))
            }
        }
        return try frame(context)
    }

    private func renderColoredPatch(color: CGColor) throws -> CapturedFrame {
        let context = try makeContext(width: 1024, height: 768)
        context.setShouldAntialias(false)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 768))
        context.setBlendMode(.copy)
        context.setFillColor(color)
        context.fill(CGRect(x: 67, y: 67, width: 3, height: 3))
        return try frame(context)
    }

    private func renderStrokes(width: Int, height: Int, rectangles: [CGRect]) throws -> CapturedFrame {
        let context = try makeContext(width: width, height: height)
        context.setShouldAntialias(false)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for rectangle in rectangles { context.fill(rectangle) }
        return try frame(context)
    }

    private func repack(_ frame: CapturedFrame, paddingByte: UInt8, padding: Int = 64,
                        omitLastPadding: Bool = false) -> CapturedFrame {
        let stride = frame.width * 4 + padding
        var data = Data(repeating: paddingByte, count: stride * frame.height - (omitLastPadding ? padding : 0))
        for row in 0..<frame.height {
            data.replaceSubrange((row * stride)..<(row * stride + frame.width * 4),
                with: frame.imageData[(row * frame.bytesPerRow)..<(row * frame.bytesPerRow + frame.width * 4)])
        }
        return CapturedFrame(timestamp: frame.timestamp, imageData: data, width: frame.width,
            height: frame.height, bytesPerRow: stride, metadata: frame.metadata)
    }

    private func makeContext(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
    }

    private func frame(_ context: CGContext) throws -> CapturedFrame {
        CapturedFrame(timestamp: Date(timeIntervalSince1970: 0),
            imageData: Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * context.height),
            width: context.width, height: context.height, bytesPerRow: context.bytesPerRow, metadata: .empty)
    }
}
