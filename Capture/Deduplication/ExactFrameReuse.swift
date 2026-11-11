import CryptoKit
import Foundation
import Shared

/// Full immutable BGRA equality, never a perceptual hash or sampled tile test.
/// Attachment/session/attempt identity is additionally checked by the manager
/// and durable journal. Padding is included conservatively in this v1 digest.
enum ExactFrameReuse {
    static func comparison(_ frame: CapturedFrame, previous: CapturedFrame?,
                           directTextEnabled: Bool) -> CaptureSimilarityComparison? {
        guard let previous, frame.width > 0, frame.width <= 16_384,
              frame.height > 0, frame.height <= 16_384, frame.width * frame.height <= 33_554_432,
              frame.bytesPerRow >= frame.width * 4, frame.bytesPerRow <= 131_072,
              frame.width == previous.width, frame.height == previous.height,
              frame.bytesPerRow == previous.bytesPerRow,
              frame.imageData.count == frame.bytesPerRow * frame.height,
              frame.metadata.displayID == previous.metadata.displayID,
              frame.metadata.capturePolicySHA256 == previous.metadata.capturePolicySHA256,
              frame.metadata.captureContext == previous.metadata.captureContext,
              frame.metadata.appBundleID == previous.metadata.appBundleID,
              frame.metadata.windowName == previous.metadata.windowName,
              frame.metadata.browserURL == previous.metadata.browserURL,
              frame.metadata.redactionReason == previous.metadata.redactionReason,
              frame.imageData == previous.imageData,
              !directTextEnabled || !DirectTextDeduplication.hasNewEvidence(frame, comparedTo: previous) else { return nil }
        let hash = SHA256.hash(data: frame.imageData).map { String(format: "%02x", $0) }.joined()
        return .init(exactPixelSHA256: hash, directTextEnabled: directTextEnabled)
    }
}
