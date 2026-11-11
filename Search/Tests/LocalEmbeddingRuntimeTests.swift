import Foundation
import Shared
import XCTest
@testable import Search

final class LocalEmbeddingRuntimeTests: XCTestCase {
    func testNativeCanonicalPagePlansAndVectorsMatchThePinnedOfflineOracle() async throws {
        guard let path = ProcessInfo.processInfo.environment["RETRACE_MINILM_MODEL_PACKAGE"], !path.isEmpty else {
            throw XCTSkip("Native canonical-page parity requires an explicit pinned local package")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalEmbeddingPages-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = LocalEmbeddingRuntime(configuration: .init(modelPackageURL: URL(fileURLWithPath: path),
            tokenizerURL: try MiniLMFixture.url("tokenizer.json"), privateCacheParentURL: root), recordMetric: { _ in })
        let oracle = try MiniLMFixture.read(PageOracle.self, "canonical-page-oracle.json")
        do {
            _ = try await runtime.prepare()
            for page in oracle.pages {
                let actual = try await runtime.embed(page.text)
                XCTAssertEqual(actual.descriptor, .miniLM)
                XCTAssertEqual(actual.windows.count, page.windows.count)
                for (window, saved) in zip(actual.windows, page.windows) {
                    XCTAssertEqual(window.tokenStart, saved.tokenStart)
                    XCTAssertEqual(window.tokenEnd, saved.tokenEnd)
                    XCTAssertEqual(window.inputUTF16Range, saved.utf16Range)
                    let error = zip(window.vector, saved.vector).map { abs($0 - $1) }.max() ?? 1
                    XCTAssertLessThan(error, 0.0001)
                }
            }
            try await runtime.close()
        } catch { try? await runtime.close(); throw error }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testSharedAdapterRejectsMissingArtifactAndJoinsOwnedCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalEmbeddingAdapter-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime: any LocalEmbeddingRuntimeProtocol = LocalEmbeddingRuntime(configuration: .init(
            modelPackageURL: root.appendingPathComponent("missing.mlpackage"),
            tokenizerURL: try MiniLMFixture.url("tokenizer.json"), privateCacheParentURL: root), recordMetric: { _ in })
        do { _ = try await runtime.prepare(); XCTFail("Missing artifact accepted") }
        catch { XCTAssertEqual(error as? LocalEmbeddingError, .artifactUnavailable) }
        try await runtime.close()
        let status = await runtime.status()
        XCTAssertFalse(status.isPrepared)
        do { _ = try await runtime.embed("authored query"); XCTFail("Closed runtime accepted text") }
        catch { XCTAssertEqual(error as? LocalEmbeddingError, .closed) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private struct PageOracle: Decodable {
        let pages: [Page]
        struct Page: Decodable { let text: String; let windows: [Window] }
        struct Window: Decodable {
            let tokenStart: Int; let tokenEnd: Int; let utf16Range: EvidenceUTF16Range; let vector: [Float]
        }
    }
}
