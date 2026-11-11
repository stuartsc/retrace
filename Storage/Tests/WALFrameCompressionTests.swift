import CoreGraphics
import CoreText
import Foundation
import Darwin
import XCTest
import Shared
@testable import Storage

final class WALFrameCompressionTests: XCTestCase {
    func testDefaultRemainsV2AndNativeCandidatesRestoreEveryPaddedPixel() throws {
        let frame = fixture()
        let legacy = try WALFrameCodec.encode(frame, path: "fixture")
        XCTAssertEqual(version(legacy.header), 2)
        for codec in [WALFrameCodec.PixelCompression.lzfse, .lz4] {
            let record = try WALFrameCodec.encode(frame, path: "fixture", compression: codec)
            XCTAssertEqual(version(record.header), 3)
            XCTAssertLessThan(record.pixels.count, frame.imageData.count)
            let restored = try read(bytes(record))
            XCTAssertEqual(restored.frame.imageData, frame.imageData)
            XCTAssertEqual(restored.frame.metadata, frame.metadata)
            XCTAssertEqual(restored.frame.bytesPerRow, frame.bytesPerRow)
        }
    }

    func testIncompressibleNativeInputFallsBackToRawWithChecksum() throws {
        var generator = SystemRandomNumberGenerator()
        let frame = fixture(pixels: Data((0..<(272 * 64)).map { _ in UInt8.random(in: 0...255, using: &generator) }))
        let record = try WALFrameCodec.encode(frame, path: "fixture", compression: .lzfse)
        XCTAssertEqual(record.pixels, frame.imageData)
        XCTAssertEqual(record.header[80], 0)
        XCTAssertEqual(try read(bytes(record)).frame.imageData, frame.imageData)
        var damaged = bytes(record)
        damaged[damaged.count - 1] ^= 1
        XCTAssertThrowsError(try read(damaged))
    }

    func testCorruptCodecLengthsChecksumTruncationAndCompressedTrailingBytesFailClosed() throws {
        let record = try WALFrameCodec.encode(fixture(), path: "fixture", compression: .lzfse)
        let original = bytes(record)
        for index in [8, 10, 36, 76, 80, 82, 84] {
            var damaged = original
            damaged[index] ^= 0xff
            XCTAssertThrowsError(try read(damaged), "offset \(index)")
        }
        XCTAssertThrowsError(try read(Data(original.dropLast())))
        var trailing = original
        trailing.append(0)
        var increased = UInt32(record.pixels.count + 1).littleEndian
        withUnsafeBytes(of: &increased) { trailing.replaceSubrange(76..<80, with: $0) }
        XCTAssertThrowsError(try read(trailing))
    }

    func testMixedRecordsRandomSeekAndMetadataScanKeepExactOffsets() throws {
        let frame = fixture()
        let first = try WALFrameCodec.encode(frame, path: "fixture")
        let second = try WALFrameCodec.encode(frame, path: "fixture", compression: .lzfse)
        let data = bytes(first) + bytes(second)
        let descriptor = try read(data, offset: UInt64(first.byteCount), loadPixels: false)
        XCTAssertTrue(descriptor.frame.imageData.isEmpty)
        XCTAssertEqual(descriptor.nextOffset, UInt64(data.count))
        XCTAssertEqual(try read(data, offset: UInt64(first.byteCount)).frame.imageData, frame.imageData)
        var truncatedTail = data
        truncatedTail.removeLast()
        XCTAssertEqual(try read(truncatedTail).frame.imageData, frame.imageData)
        XCTAssertThrowsError(try read(truncatedTail, offset: UInt64(first.byteCount)))
    }

    func testNativeRenderedTextAndDigitChangesRoundTripBothCandidates() throws {
        let width = 640, height = 360, stride = 640 * 4
        var retained = [CapturedFrame]()
        for digit in ["123456.78", "123456.79", "123456.79"] {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 14, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Invoice \(digit) — Australian English 🦘", attributes: attributes))
            context.textPosition = CGPoint(x: 12, y: 160)
            CTLineDraw(line, context)
            let pixels = Data(bytes: try XCTUnwrap(context.data), count: stride * height)
            retained.append(CapturedFrame(timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                imageData: pixels, width: width, height: height, bytesPerRow: stride,
                metadata: FrameMetadata(displayID: 7)))
        }
        XCTAssertNotEqual(retained[0].imageData, retained[1].imageData)
        for codec in [WALFrameCodec.PixelCompression.disabled, .lzfse, .lz4] {
            var stored = 0
            let cpuStart = try processCPUSeconds()
            let start = ProcessInfo.processInfo.systemUptime
            for frame in retained {
                let record = try WALFrameCodec.encode(frame, path: "native-fixture", compression: codec)
                stored += Int(record.byteCount)
                XCTAssertEqual(try read(bytes(record)).frame.imageData, frame.imageData)
            }
            let wall = ProcessInfo.processInfo.systemUptime - start
            let cpu = try processCPUSeconds() - cpuStart
            print("Authored text smoke comparison codec=\(codec) frames=\(retained.count) raw=\(retained.reduce(0) { $0 + $1.imageData.count }) stored=\(stored) encode_write_read_decode_wall_seconds=\(wall) process_cpu_seconds=\(cpu)")
        }
        // This small authored smoke corpus is not representative storage/latency promotion evidence.
    }

    private func processCPUSeconds() throws -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw CocoaError(.fileReadUnknown) }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private func fixture(pixels: Data? = nil) -> CapturedFrame {
        // Native BGRA-shaped bytes with nonzero padding: every retained byte is evidence.
        let data = pixels ?? Data((0..<(272 * 64)).map { UInt8(($0 % 272) / 4) })
        return CapturedFrame(timestamp: Date(timeIntervalSince1970: 1_700_000_000), imageData: data,
            width: 64, height: 64, bytesPerRow: 272,
            metadata: FrameMetadata(appBundleID: "test.compression", appName: "Δ 🦘", displayID: 7))
    }
    private func bytes(_ record: WALFrameCodec.EncodedRecord) -> Data { record.header + record.metadata + record.pixels }
    private func version(_ data: Data) -> UInt16 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt16.self) }.littleEndian }
    private func read(_ data: Data, offset: UInt64 = 0, loadPixels: Bool = true) throws -> WALFrameCodec.DecodedRecord {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let result = try WALFrameCodec.read(handle: handle, path: url.path,
            sourceSize: UInt64(data.count), offset: offset, loadPixels: loadPixels)
        return try XCTUnwrap(result)
    }
}
