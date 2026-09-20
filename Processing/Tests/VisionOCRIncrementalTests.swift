import XCTest
import CoreGraphics
import CoreText
import Shared
@testable import Processing

/// Exercises real CoreText rasterisation, pixel change detection and Vision recognition.
final class VisionOCRIncrementalTests: XCTestCase {
    private let ocr = VisionOCR()
    private let config = ProcessingConfig(accessibilityEnabled: false, minimumConfidence: 0.1)

    func testSparseProportionalTextIsDiscoveredOn4KFrame() async throws {
        let lines = ["Reference ZX842619 amount 9876.54",
            "Invoice ABC12345 total 4200.00 payable Friday", "Cedar proposal amount 47000.00",
            "https://example.test/invoices/ZX842619", "const invoice_id = 842619; total = 9876.54;",
            "Approved on 2026-09-20 for account 17002468"]
        let captured = try frame(width: 3840, height: 2160,
            lines: lines.enumerated().map { ($0.element, 800, CGFloat(300 + $0.offset * 250), 16) },
            fontName: "Helvetica")
        let regions = try await ocr.recognizeText(imageData: captured.imageData, width: captured.width,
            height: captured.height, bytesPerRow: captured.bytesPerRow,
            config: ProcessingConfig(accessibilityEnabled: false, minimumConfidence: 0.5))
        let recognized = regions.map(\.text).joined(separator: " ")
        for text in lines { XCTAssertTrue(recognized.contains(text), "Legible source text was dropped or changed: \(recognized)") }
    }

    func testNativeDiscoveryKeepsLinesWholeAcrossCropBoundaries() async throws {
        let lines = ["Reference ZX842619 amount 9876.54",
            "Invoice ABC12345 total 4200.00 payable Friday", "Cedar proposal amount 47000.00",
            "https://example.test/invoices/ZX842619", "const invoice_id = 842619; total = 9876.54;",
            "Approved on 2026-09-20 for account 17002468"]
        let captured = try frame(width: 3840, height: 2160,
            lines: lines.enumerated().map { ($0.element, 1000, CGFloat(300 + $0.offset * 250), 16) },
            fontName: "Helvetica")
        let regions = try await ocr.recognizeText(imageData: captured.imageData, width: captured.width,
            height: captured.height, bytesPerRow: captured.bytesPerRow, config: config)
        XCTAssertEqual(regions.map(\.text).joined(separator: " "), lines.joined(separator: " "),
                       "Overlapping discovery must not split or duplicate a source line")
    }

    func testDarkScreenPreservesReadingOrderWhenVisionSplitsALine() async throws {
        let lines = ["Reference ZX842619 amount 9876.54",
            "Invoice ABC12345 total 4200.00 payable Friday", "Cedar proposal amount 47000.00",
            "https://example.test/invoices/ZX842619", "const invoice_id = 842619; total = 9876.54;",
            "Approved on 2026-09-20 for account 17002468"]
        let captured = try frame(width: 3840, height: 2160,
            lines: lines.enumerated().map { ($0.element, 800, CGFloat(300 + $0.offset * 250), 14) },
            background: 0.075, foreground: 0.95)
        let regions = try await ocr.recognizeText(imageData: captured.imageData, width: captured.width,
            height: captured.height, bytesPerRow: captured.bytesPerRow, config: config)
        XCTAssertEqual(regions.map(\.text).joined(separator: " "), lines.joined(separator: " "))
    }

    func testPartialRefinementCannotDiscardAlreadyDetectedLines() async throws {
        let captured = try frame(lines: [("Invoice total 4200.00", 80, 130, 32),
                                         ("Reference ZX842619", 80, 170, 32)])
        let discovered = try await ocr.recognizeText(imageData: captured.imageData,
            width: captured.width, height: captured.height, bytesPerRow: captured.bytesPerRow, config: config)
        XCTAssertEqual(discovered.count, 2, "Use real Vision observations of both authored lines")
        guard discovered.count == 2 else { return }
        // Inject a dropped observation at the recognizer boundary. This models
        // a partial Vision response without inventing text or geometry fixtures.
        let partial = [discovered[0]]
        let kept = VisionOCR.completeRefinement(partial, replacing: discovered)
        XCTAssertEqual(kept.map(\.text), discovered.map(\.text))
        XCTAssertEqual(VisionOCR.completeRefinement(discovered, replacing: discovered).map(\.text), discovered.map(\.text))
    }

    func testPartialRefinementCannotDiscardShortTrailingText() async throws {
        for (prefix, suffix) in [("Invoice ABC12345 decision is approved", " NOT"),
                                 ("Invoice reference ABC12345 amount 9876.", "54")] {
            let complete = try frame(lines: [(prefix + suffix, 80, 170, 32)])
            let clipped = try frame(lines: [(prefix, 80, 170, 32)])
            let original = try await ocr.recognizeText(imageData: complete.imageData,
                width: complete.width, height: complete.height, bytesPerRow: complete.bytesPerRow, config: config)
            let partial = try await ocr.recognizeText(imageData: clipped.imageData,
                width: clipped.width, height: clipped.height, bytesPerRow: clipped.bytesPerRow, config: config)
            XCTAssertEqual(original.map(\.text), [prefix + suffix], "Vision must read the complete authored fixture")
            XCTAssertFalse(partial.isEmpty)
            XCTAssertNotEqual(partial.map(\.text), original.map(\.text))
            // A real prefix-only raster models a crop omitting the trailing ink.
            // Its high overlap is not permission to lose a short critical suffix.
            let kept = VisionOCR.completeRefinement(partial, replacing: original)
            XCTAssertEqual(kept.map(\.text), original.map(\.text))
        }
    }

    func testPartialRefinementCannotDropFinalDigitWhenAnotherGlyphDiffers() async throws {
        let completeText = "Invoice ABC12345 amount 9876.54"
        let partialText = "Invoice ABC12346 amount 9876.5"
        let complete = try frame(width: 480, height: 120, lines: [(completeText, 40, 60, 16)])
        let clipped = try frame(width: 480, height: 120, lines: [(partialText, 40, 60, 16)])
        let original = try await ocr.recognizeText(imageData: complete.imageData,
            width: complete.width, height: complete.height, bytesPerRow: complete.bytesPerRow, config: config)
        let partial = try await ocr.recognizeText(imageData: clipped.imageData,
            width: clipped.width, height: clipped.height, bytesPerRow: clipped.bytesPerRow, config: config)
        XCTAssertEqual(original.map(\.text), [completeText])
        XCTAssertEqual(partial.map(\.text), [partialText])
        XCTAssertEqual(VisionOCR.completeRefinement(partial, replacing: original).map(\.text), [completeText],
                       "A changed earlier glyph must not bypass protection for a dropped final digit")
    }

    func testInitial4KFrameRetainsSmallIdentifiersAndAmounts() async throws {
        let identifier = "Reference ZX842619 amount 9876.54"
        let invoice = "Invoice ABC12345 total 4200.00 payable Friday"
        let heading = "Cedar proposal amount 47000.00"
        let captured = try frame(width: 3840, height: 2160, lines: [
            (identifier, 800, 500, 12), (invoice, 800, 800, 16),
            (heading, 800, 1400, 32)
        ])
        let regions = try await ocr.recognizeText(
            imageData: captured.imageData, width: captured.width,
            height: captured.height, bytesPerRow: captured.bytesPerRow, config: config
        )
        let text = regions.map(\.text).joined(separator: " ")
        for expected in [identifier, invoice, heading] {
            XCTAssertTrue(text.contains(expected), "Initial OCR must retain the authored text: \(text)")
        }
        let bounds = try XCTUnwrap(regions.first { $0.text == identifier }?.bounds)
        try assertHighlight(bounds, coversInkIn: captured,
                            area: CGRect(x: 780, y: 470, width: 350, height: 50))
    }

    func test4KCacheRefreshRetainsSmallTextAfterApplicationChange() async throws {
        let text = "Reference ZX842619 amount 9876.54"
        let heading = "Unchanged heading"
        let original = try frame(width: 3840, height: 2160,
                                 lines: [(heading, 100, 200, 48)])
        let pixels = try frame(width: 3840, height: 2160,
                               lines: [(heading, 100, 200, 48), (text, 2430, 1450, 12)])
        let replacement = CapturedFrame(timestamp: pixels.timestamp, imageData: pixels.imageData,
            width: pixels.width, height: pixels.height, bytesPerRow: pixels.bytesPerRow,
            metadata: FrameMetadata(appBundleID: "com.test.other-document"))
        let cache = FullFrameOCRCache()
        _ = try await ocr.recognizeTextRegionBased(frame: original, previousFrame: nil,
                                                  cache: cache, config: config)
        let result = try await ocr.recognizeTextRegionBased(frame: replacement,
            previousFrame: original, cache: cache, config: config)
        XCTAssertTrue(result.regions.contains { $0.text == text },
                      "A cache reset must not reduce detail: \(result.regions.map(\.text))")
        let unchanged = try await ocr.recognizeTextRegionBased(frame: replacement,
            previousFrame: replacement, cache: cache, config: config)
        XCTAssertEqual(unchanged.regions.map(\.text), result.regions.map(\.text))
        XCTAssertEqual(unchanged.stats.tilesOCRed, 0)
    }

    func testOneCharacterEditKeepsEntireLineAndFrameCoordinates() async throws {
        let beforeText = "Invoice ABC12345 total 4200.00 payable Friday"
        let afterText = "Invoice ABC12345 total 9200.00 payable Friday"
        let before = try frame(lines: [(beforeText, 80, 330, 32)])
        let after = try frame(lines: [(afterText, 80, 330, 32)])
        let cache = FullFrameOCRCache()
        let first = try await ocr.recognizeTextRegionBased(frame: before, previousFrame: nil, cache: cache, config: config)
        XCTAssertEqual(first.regions.map(\.text), [beforeText])

        let result = try await ocr.recognizeTextRegionBased(frame: after, previousFrame: before, cache: cache, config: config)
        XCTAssertEqual(result.regions.map(\.text), [afterText], "A changed character must not replace a full line with a cropped fragment")
        let bounds = try XCTUnwrap(result.regions.first?.bounds)
        // Vision's text-detection box can include crop padding. Compare its
        // highlight against the actual rendered pixels rather than another
        // Vision pass's independently estimated box.
        try assertHighlight(bounds, coversInkIn: after, area: CGRect(x: 0, y: 250, width: 1200, height: 150))
        XCTAssertGreaterThan(result.stats.tilesCached, 0)
    }

    func testSmallTextAddedTo4KFrameRetainsNativeCropDetail() async throws {
        let anchor = ("Unchanged heading", CGFloat(100), CGFloat(200), CGFloat(48))
        let identifier = "Reference ZX842619 amount 9876.54"
        let before = try frame(width: 3840, height: 2160, lines: [anchor])
        let after = try frame(width: 3840, height: 2160, lines: [anchor, (identifier, 2430, 1450, 12)], changedArea: CGRect(x: 2400, y: 1400, width: 420, height: 100))
        let cache = FullFrameOCRCache()
        _ = try await ocr.recognizeTextRegionBased(frame: before, previousFrame: nil, cache: cache, config: config)

        let result = try await ocr.recognizeTextRegionBased(frame: after, previousFrame: before, cache: cache, config: config)
        let recognized = try XCTUnwrap(result.regions.first { $0.text == identifier }, "Native-resolution crop must retain the small identifier: \(result.regions.map(\.text))")
        try assertHighlight(recognized.bounds, coversInkIn: after, area: CGRect(x: 2400, y: 1400, width: 420, height: 100))
        XCTAssertEqual(result.regions.filter { $0.text == anchor.0 }.count, 1)
    }

    func testDeletedLineDisappearsAndUnchangedFrameReusesResult() async throws {
        let before = try frame(lines: [("Remove this invoice", 80, 330, 32), ("Keep this heading", 80, 130, 32)])
        let after = try frame(lines: [("Keep this heading", 80, 130, 32)])
        let cache = FullFrameOCRCache()
        _ = try await ocr.recognizeTextRegionBased(frame: before, previousFrame: nil, cache: cache, config: config)
        let result = try await ocr.recognizeTextRegionBased(frame: after, previousFrame: before, cache: cache, config: config)
        XCTAssertEqual(result.regions.map(\.text), ["Keep this heading"])
        let unchanged = try await ocr.recognizeTextRegionBased(frame: after, previousFrame: after, cache: cache, config: config)
        XCTAssertEqual(unchanged.regions.map(\.text), ["Keep this heading"])
        XCTAssertEqual(unchanged.stats.tilesOCRed, 0)
    }

    func testDistantEditsKeepSeparateCompleteTextCrops() async throws {
        let first = "First amount 4200.00 invoice due"
        let second = "Other amount 5100.00 invoice due"
        let before = try frame(width: 1920, height: 1080, lines: [(first, 80, 180, 28), (second, 1000, 850, 28)])
        let after = try frame(width: 1920, height: 1080, lines: [(first.replacingOccurrences(of: "4200", with: "9200"), 80, 180, 28), (second.replacingOccurrences(of: "5100", with: "9100"), 1000, 850, 28)])
        let cache = FullFrameOCRCache()
        _ = try await ocr.recognizeTextRegionBased(frame: before, previousFrame: nil, cache: cache, config: config)
        let result = try await ocr.recognizeTextRegionBased(frame: after, previousFrame: before, cache: cache, config: config)
        XCTAssertEqual(result.regions.map(\.text), ["First amount 9200.00 invoice due", "Other amount 9100.00 invoice due"])
        XCTAssertLessThan(result.stats.tilesOCRed, result.stats.totalTiles / 4, "Distant edits must not bridge most of the frame")
    }

    func testManySeparateChangesUseOneBoundedFullFramePass() async throws {
        let positions: [(CGFloat, CGFloat)] = [(80, 100), (700, 100), (80, 350), (700, 350), (80, 600)]
        let before = try frame(lines: positions.map { ("Reference 4000", $0.0, $0.1, 32) })
        let after = try frame(lines: positions.map { ("Reference 9000", $0.0, $0.1, 32) })
        let cache = FullFrameOCRCache()
        _ = try await ocr.recognizeTextRegionBased(frame: before, previousFrame: nil, cache: cache, config: config)
        let result = try await ocr.recognizeTextRegionBased(frame: after, previousFrame: before, cache: cache, config: config)
        XCTAssertEqual(result.regions.map(\.text), Array(repeating: "Reference 9000", count: 5))
        XCTAssertEqual(result.stats.tilesOCRed, result.stats.totalTiles)
    }

    func testCropExpansionRefreshesNeighborOutsideChangedTile() async throws {
        let before = try frame(lines: [("Reference 4000", 80, 312, 12), ("Amount 4200", 80, 340, 32)])
        let after = try frame(lines: [("Reference 9000", 80, 312, 12), ("Amount 9200", 80, 340, 32)])
        let cache = FullFrameOCRCache()
        let initial = try await ocr.recognizeTextRegionBased(frame: before, previousFrame: nil, cache: cache, config: config)
        XCTAssertEqual(initial.regions.map(\.text), ["Reference 4000", "Amount 4200"])
        let changes = try XCTUnwrap(TileChangeDetector().detectChanges(current: after, previous: before))
        let smallLine = try XCTUnwrap(initial.regions.first)
        XCTAssertFalse(changes.changedTiles.contains { $0.pixelBounds.intersects(smallLine.bounds) }, "Fixture must leave the small neighbor outside initially invalidated tiles")
        let result = try await ocr.recognizeTextRegionBased(frame: after, previousFrame: before, cache: cache, config: config)
        XCTAssertEqual(result.regions.map(\.text).joined(separator: " "), "Reference 9000 Amount 9200", "Expanded crops must replace all intersecting cached text, including the neighbor")
    }

    func testLarge4KChangeRefreshesTheWholeFrameAtNativeResolution() async throws {
        let heading = ("Budget remains bounded", CGFloat(80), CGFloat(160), CGFloat(48))
        let before = try frame(width: 3840, height: 2160, lines: [heading])
        let after = try frame(width: 3840, height: 2160, lines: [heading], changedArea: CGRect(x: 0, y: 0, width: 3840, height: 2160))
        let cache = FullFrameOCRCache()
        _ = try await ocr.recognizeTextRegionBased(frame: before, previousFrame: nil, cache: cache, config: config)
        let result = try await ocr.recognizeTextRegionBased(frame: after, previousFrame: before, cache: cache, config: config)
        XCTAssertEqual(result.regions.map(\.text).joined(separator: " "), heading.0)
        XCTAssertEqual(result.stats.tilesOCRed, result.stats.totalTiles)
        XCTAssertEqual(result.stats.tilesCached, 0)
    }

    func testPixelComparisonRespectsEachFramesRowStride() throws {
        let lines = [("Same captured pixels", CGFloat(80), CGFloat(330), CGFloat(32))]
        let padded = try frame(lines: lines, rowPadding: 128)
        let packed = try frame(lines: lines)
        let result = try XCTUnwrap(TileChangeDetector().detectChanges(current: packed, previous: padded))
        XCTAssertTrue(result.changedTiles.isEmpty, "Different row alignment must not create false image changes")
        XCTAssertEqual(result.unchangedTiles.count, result.totalTiles)
    }

    func testLiveAndArchivedHighlightsCoverTheSameRenderedPixels() async throws {
        let text = "Australian invoice 9246.00"
        let captured = try frame(lines: [(text, 160, 500, 32)])
        let image = try XCTUnwrap(ocr.createCGImage(from: captured.imageData, width: captured.width, height: captured.height, bytesPerRow: captured.bytesPerRow))
        let live = try await ocr.recognizeTextFromCGImage(image)
        XCTAssertEqual(live.map(\.text).joined(separator: " "), text)
        let liveBounds = try XCTUnwrap(live.first?.bounds)
        try assertHighlight(CGRect(x: liveBounds.minX * 1200, y: liveBounds.minY * 700, width: liveBounds.width * 1200, height: liveBounds.height * 700), coversInkIn: captured, area: CGRect(x: 0, y: 400, width: 1200, height: 150))

        let archived = try await ocr.recognizeText(imageData: captured.imageData, width: captured.width, height: captured.height, bytesPerRow: captured.bytesPerRow, config: config)
        XCTAssertEqual(archived.map(\.text).joined(separator: " "), text)
        try assertHighlight(XCTUnwrap(archived.first?.bounds), coversInkIn: captured, area: CGRect(x: 0, y: 400, width: 1200, height: 150))
    }

    func testFastModeKeepsEntireEditedLine() async throws {
        let before = try frame(lines: [("Amount 4200 payable Friday", 80, 330, 32)])
        let after = try frame(lines: [("Amount 9200 payable Friday", 80, 330, 32)])
        let fast = ProcessingConfig(accessibilityEnabled: false, ocrAccuracyLevel: .fast, minimumConfidence: 0.1)
        let cache = FullFrameOCRCache()
        _ = try await ocr.recognizeTextRegionBased(frame: before, previousFrame: nil, cache: cache, config: fast)
        let result = try await ocr.recognizeTextRegionBased(frame: after, previousFrame: before, cache: cache, config: fast)
        XCTAssertEqual(result.regions.map(\.text).joined(separator: " "), "Amount 9200 payable Friday")
    }

    func testBlankFrameDoesNotInventSearchableText() async throws {
        let blank = try frame(lines: [])
        let regions = try await ocr.recognizeText(imageData: blank.imageData, width: blank.width, height: blank.height, bytesPerRow: blank.bytesPerRow, config: config)
        XCTAssertTrue(regions.isEmpty)
    }

    func testTruncatedPixelsAreRejectedBeforeVisionReadsThem() {
        XCTAssertNil(ocr.createCGImage(from: Data(repeating: 255, count: 16), width: 64, height: 64, bytesPerRow: 256))
    }

    private func assertHighlight(
        _ bounds: CGRect,
        coversInkIn frame: CapturedFrame,
        area: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var minX = frame.width
        var minY = frame.height
        var maxX = 0
        var maxY = 0
        frame.imageData.withUnsafeBytes { storage in
            let pixels = storage.bindMemory(to: UInt8.self)
            for y in Int(area.minY)..<Int(area.maxY) {
                for x in Int(area.minX)..<Int(area.maxX) {
                    let offset = y * frame.bytesPerRow + x * 4
                    if pixels[offset] < 64 && pixels[offset + 1] < 64 && pixels[offset + 2] < 64 {
                        minX = min(minX, x)
                        minY = min(minY, y)
                        maxX = max(maxX, x + 1)
                        maxY = max(maxY, y + 1)
                    }
                }
            }
        }
        XCTAssertLessThan(minX, maxX, "Fixture must contain actual text pixels", file: file, line: line)
        let ink = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        XCTAssertTrue(bounds.insetBy(dx: -3, dy: -3).contains(ink), "Highlight \(bounds) must cover text pixels \(ink)", file: file, line: line)
        XCTAssertTrue(ink.insetBy(dx: -16, dy: -16).contains(bounds), "Highlight \(bounds) must stay near text pixels \(ink)", file: file, line: line)
    }

    private func frame(
        width: Int = 1200,
        height: Int = 700,
        lines: [(String, CGFloat, CGFloat, CGFloat)],
        changedArea: CGRect? = nil,
        rowPadding: Int = 0,
        fontName: String = "Menlo",
        background: CGFloat = 1,
        foreground: CGFloat = 0
    ) throws -> CapturedFrame {
        let bytesPerRow = width * 4 + rowPadding
        var data = Data(count: bytesPerRow * height)
        try data.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ))
            context.setFillColor(CGColor(gray: background, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if let area = changedArea {
                context.setFillColor(CGColor(gray: 0.88, alpha: 1))
                context.fill(CGRect(x: area.minX, y: CGFloat(height) - area.maxY, width: area.width, height: area.height))
            }
            for (text, x, baselineFromTop, size) in lines {
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(fontName as CFString, size, nil),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: foreground, alpha: 1)
                ]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                context.textPosition = CGPoint(x: x, y: CGFloat(height) - baselineFromTop)
                CTLineDraw(line, context)
            }
        }
        return CapturedFrame(imageData: data, width: width, height: height, bytesPerRow: bytesPerRow)
    }
}
