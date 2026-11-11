import CoreGraphics
import Foundation
import Shared

/// Public WindowServer inventory, sampled outside native notification callbacks.
struct CaptureDisplayDescriptor: Sendable, Equatable {
    let displayID: UInt32
    let monitorUUID: UUID
    let bounds: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let rotationDegrees: Double
    let refreshRateHz: Double
    let modeID: UInt32

    func attachment(id: UUID) -> CaptureDisplayAttachment {
        .init(attachmentID: id, displayID: displayID, monitorUUID: monitorUUID, bounds: bounds,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight, rotationDegrees: rotationDegrees,
            refreshRateHz: refreshRateHz, modeID: modeID)
    }
}

/// A separate notification generation catches mode/attachment A→B→A even when
/// before/after geometry is identical. The callback only invalidates locked
/// state; it performs no WindowServer query, task creation or filesystem work.
final class CaptureDisplayAttachmentTracker: @unchecked Sendable {
    private struct Entry { let descriptor: CaptureDisplayDescriptor; let attachment: CaptureDisplayAttachment }
    private let lock = NSLock()
    private let observeNativeChanges: Bool
    private var entries: [UInt32: Entry] = [:]
    private var invalidated: Set<UInt32> = []
    private var invalidateAll = false
    private var configuring: Set<UInt32> = []
    private var configurationOverflow = false
    private var active = false
    private var registered = false

    init(observeNativeChanges: Bool = true) { self.observeNativeChanges = observeNativeChanges }
    deinit { stop() }

    func start() throws {
        lock.withLock { entries.removeAll(); invalidated.removeAll(); invalidateAll = false; configuring.removeAll(); configurationOverflow = false; active = true }
        guard observeNativeChanges, !registered else { return }
        let result = CGDisplayRegisterReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
        guard result == .success else {
            lock.withLock { active = false }
            throw CaptureError.captureSessionFailed(underlying: "Display lifetime notifications are unavailable")
        }
        registered = true
    }

    func stop() {
        lock.withLock { active = false; entries.removeAll(); invalidated.removeAll(); invalidateAll = false; configuring.removeAll(); configurationOverflow = false }
        if registered {
            CGDisplayRemoveReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
            registered = false
        }
    }

    func noteReconfiguration(displayID: UInt32, beginsConfiguration: Bool? = nil) {
        lock.withLock {
            guard active else { return }
            if let beginsConfiguration {
                if beginsConfiguration {
                    if configuring.count < CaptureSamplingGroup.maximumTargets { configuring.insert(displayID) }
                    else { configurationOverflow = true }
                } else { configuring.remove(displayID) }
            }
            if invalidated.count < CaptureSamplingGroup.maximumTargets { invalidated.insert(displayID) }
            else { invalidateAll = true; invalidated.removeAll() }
        }
    }

    /// Full inventory is mandatory; passing only selected targets would mistake
    /// an attached but currently unselected display for physical removal.
    func sample(_ descriptors: [CaptureDisplayDescriptor]) throws -> [UInt32: CaptureDisplayAttachment] {
        try lock.withLock {
            guard active, descriptors.count <= CaptureSamplingGroup.maximumTargets,
                  Set(descriptors.map(\.displayID)).count == descriptors.count else {
                throw CaptureError.noDisplaysAvailable
            }
            let present = Set(descriptors.map(\.displayID))
            entries = entries.filter { present.contains($0.key) }
            for descriptor in descriptors {
                let old = entries[descriptor.displayID]
                if old?.descriptor != descriptor || invalidateAll || invalidated.contains(descriptor.displayID) {
                    entries[descriptor.displayID] = Entry(descriptor: descriptor, attachment: descriptor.attachment(id: UUID()))
                }
            }
            invalidated.removeAll(); invalidateAll = false
            return entries.mapValues(\.attachment)
        }
    }

    func isCurrent(_ attachment: CaptureDisplayAttachment) -> Bool {
        lock.withLock {
            active && configuring.isEmpty && !configurationOverflow && !invalidateAll && !invalidated.contains(attachment.displayID) &&
                entries[attachment.displayID]?.attachment == attachment
        }
    }

    private static let callback: CGDisplayReconfigurationCallBack = { display, flags, userInfo in
        guard let userInfo else { return }
        Unmanaged<CaptureDisplayAttachmentTracker>.fromOpaque(userInfo).takeUnretainedValue()
            .noteReconfiguration(displayID: display, beginsConfiguration: flags.contains(.beginConfigurationFlag))
    }
}

/// The reserved identity exists before AX/pre-read; the callback records only a
/// real native-call interval, including native nil/throw outcomes.
struct CapturePixelAttempt: Sendable {
    let id: UUID
    let didRead: @Sendable (CapturePixelReceipt) -> Void
}

final class CapturePixelReceiptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var receipt: CapturePixelReceipt?
    func store(_ value: CapturePixelReceipt) { lock.withLock { if receipt == nil { receipt = value } } }
    var value: CapturePixelReceipt? { lock.withLock { receipt } }
}
