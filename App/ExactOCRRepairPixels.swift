import CoreGraphics
import Foundation
import Shared

enum ExactOCRRepairPixels {
    static func frame(_ image: CGImage, target: ExactOCRRepairTarget) async throws -> CapturedFrame {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let width = image.width, height = image.height
            guard (1...16_384).contains(width), (1...16_384).contains(height),
                  width * height <= 33_554_432,
                  target.snapshot.width == 0 || target.snapshot.width == width,
                  target.snapshot.height == 0 || target.snapshot.height == height else { throw ExactOCRRepairError.invalidPixels }
            let stride = width * 4
            var data = Data(count: stride * height)
            let drawn = data.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { throw ExactOCRRepairError.invalidPixels }
            try Task.checkCancellation()
            return CapturedFrame(timestamp: target.snapshot.frame.timestamp, imageData: data,
                width: width, height: height, bytesPerRow: stride, metadata: target.snapshot.frame.metadata)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
