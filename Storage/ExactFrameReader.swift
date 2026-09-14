import AVFoundation
import CoreGraphics
import Foundation

/// Evidence reads expose unavailable states without substituting neighboring pixels.
public enum ExactFrameReadError: Error, Equatable, Sendable {
    case recordingMissing
    case frameFinalising
    case integrityFailure
    case cancelled
}

/// Reads a retained encoded frame with independent identity checks.
public enum ExactFrameReader {
    public static func readFrame(videoURL: URL, frameIndex: Int, frameRate: Double,
                                 expectedWidth: Int, expectedHeight: Int) async throws -> CGImage {
        try await readFrame(videoURL: videoURL, frameIndex: frameIndex, frameRate: frameRate,
                            expectedWidth: expectedWidth, expectedHeight: expectedHeight,
                            decoder: { try decodeFrame(videoURL: $0, at: $1) })
    }

    static func readFrame(videoURL: URL, frameIndex: Int, frameRate: Double,
                          expectedWidth: Int, expectedHeight: Int,
                          decoder: @escaping @Sendable (URL, CMTime) throws -> ExactDecodedFrame) async throws -> CGImage {
        guard !Task.isCancelled else { throw ExactFrameReadError.cancelled }
        // AVFoundation's synchronous image decoder and file validation belong on a worker.
        let worker = Task.detached(priority: .userInitiated) {
            try checkCancellation()
            guard videoURL.isFileURL, frameIndex >= 0, frameRate.isFinite, frameRate > 0,
                  expectedWidth > 0, expectedHeight > 0 else {
                throw ExactFrameReadError.integrityFailure
            }
            let seconds = Double(frameIndex) / frameRate
            let timeScale: CMTimeScale = 600_000
            guard seconds.isFinite, seconds >= 0,
                  seconds < Double(Int64.max) / Double(timeScale) else {
                throw ExactFrameReadError.integrityFailure
            }
            let requested = CMTime(seconds: seconds, preferredTimescale: timeScale)
            guard requested.isNumeric else { throw ExactFrameReadError.integrityFailure }
            let initialFile = try fileIdentity(videoURL)
            guard initialFile.size > 0 else { throw ExactFrameReadError.frameFinalising }

            // A new asset and generator are constructed for every attempt. Decoder state
            // retained while a segment was growing must never substitute an older image.
            for attempt in 0..<2 {
                try checkCancellation()
                do {
                    let decoded = try decoder(videoURL, requested)
                    try checkCancellation()
                    guard try fileIdentity(videoURL) == initialFile else {
                        throw ExactFrameReadError.frameFinalising
                    }
                    let actual = decoded.actualTime
                    guard actual.isNumeric, actual.timescale > 0, actual.epoch == requested.epoch,
                          actual.seconds.isFinite, actual.seconds >= 0,
                          decoded.image.width == expectedWidth,
                          decoded.image.height == expectedHeight else {
                        throw ExactFrameReadError.integrityFailure
                    }
                    // Permit only rounding of the requested rational time, never an
                    // adjacent sample (including frame intervals below the old 10 ms guard).
                    let rounding = 1 / Double(timeScale)
                    let difference = abs(CMTimeSubtract(actual, requested).seconds)
                    guard difference.isFinite, difference <= rounding,
                          difference < 0.5 / frameRate else {
                        throw ExactFrameReadError.integrityFailure
                    }
                    try checkCancellation()
                    return decoded.image
                } catch {
                    try checkCancellation()
                    if let exact = error as? ExactFrameReadError,
                       exact != .integrityFailure { throw exact }
                    if attempt == 1 { throw ExactFrameReadError.integrityFailure }
                }
            }
            throw ExactFrameReadError.integrityFailure
        }
        return try await withTaskCancellationHandler {
            let image = try await worker.value
            try checkCancellation()
            return image
        } onCancel: {
            worker.cancel()
        }
    }

    static func decodeFrame(videoURL: URL, at time: CMTime) throws -> ExactDecodedFrame {
        // The persisted native MP4 filename has no extension. A temporary symlink
        // supplies a container hint without changing the retained recording.
        var temporaryURL: URL?
        let assetURL: URL
        if videoURL.pathExtension.isEmpty {
            let link = FileManager.default.temporaryDirectory
                .appendingPathComponent("retrace-exact-\(UUID()).mp4")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: videoURL)
            temporaryURL = link
            assetURL = link
        } else {
            assetURL = videoURL
        }
        defer {
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        }
        let asset = AVURLAsset(url: assetURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var actual = CMTime.invalid
        let image = try generator.copyCGImage(at: time, actualTime: &actual)
        return ExactDecodedFrame(image: image, actualTime: actual)
    }

    private static func checkCancellation() throws {
        if Task.isCancelled { throw ExactFrameReadError.cancelled }
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let modified: Date
    }

    private static func fileIdentity(_ url: URL) throws -> FileIdentity {
        do {
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            guard values[.type] as? FileAttributeType == .typeRegular,
                  let device = values[.systemNumber] as? NSNumber,
                  let inode = values[.systemFileNumber] as? NSNumber,
                  let size = values[.size] as? NSNumber,
                  let modified = values[.modificationDate] as? Date else {
                throw ExactFrameReadError.integrityFailure
            }
            return FileIdentity(device: device.uint64Value, inode: inode.uint64Value,
                                size: size.uint64Value, modified: modified)
        } catch let error as ExactFrameReadError {
            throw error
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            throw ExactFrameReadError.recordingMissing
        } catch {
            throw ExactFrameReadError.integrityFailure
        }
    }
}

struct ExactDecodedFrame: @unchecked Sendable {
    let image: CGImage
    let actualTime: CMTime
}
