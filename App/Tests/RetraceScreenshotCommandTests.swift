import CoreGraphics
import CryptoKit
import Database
import Foundation
import ImageIO
import Shared
import Storage
import UniformTypeIdentifiers
import XCTest
@testable import App

/// Real private SQLite identities and native PNG bytes; no screen capture or live library access.
final class RetraceScreenshotCommandTests: XCTestCase {
    private var root: URL!
    private var database: DatabaseManager!
    private var adapter: DataAdapter!
    private var dispatcher: RetraceCommandDispatcher!
    private var policy: ScreenshotCommandPolicy!
    private var outputGate: ScreenshotCommandOutputGate!
    private var imageReads: ScreenshotCommandImageReads!
    private var reference: ScreenEvidenceRef!
    private var image: CGImage!
    private var expectedPNG: Data!
    private var segmentID: Int64!
    private let token = "screenshot-fixture-token-32-characters-minimum"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-command-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        // A unique private memory URI bypasses the installed encryption setting
        // and Keychain. The dispatcher ledger alone uses the private directory.
        database = DatabaseManager(databasePath: "file:screenshot-command-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let connection = try await database.makeRecallReadConnection()
        adapter = DataAdapter(retraceConnection: connection,
            retraceConfig: .init(dateFormatter: nil, storageRoot: root.path, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root.path), database: database)
        try await adapter.initialize()

        let image = try Self.authoredImage(width: 640, height: 480)
        self.image = image
        expectedPNG = try Self.png(image)
        let policy = ScreenshotCommandPolicy()
        let imageReads = ScreenshotCommandImageReads()
        let outputGate = ScreenshotCommandOutputGate()
        self.policy = policy; self.imageReads = imageReads; self.outputGate = outputGate
        let service = ProgressiveRecallService(database: database, adapter: adapter,
            configuration: { await policy.config() }, disclosureState: { await policy.state() },
            imageReader: { item in
                await imageReads.record(item.frame.id)
                return image
            })
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = FrameMetadata(appBundleID: "com.fixture.screenshot", appName: "Authored Fixture",
            windowName: "Private screenshot fixture")
        segmentID = try await database.insertSegment(bundleID: "com.fixture.screenshot",
            startDate: timestamp, endDate: timestamp, windowName: metadata.windowName, browserUrl: nil, type: 0)
        let frameID = FrameID(value: try await database.insertFrame(.init(id: .init(value: 0),
            timestamp: timestamp, segmentID: .init(value: segmentID), frameIndexInSegment: 0, metadata: metadata)))
        _ = try await database.commitFrameOCR(frameID: frameID,
            text: ExtractedText(frameID: frameID, timestamp: timestamp,
                regions: [TextRegion(frameID: frameID, text: "Authored screenshot evidence",
                    bounds: CGRect(x: 5, y: 5, width: 100, height: 30))], metadata: metadata),
            frameWidth: image.width, frameHeight: image.height)
        reference = try await service.reference(frameID: frameID, source: .native)
        dispatcher = try RetraceCommandDispatcher(directory: root,
            grants: [.init(clientID: "screenshot-fixture", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token),
                capabilities: [.evidenceRead])],
            handlers: [.init(operation: .screenshot) { context in
                let result = try await RetraceScreenshotCommands.read(context, service: service)
                await outputGate.beforeReturn()
                return result
            }])
    }

    override func tearDown() async throws {
        await outputGate?.release()
        await dispatcher?.close()
        await adapter?.shutdown()
        try await database?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testAllDefaultChunksReconstructExactNativePNGAndPixels() async throws {
        XCTAssertGreaterThan(expectedPNG.count, 700_000, "Noise must exercise multiple wire chunks")
        let expectedDigest = Self.digest(expectedPNG)
        var reconstructed = Data()
        var nextOffset: Int? = 0
        var chunkCount = 0
        while let offset = nextOffset {
            let response = try await read(offset: offset, digest: offset == 0 ? nil : expectedDigest)
            let chunk = try decode(response)
            XCTAssertEqual(chunk.reference, reference)
            XCTAssertEqual(chunk.mimeType, "image/png")
            XCTAssertEqual(chunk.sha256, expectedDigest)
            XCTAssertEqual(chunk.totalBytes, expectedPNG.count)
            XCTAssertEqual(chunk.offset, reconstructed.count)
            XCTAssertEqual(chunk.length, min(512_000, expectedPNG.count - offset))
            let bytes = try XCTUnwrap(Data(base64Encoded: chunk.base64))
            XCTAssertEqual(bytes.count, chunk.length)
            reconstructed.append(bytes)
            nextOffset = chunk.nextOffset
            if let nextOffset { XCTAssertEqual(nextOffset, reconstructed.count) }
            chunkCount += 1
            guard chunkCount <= 8 else { return XCTFail("Chunk continuation did not terminate") }
        }
        XCTAssertGreaterThan(chunkCount, 1)
        XCTAssertEqual(reconstructed, expectedPNG, "Chunks preserve every native PNG byte in order")
        XCTAssertEqual(Self.digest(reconstructed), expectedDigest)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(reconstructed as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, image.width)
        XCTAssertEqual(decoded.height, image.height)
        XCTAssertEqual(try Self.rgba(decoded), try Self.rgba(image), "PNG round-trip retains authored pixels")
        let reads = await imageReads.frames
        XCTAssertEqual(reads, Array(repeating: reference.frameID, count: chunkCount))
    }

    func testWrongDigestConflictsAndOffsetAtEndReturnsNoBytes() async throws {
        let first = try decode(await read())
        let wrongDigest = String(repeating: first.sha256.first == "0" ? "1" : "0", count: 64)
        let conflict = try await read(offset: try XCTUnwrap(first.nextOffset), digest: wrongDigest)
        XCTAssertEqual(conflict.status, .conflict)
        XCTAssertEqual(conflict.code, "revision_conflict")
        XCTAssertNil(conflict.data)

        let end = try await read(offset: first.totalBytes, digest: first.sha256)
        XCTAssertEqual(end.status, .failed)
        XCTAssertEqual(end.code, "invalid_arguments")
        XCTAssertNil(end.data)
    }

    func testPrivacyAndHiddenStateAreRecheckedBetweenChunks() async throws {
        let first = try decode(await read())
        let next = try XCTUnwrap(first.nextOffset)
        await policy.setExcluded(true)
        let excluded = try await read(offset: next, digest: first.sha256)
        XCTAssertEqual(excluded.status, .denied)
        XCTAssertNil(excluded.data)
        let deniedReads = await imageReads.frames.count
        XCTAssertEqual(deniedReads, 1, "A denied continuation must not decode the screenshot")

        await policy.setExcluded(false)
        let permittedAgain = try await read(offset: next, digest: first.sha256)
        XCTAssertEqual(permittedAgain.status, .succeeded)
        let hiddenValue = try await database.getTag(name: "hidden")
        let hidden = try XCTUnwrap(hiddenValue)
        try await database.addTagToSegment(segmentId: .init(value: segmentID), tagId: hidden.id)
        let hiddenResponse = try await read(offset: next, digest: first.sha256)
        XCTAssertEqual(hiddenResponse.status, .denied)
        XCTAssertNil(hiddenResponse.data)
        let hiddenReads = await imageReads.frames.count
        XCTAssertEqual(hiddenReads, 2)
    }

    func testRevokingGrantDiscardsAnAlreadyEncodedChunk() async throws {
        let first = try decode(await read())
        let reached = expectation(description: "Continuation encoded before dispatcher return")
        await outputGate.holdNext { reached.fulfill() }
        let request = try request(offset: try XCTUnwrap(first.nextOffset), digest: first.sha256)
        let dispatcher = try XCTUnwrap(dispatcher)
        let token = token
        let pending = Task { await dispatcher.execute(request, bearerToken: token) }
        await fulfillment(of: [reached], timeout: 10)
        try await dispatcher.replaceGrants([])
        await outputGate.release()
        let result = await pending.value
        XCTAssertEqual(result.status, .denied)
        XCTAssertEqual(result.code, "grant_revoked")
        XCTAssertNil(result.data, "Even encoded image bytes cannot escape a revoked command scope")
        let later = await dispatcher.execute(request, bearerToken: token)
        XCTAssertEqual(later.status, .denied)
        XCTAssertNil(later.data)
    }

    func testMalformedOffsetsLengthsAndDigestsAreRejectedBeforeImageRead() async throws {
        let digest = Self.digest(expectedPNG)
        let invalid: [[String: RetraceJSON]] = [
            ["offset": .integer(-1)],
            ["offset": .integer(32 * 1024 * 1024), "sha256": .string(digest)],
            ["offset": .integer(Int64.max), "sha256": .string(digest)],
            ["offset": .integer(1)],
            ["offset": .number(0.5)],
            ["offset": .string("512000")],
            ["length": .integer(0)],
            ["length": .integer(-1)],
            ["length": .integer(512_001)],
            ["sha256": .string("short")],
            ["sha256": .string(String(repeating: "G", count: 64))]
        ]
        for fields in invalid {
            var arguments = fields
            arguments["reference"] = try .encode(reference)
            let result = await dispatcher.execute(.init(requestID: UUID(), operation: .screenshot,
                arguments: .object(arguments)), bearerToken: token)
            XCTAssertEqual(result.status, .failed)
            XCTAssertEqual(result.code, "invalid_arguments")
            XCTAssertNil(result.data)
        }
        let reads = await imageReads.frames
        XCTAssertTrue(reads.isEmpty)
    }

    func testContinuationCannotSubstituteSourceIdentityOrReadDeletedFrame() async throws {
        let first = try decode(await read())
        let next = try XCTUnwrap(first.nextOffset)
        let ref = try XCTUnwrap(reference)
        let wrongReferences = [
            ScreenEvidenceRef(storeID: UUID(), source: ref.source, observationID: ref.observationID,
                frameID: ref.frameID, extractionRevision: ref.extractionRevision),
            ScreenEvidenceRef(storeID: ref.storeID, source: ref.source, observationID: UUID(),
                frameID: ref.frameID, extractionRevision: ref.extractionRevision),
            ScreenEvidenceRef(storeID: ref.storeID, source: .rewind, observationID: ref.observationID,
                frameID: ref.frameID, extractionRevision: ref.extractionRevision)
        ]
        for wrong in wrongReferences {
            let result = try await read(offset: next, digest: first.sha256, reference: wrong)
            XCTAssertEqual(result.status, .denied)
            XCTAssertNil(result.data)
        }
        try await database.deleteFrame(id: ref.frameID)
        let deleted = try await read(offset: next, digest: first.sha256)
        XCTAssertNotEqual(deleted.status, .succeeded)
        XCTAssertNil(deleted.data)
        let reads = await imageReads.frames.count
        XCTAssertEqual(reads, 1)
    }

    private func request(offset: Int? = nil, digest: String? = nil,
                         reference: ScreenEvidenceRef? = nil) throws -> RetraceCommandRequest {
        var arguments: [String: RetraceJSON] = ["reference": try .encode(reference ?? self.reference!)]
        if let offset { arguments["offset"] = .integer(Int64(offset)) }
        if let digest { arguments["sha256"] = .string(digest) }
        return .init(requestID: UUID(), operation: .screenshot, arguments: .object(arguments))
    }

    private func read(offset: Int? = nil, digest: String? = nil,
                      reference: ScreenEvidenceRef? = nil) async throws -> RetraceCommandResponse {
        await dispatcher.execute(try request(offset: offset, digest: digest, reference: reference), bearerToken: token)
    }

    private func decode(_ response: RetraceCommandResponse) throws -> ScreenshotChunk {
        XCTAssertEqual(response.status, .succeeded, response.code ?? "No error code")
        return try XCTUnwrap(response.data).decode(ScreenshotChunk.self)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func authoredImage(width: Int, height: Int) throws -> CGImage {
        var state: UInt32 = 0x6d2b79f5
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for pixel in 0..<(width * height) {
            for channel in 0..<3 {
                state ^= state << 13; state ^= state >> 17; state ^= state << 5
                pixels[pixel * 4 + channel] = UInt8(truncatingIfNeeded: state)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private static func png(_ image: CGImage) throws -> Data {
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw EvidenceUnavailableReason.integrityFailure }
        return bytes as Data
    }

    private static func rgba(_ image: CGImage) throws -> Data {
        let count = image.width * image.height * 4
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: count)
    }
}

private struct ScreenshotChunk: Decodable {
    let reference: ScreenEvidenceRef
    let mimeType: String
    let sha256: String
    let totalBytes: Int
    let offset: Int
    let length: Int
    let nextOffset: Int?
    let base64: String
}

private actor ScreenshotCommandPolicy {
    private var excluded = false
    private var revision = UUID()
    func config() -> CaptureConfig { .init(excludedAppBundleIDs: excluded ? ["com.fixture.screenshot"] : []) }
    func state() -> NativeCaptureState { .init(config: config(), revision: revision) }
    func setExcluded(_ value: Bool) { excluded = value; revision = UUID() }
}

private actor ScreenshotCommandImageReads {
    private(set) var frames: [FrameID] = []
    func record(_ frame: FrameID) { frames.append(frame) }
}

private actor ScreenshotCommandOutputGate {
    private var reached: (@Sendable () -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func holdNext(_ reached: @escaping @Sendable () -> Void) { self.reached = reached; released = false }
    func beforeReturn() async {
        guard let reached else { return }
        self.reached = nil
        reached()
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume(); continuation = nil
    }
}
