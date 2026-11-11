import Foundation

/// A permit is obtained before claiming this lane. Ineligible historical work
/// must never occupy the single OCR worker while waiting for quiet time.
public enum FrameProcessingLane: String, Hashable, Sendable {
    case manual, current, historical
}
