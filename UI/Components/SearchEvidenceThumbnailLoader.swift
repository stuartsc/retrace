import Foundation
import CoreGraphics
import Combine
import Shared
import App

enum SearchEvidenceThumbnailError: Error {
    case capacity
}

/// Every exposure resolves the original search proof, including current privacy and deletion checks.
/// Decoding and Core Graphics resizing run on this actor, never on the main actor.
actor SearchEvidenceThumbnailLoader {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let maxConcurrent: Int
    private let maxQueued: Int
    private var active = 0
    private var waiters: [Waiter] = []

    init(maxConcurrent: Int = 2, maxQueued: Int = 32) {
        precondition(maxConcurrent > 0 && maxQueued >= 0)
        self.maxConcurrent = maxConcurrent
        self.maxQueued = maxQueued
    }

    func load(_ result: SearchResult, service: ProgressiveRecallService, size: CGSize) async throws -> CGImage {
        guard size.width.isFinite, size.height.isFinite,
              (1...1024).contains(size.width), (1...1024).contains(size.height) else {
            throw EvidenceUnavailableReason.unsupported
        }
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        let start = Date()
        defer { Log.recordLatency("search.thumbnail.exact", valueMs: Date().timeIntervalSince(start) * 1000, category: .ui) }
        let reference = try await service.reference(searchResult: result)
        switch await service.resolve(.screen(reference), for: .localUser) {
        case .screen(_, let image):
            try Task.checkCancellation()
            let thumbnail = try resize(image, size: size)
            try Task.checkCancellation()
            return thumbnail
        case .unavailable(let reason): throw reason
        case .activity: throw EvidenceUnavailableReason.integrityFailure
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if active < maxConcurrent {
            active += 1
            return
        }
        guard waiters.count < maxQueued else { throw SearchEvidenceThumbnailError.capacity }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().continuation.resume() }
    }

    private func resize(_ image: CGImage, size: CGSize) throws -> CGImage {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EvidenceUnavailableReason.integrityFailure
        }
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let fitted = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: (CGFloat(width) - fitted.width) / 2,
            y: (CGFloat(height) - fitted.height) / 2, width: fitted.width, height: fitted.height))
        guard let thumbnail = context.makeImage() else { throw EvidenceUnavailableReason.integrityFailure }
        return thumbnail
    }
}

/// Holds pixels only for the current visible row. Neither memory nor disk cache keys grant access.
@MainActor
final class SearchEvidenceThumbnailPreview: ObservableObject {
    @Published private var pixels: CGImage?
    @Published private var unavailable = false
    private var key: String?
    private var requestID = UUID()

    func image(for key: String) -> CGImage? { self.key == key ? pixels : nil }
    func isUnavailable(for key: String) -> Bool { self.key == key && unavailable }

    func show(_ result: SearchResult, key: String, loader: SearchEvidenceThumbnailLoader, size: CGSize,
              service: () async throws -> ProgressiveRecallService) async {
        let requestID = UUID()
        self.requestID = requestID
        self.key = key
        pixels = nil
        unavailable = false
        do {
            let image = try await loader.load(result, service: service(), size: size)
            guard self.requestID == requestID, !Task.isCancelled else { return }
            pixels = image
        } catch {
            guard self.requestID == requestID, !Task.isCancelled else { return }
            unavailable = true
        }
    }

    func hide() {
        requestID = UUID()
        key = nil
        pixels = nil
        unavailable = false
    }
}
