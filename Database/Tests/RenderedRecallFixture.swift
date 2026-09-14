import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import XCTest
import Shared

/// Non-private rendered screens exercise JPEG, HEVC, Vision and SQLite end to end.
/// The two documents intentionally retain the same title while their evidence changes.
enum RenderedRecallFixture {
    static func assertSearchEvidence(_ search: any SearchProtocol, file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = try await search.search(text: "42000", limit: 10)
        let after = try await search.search(text: "47000", limit: 10)
        let negation = try await search.search(text: "\"NOT GRANTED\"", limit: 10)
        XCTAssertEqual(before.results.count, 1, "The first amount must survive OCR/indexing", file: file, line: line)
        XCTAssertEqual(after.results.count, 1, "The later same-title amount must survive", file: file, line: line)
        XCTAssertEqual(negation.results.count, 2, "Negation must survive both saved screens", file: file, line: line)
        XCTAssertNotEqual(before.results.first?.id, after.results.first?.id, "Changed content needs distinct evidence", file: file, line: line)
    }

    static func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pages = [
            ["Cedar proposal", "Amount 42000", "Status DRAFT", "Approval NOT GRANTED", "Meeting tomorrow"],
            ["Cedar proposal", "Amount 47000", "Status SENT", "Approval NOT GRANTED", "Meeting tomorrow"]
        ]
        for (index, lines) in pages.enumerated() {
            guard let context = CGContext(data: nil, width: 1280, height: 800, bitsPerComponent: 8,
                bytesPerRow: 1280 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FixtureError.render }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1280, height: 800))
            let font = CTFontCreateWithName("Menlo" as CFString, 40, nil)
            for (row, text) in lines.enumerated() {
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
                ]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                context.textPosition = CGPoint(x: 64, y: 690 - row * 110)
                CTLineDraw(line, context)
            }
            let url = directory.appendingPathComponent("\(1_700_000_000 + index * 2).jpeg")
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw FixtureError.render
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.98] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw FixtureError.render }
        }
    }
    private enum FixtureError: Error { case render }
}
