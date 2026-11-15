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

            // Generators are cached per file identity and dropped after any failed attempt,
            // so a retry always uses a freshly opened asset and a changed file is never
            // served from older decoder state.
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
                    // Every failed attempt discards the cached generator so the retry
                    // (and any later read) starts from a freshly opened asset.
                    generatorCache.evict(path: videoURL.path)
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

    /// At most this many opened recordings (asset + generator) stay resident.
    static let maximumCachedGenerators = 3
    private static let generatorCache = GeneratorCache(limit: maximumCachedGenerators)

    /// Test seams: how many assets were opened, how many entries are resident.
    static var assetOpenCountForTesting: Int { generatorCache.openCount }
    static var cachedGeneratorCountForTesting: Int { generatorCache.count }
    static func clearGeneratorCacheForTesting() { generatorCache.removeAll() }

    static func decodeFrame(videoURL: URL, at time: CMTime) throws -> ExactDecodedFrame {
        // A cached generator is only reused while the file's device, inode, size and
        // modification time are unchanged; any other identity opens a fresh asset.
        let identity = try fileIdentity(videoURL)
        let entry = try generatorCache.acquire(path: videoURL.path, identity: identity) {
            try CachedGenerator(videoURL: videoURL, identity: identity)
        }
        do {
            return try entry.decode(at: time)
        } catch {
            generatorCache.evict(path: videoURL.path)
            throw error
        }
    }

    /// One opened recording. Zero tolerance is configured exactly as for a cold decode.
    private final class CachedGenerator: @unchecked Sendable {
        let path: String
        let identity: FileIdentity
        private let linkURL: URL?
        private let generator: AVAssetImageGenerator
        // AVAssetImageGenerator is not documented as safe for concurrent copyCGImage
        // on one instance, so decodes on the same entry are serialised.
        private let decodeLock = NSLock()

        init(videoURL: URL, identity: FileIdentity) throws {
            // The persisted native MP4 filename has no extension. A temporary symlink
            // supplies a container hint without changing the retained recording.
            // It lives as long as the entry and is removed in deinit.
            var link: URL?
            let assetURL: URL
            if videoURL.pathExtension.isEmpty {
                let created = FileManager.default.temporaryDirectory
                    .appendingPathComponent("retrace-exact-\(UUID()).mp4")
                try FileManager.default.createSymbolicLink(at: created, withDestinationURL: videoURL)
                link = created
                assetURL = created
            } else {
                assetURL = videoURL
            }
            let asset = AVURLAsset(url: assetURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            self.path = videoURL.path
            self.identity = identity
            self.linkURL = link
            self.generator = generator
        }

        deinit {
            if let linkURL { try? FileManager.default.removeItem(at: linkURL) }
        }

        func decode(at time: CMTime) throws -> ExactDecodedFrame {
            decodeLock.lock()
            defer { decodeLock.unlock() }
            var actual = CMTime.invalid
            let image = try generator.copyCGImage(at: time, actualTime: &actual)
            return ExactDecodedFrame(image: image, actualTime: actual)
        }
    }

    /// Small LRU guarded by a lock; the last element is the most recently used.
    private final class GeneratorCache: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var entries: [CachedGenerator] = []
        private var opened = 0

        init(limit: Int) { self.limit = limit }

        var openCount: Int { lock.lock(); defer { lock.unlock() }; return opened }
        var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

        func acquire(path: String, identity: FileIdentity,
                     open: () throws -> CachedGenerator) throws -> CachedGenerator {
            lock.lock()
            defer { lock.unlock() }
            if let index = entries.firstIndex(where: { $0.path == path && $0.identity == identity }) {
                let hit = entries.remove(at: index)
                entries.append(hit)
                return hit
            }
            // A changed file never reuses an older generator for the same path.
            entries.removeAll { $0.path == path }
            let created = try open()
            opened += 1
            entries.append(created)
            while entries.count > limit { entries.removeFirst() }
            return created
        }

        func evict(path: String) {
            lock.lock()
            defer { lock.unlock() }
            entries.removeAll { $0.path == path }
        }

        func removeAll() {
            lock.lock()
            defer { lock.unlock() }
            entries.removeAll()
        }
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
