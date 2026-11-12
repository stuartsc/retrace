import CryptoKit
import Foundation
import ImageIO
import Shared
import UniformTypeIdentifiers

/// Stateless chunks are bound to both the current exact source reference and PNG
/// digest. Every chunk repeats native disclosure checks; offsets grant no access.
enum RetraceScreenshotCommands {
    private struct Input: Decodable {
        let reference: ScreenEvidenceRef
        let offset: Int?
        let length: Int?
        let sha256: String?
    }
    static func read(_ context: RetraceCommandContext, service: ProgressiveRecallService) async throws -> RetraceJSON {
        let input: Input = try context.decode(keys: ["reference", "offset", "length", "sha256"])
        let offset = input.offset ?? 0, length = input.length ?? 512_000
        guard offset >= 0, offset < 32 * 1024 * 1024, (1...512_000).contains(length),
              offset == 0 || input.sha256 != nil,
              input.sha256.map({ $0.utf8.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }) ?? true else {
            throw RetraceCommandError.invalidArguments
        }
        guard case .screen(let snapshot, let image) = try await service.grantedScreenshot(input.reference, context: context),
              image.width > 0, image.height > 0, image.width <= 16_384,
              image.height <= 16_384, image.width * image.height <= 32 * 1024 * 1024 else {
            throw RetraceCommandError.unavailable
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw RetraceCommandError.unavailable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= 32 * 1024 * 1024 else {
            throw RetraceCommandError.unavailable
        }
        let bytes = data as Data
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard input.sha256 == nil || input.sha256 == digest else { throw RetraceCommandError.revisionConflict }
        guard offset < bytes.count else { throw RetraceCommandError.invalidArguments }
        let end = min(bytes.count, offset + length)
        _ = try await service.grantedScreen(input.reference, context: context)
        try await context.authorize(.evidenceRead)
        return .object(["reference": try .encode(snapshot.ref), "mimeType": .string("image/png"),
            "sha256": .string(digest), "totalBytes": .integer(Int64(bytes.count)),
            "offset": .integer(Int64(offset)), "length": .integer(Int64(end - offset)),
            "nextOffset": end < bytes.count ? .integer(Int64(end)) : .null,
            "base64": .string(bytes.subdata(in: offset..<end).base64EncodedString()),
            "coverage": .string("One exact retained screenshot. Concatenate chunks in byte-offset order and verify SHA-256 before decoding.")])
    }
}
