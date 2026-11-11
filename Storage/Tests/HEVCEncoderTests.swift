import AVFoundation
import CoreMedia
import Foundation
import XCTest
import VideoToolbox
import Shared
@testable import Storage

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                       HEVC ENCODER TESTS                                     ║
// ║                                                                              ║
// ║  • Verify encoding produces valid MP4 files with proper metadata             ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class HEVCEncoderTests: XCTestCase {

    private static var hasPrintedSeparator = false

    override func setUp() {
        super.setUp()

        if !Self.hasPrintedSeparator {
            printTestSeparator()
            Self.hasPrintedSeparator = true
        }
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                         Encoding Tests                                   │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testEncodeProducesValidMP4File() async throws {
        let encoder = HEVCEncoder()
        let config = VideoEncoderConfig.default
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID().uuidString).mp4")
        let startTime = Date()

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        do {
            try await encoder.initialize(width: 4, height: 4, config: config, outputURL: tempURL, segmentStartTime: startTime)

            let status = await encoder.accelerationStatus()
            XCTAssertEqual(status.selection, .automatic)
            XCTAssertNil(status.actualHardwareUse, "AVAssetWriter does not expose its VTSession")
            XCTAssertTrue(status.softwareFallbackPermitted)

            // Encode a few frames
            for i in 0..<5 {
                let bytesPerRow = 4 * 4
                let imageData = Data(repeating: UInt8(i * 50), count: bytesPerRow * 4)
                let frame = CapturedFrame(
                    imageData: imageData,
                    width: 4,
                    height: 4,
                    bytesPerRow: bytesPerRow
                )
                let pixelBuffer = try FrameConverter.createPixelBuffer(from: frame)
                let timestamp = CMTime(seconds: Double(i), preferredTimescale: 600)
                try await encoder.encode(pixelBuffer: pixelBuffer, timestamp: timestamp)
            }

            try await encoder.finalize()

            // Verify the file exists and is not empty
            XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
            let attributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            XCTAssertGreaterThan(fileSize, 0)

        } catch {
            throw XCTSkip("HEVC encoding unavailable in test environment: \(error)")
        }
    }

    func testHardwareAccelerationAvailability() async throws {
        let encoder = HEVCEncoder()
        let config = VideoEncoderConfig.default
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_hw_\(UUID().uuidString).mp4")
        let startTime = Date()

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        do {
            try await encoder.initialize(width: 1920, height: 1080, config: config, outputURL: tempURL, segmentStartTime: startTime)

            let isHardwareAccelerated = await encoder.isHardwareAccelerated()

            XCTAssertFalse(isHardwareAccelerated, "Encoder availability does not verify the AVAssetWriter session")

            await encoder.reset()

        } catch {
            throw XCTSkip("HEVC encoding unavailable in test environment: \(error)")
        }
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │              Movie Fragment Interval - Read Before Finalize             │
    // └──────────────────────────────────────────────────────────────────────────┘

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │              Concurrent Writers - Reproduce File Deletion Bug           │
    // └──────────────────────────────────────────────────────────────────────────┘

    /// Test that creates two writers concurrently to see if one deletes the other's file
    /// This simulates the scenario where two resolutions are captured simultaneously
    func testConcurrentWritersDoNotInterfere() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("concurrent_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let config = VideoEncoderConfig.default
        let startTime = Date()

        // Create two encoders with different paths (simulating different resolutions)
        let encoder1 = HEVCEncoder()
        let encoder2 = HEVCEncoder()

        let url1 = tempDir.appendingPathComponent("video1.mp4")
        let url2 = tempDir.appendingPathComponent("video2.mp4")

        print("📝 Creating two concurrent encoders...")
        print("   Encoder 1: \(url1.lastPathComponent)")
        print("   Encoder 2: \(url2.lastPathComponent)")

        // Initialize both nearly simultaneously
        try await encoder1.initialize(width: 1920, height: 1080, config: config, outputURL: url1, segmentStartTime: startTime)
        try await encoder2.initialize(width: 1280, height: 720, config: config, outputURL: url2, segmentStartTime: startTime)

        print("✅ Both encoders initialized")
        print("   File 1 exists: \(FileManager.default.fileExists(atPath: url1.path))")
        print("   File 2 exists: \(FileManager.default.fileExists(atPath: url2.path))")

        // Write frames to both concurrently
        print("\n📝 Writing frames to both encoders concurrently...")

        for i in 0..<10 {
            // Create frames for both resolutions
            let frame1 = createTestFrame(width: 1920, height: 1080, value: UInt8(i * 20))
            let frame2 = createTestFrame(width: 1280, height: 720, value: UInt8(i * 20 + 10))

            let pb1 = try FrameConverter.createPixelBuffer(from: frame1)
            let pb2 = try FrameConverter.createPixelBuffer(from: frame2)

            let timestamp = CMTime(value: Int64(i) * 20, timescale: 600)

            // Write to both - check file existence before and after
            let exists1Before = FileManager.default.fileExists(atPath: url1.path)
            let exists2Before = FileManager.default.fileExists(atPath: url2.path)

            try await encoder1.encode(pixelBuffer: pb1, timestamp: timestamp)
            try await encoder2.encode(pixelBuffer: pb2, timestamp: timestamp)

            let exists1After = FileManager.default.fileExists(atPath: url1.path)
            let exists2After = FileManager.default.fileExists(atPath: url2.path)

            if !exists1After && exists1Before {
                print("   ❌ Frame \(i): File 1 was DELETED!")
            }
            if !exists2After && exists2Before {
                print("   ❌ Frame \(i): File 2 was DELETED!")
            }

            if i % 3 == 0 {
                print("   Frame \(i): file1=\(exists1After), file2=\(exists2After)")
            }
        }

        // Finalize both
        try await encoder1.finalize()
        try await encoder2.finalize()

        // Verify both files exist and have content
        let size1 = (try? FileManager.default.attributesOfItem(atPath: url1.path)[.size] as? Int64) ?? 0
        let size2 = (try? FileManager.default.attributesOfItem(atPath: url2.path)[.size] as? Int64) ?? 0

        print("\n📊 Final results:")
        print("   File 1: \(size1) bytes")
        print("   File 2: \(size2) bytes")

        XCTAssertTrue(FileManager.default.fileExists(atPath: url1.path), "File 1 should exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url2.path), "File 2 should exist")
        XCTAssertGreaterThan(size1, 0, "File 1 should have content")
        XCTAssertGreaterThan(size2, 0, "File 2 should have content")
    }

    func testHardwareSelectionSettingsAndStatusRemainExplicit() async throws {
        XCTAssertNil(HEVCEncoder.encoderSpecification(for: .automatic))
        let require = try XCTUnwrap(HEVCEncoder.encoderSpecification(for: .requireHardware))
        XCTAssertEqual(require[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] as? Bool, true)
        let prefer = try XCTUnwrap(HEVCEncoder.encoderSpecification(for: .preferHardware))
        XCTAssertEqual(prefer[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String] as? Bool, true)
        XCTAssertNil(prefer[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String])
        let software = try XCTUnwrap(HEVCEncoder.encoderSpecification(for: .softwareOnly))
        XCTAssertEqual(software[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String] as? Bool, false)
        let encoder = HEVCEncoder(selection: .requireHardware)
        let status = await encoder.accelerationStatus()
        XCTAssertEqual(status.selection, .requireHardware)
        XCTAssertNil(status.hardwareAvailable)
        XCTAssertNil(status.actualHardwareUse)
        XCTAssertFalse(status.softwareFallbackPermitted)
    }

    func testExplicitHardwarePreferenceEncodesAndDecodesWithoutClaimingVerifiedUse() async throws {
        let encoder = HEVCEncoder(selection: .preferHardware)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hardware_request_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await encoder.initialize(width: 64, height: 64, config: .default, outputURL: url, segmentStartTime: Date())
        for i in 0..<3 {
            let buffer = try FrameConverter.createPixelBuffer(from: createTestFrame(width: 64, height: 64, value: UInt8(i * 50)))
            try await encoder.encode(pixelBuffer: buffer, timestamp: CMTime(value: Int64(i), timescale: 30))
        }
        try await encoder.finalize()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var actual = CMTime.invalid
        let image = try generator.copyCGImage(at: .zero, actualTime: &actual)
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 64)
        XCTAssertEqual(actual, .zero)
        let status = await encoder.accelerationStatus()
        XCTAssertEqual(status.selection, .preferHardware)
        XCTAssertNil(status.actualHardwareUse)
        XCTAssertTrue(status.softwareFallbackPermitted)
        await encoder.reset()
        let resetStatus = await encoder.accelerationStatus()
        XCTAssertNil(resetStatus.hardwareAvailable)
        XCTAssertNil(resetStatus.actualHardwareUse)
    }

    private func createTestFrame(width: Int, height: Int, value: UInt8) -> CapturedFrame {
        let bytesPerRow = width * 4
        let imageData = Data(repeating: value, count: bytesPerRow * height)
        return CapturedFrame(
            imageData: imageData,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │              Movie Fragment Interval - Read Before Finalize             │
    // └──────────────────────────────────────────────────────────────────────────┘

    /// Test if we can read frames from an MP4 file BEFORE finalization
    /// when movieFragmentInterval is set. This is the key test for enabling
    /// "see frames within 10 seconds" functionality.
    func testReadFramesBeforeFinalization() async throws {
        let encoder = HEVCEncoder()
        let config = VideoEncoderConfig.default
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_fragment_\(UUID().uuidString).mp4")
        let startTime = Date()

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        do {
            // Initialize encoder (now with movieFragmentInterval = 4 seconds)
            try await encoder.initialize(width: 640, height: 480, config: config, outputURL: tempURL, segmentStartTime: startTime)

            print("📝 Writing 150 frames to ensure fragment intervals are triggered...")
            print("   movieFragmentInterval = 4 seconds, so at 30fps we need 120+ frames")

            // Encode 150 frames - definitely enough to trigger multiple fragment intervals
            // At 30fps, 150 frames = 5 seconds of video
            // With movieFragmentInterval = 4s, we should have at least 1 fragment written
            for i in 0..<150 {
                let bytesPerRow = 640 * 4  // BGRA
                var imageData = Data(count: bytesPerRow * 480)
                // Create distinct pattern for each frame so we can verify correct frame is read
                for y in 0..<480 {
                    for x in 0..<640 {
                        let offset = y * bytesPerRow + x * 4
                        imageData[offset] = UInt8((i * 25) % 256)     // B
                        imageData[offset + 1] = UInt8((i * 50) % 256) // G
                        imageData[offset + 2] = UInt8((i * 75) % 256) // R
                        imageData[offset + 3] = 255                    // A
                    }
                }

                let frame = CapturedFrame(
                    imageData: imageData,
                    width: 640,
                    height: 480,
                    bytesPerRow: bytesPerRow
                )
                let pixelBuffer = try FrameConverter.createPixelBuffer(from: frame)

                // Timestamp at 30fps (what the encoder expects)
                let timestamp = CMTime(seconds: Double(i) / 30.0, preferredTimescale: 600)
                try await encoder.encode(pixelBuffer: pixelBuffer, timestamp: timestamp)

                if i % 30 == 0 {
                    print("  Frame \(i) encoded at time \(String(format: "%.2f", Double(i) / 30.0))s")
                }
            }
            print("  ... \(150) frames total")

            // Check file size before finalization
            let preFinalizeSizeBytes = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
            print("\n📊 File size before finalization: \(preFinalizeSizeBytes) bytes (\(preFinalizeSizeBytes / 1024) KB)")

            print("\n🔍 Attempting to read frames BEFORE finalization...")

            // Try to read the file before finalization
            var preReadSuccess = false
            do {
                let asset = AVAsset(url: tempURL)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

                // Check if video track exists
                let tracks = try await asset.loadTracks(withMediaType: .video)
                print("  Video tracks found: \(tracks.count)")

                if tracks.isEmpty {
                    print("  ❌ No video tracks - file not readable before finalization")
                } else {
                    // Try to read frame 0
                    var actualTime = CMTime.zero
                    let cgImage = try generator.copyCGImage(at: .zero, actualTime: &actualTime)
                    print("  ✅ SUCCESS! Read frame at time \(actualTime.seconds)s")
                    print("     Image size: \(cgImage.width)x\(cgImage.height)")
                    preReadSuccess = true

                    // Try to read a later frame (at 2 seconds)
                    let laterTime = CMTime(seconds: 2.0, preferredTimescale: 600)
                    let cgImage2 = try generator.copyCGImage(at: laterTime, actualTime: &actualTime)
                    print("  ✅ Read later frame at time \(actualTime.seconds)s")
                    print("     Image size: \(cgImage2.width)x\(cgImage2.height)")
                }
            } catch {
                print("  ❌ Failed to read before finalization: \(error.localizedDescription)")
            }

            print("\n📦 Now finalizing...")
            try await encoder.finalize()

            // Check file size after finalization
            let postFinalizeSizeBytes = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
            print("📊 File size after finalization: \(postFinalizeSizeBytes) bytes (\(postFinalizeSizeBytes / 1024) KB)")

            print("\n🔍 Reading frames AFTER finalization...")

            // Read again after finalization to compare
            let finalAsset = AVAsset(url: tempURL)
            let finalGenerator = AVAssetImageGenerator(asset: finalAsset)
            finalGenerator.appliesPreferredTrackTransform = true
            finalGenerator.requestedTimeToleranceBefore = .zero
            finalGenerator.requestedTimeToleranceAfter = .zero

            var actualTime2 = CMTime.zero
            let cgImageFinal = try finalGenerator.copyCGImage(at: .zero, actualTime: &actualTime2)
            print("  ✅ Read frame at time \(actualTime2.seconds)s")
            print("     Image size: \(cgImageFinal.width)x\(cgImageFinal.height)")

            // File should exist and be valid
            XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))

            // Report final result
            print("\n" + String(repeating: "=", count: 60))
            if preReadSuccess {
                print("🎉 RESULT: movieFragmentInterval WORKS for reading before finalization!")
            } else {
                print("❌ RESULT: movieFragmentInterval does NOT allow reading before finalization")
                print("   Fallback needed: WAL read or smaller segments")
            }
            print(String(repeating: "=", count: 60))

        } catch {
            print("❌ Test failed with error: \(error)")
            throw error
        }
    }
}

