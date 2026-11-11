import Foundation
import XCTest
@testable import Search

final class MiniLMEmbeddingRuntimeTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MiniLMTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return root
    }

    private func modelURL() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["RETRACE_MINILM_MODEL_PACKAGE"], !path.isEmpty else {
            throw XCTSkip("Native parity requires an explicitly supplied pinned local .mlpackage")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func makeRuntime(_ root: URL, model: URL, tokenizer: URL? = nil,
                             metrics: MiniLMTestMetrics = MiniLMTestMetrics()) throws -> MiniLMEmbeddingRuntime {
        MiniLMEmbeddingRuntime(configuration: .init(modelPackageURL: model,
            tokenizerURL: try tokenizer ?? MiniLMFixture.url("tokenizer.json"), privateCacheParentURL: root),
            recordMetric: { metrics.append($0) })
    }

    func testMissingArtifactCannotCreateReadyRuntimeAndLeavesNoOwnedFiles() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try makeRuntime(root, model: root.appendingPathComponent("missing.mlpackage"))
        do { try await runtime.prepare(); XCTFail("Expected absent artifact rejection") }
        catch let error as MiniLMRuntimeError { XCTAssertEqual(error, .artifactUnavailable) }
        let status = await runtime.status()
        XCTAssertFalse(status.isPrepared)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        try await runtime.close()
    }

    func testCorruptAndOversizedTokenizerFailBeforeAnyModelLoad() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source-tokenizer.json")
        var data = try MiniLMFixture.data("tokenizer.json")
        data[data.count / 2] ^= 1
        for invalid in [data, data + Data([0])] {
            try invalid.write(to: source)
            let runtime = try makeRuntime(root, model: root.appendingPathComponent("missing.mlpackage"), tokenizer: source)
            do { try await runtime.prepare(); XCTFail("Expected tokenizer integrity failure") }
            catch let error as MiniLMRuntimeError { XCTAssertEqual(error, .artifactInvalid) }
            try await runtime.close()
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source-tokenizer.json"])
        }
    }

    func testTokenizerSymlinkIsRejectedWithoutReadingItsTarget() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("linked-tokenizer.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: MiniLMFixture.url("tokenizer.json"))
        let runtime = try makeRuntime(root, model: root.appendingPathComponent("missing.mlpackage"), tokenizer: link)
        do { try await runtime.prepare(); XCTFail("Expected symlink rejection") }
        catch let error as MiniLMRuntimeError { XCTAssertEqual(error, .artifactInvalid) }
        try await runtime.close()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["linked-tokenizer.json"])
    }

    func testCancelledPreparationHasNoPublishedModelOrResidualPrivateCopy() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try makeRuntime(root, model: root.appendingPathComponent("missing.mlpackage"))
        let gate = MiniLMTestGate()
        let task = Task { await gate.wait(); try await runtime.prepare() }
        task.cancel(); await gate.release()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        let status = await runtime.status()
        XCTAssertFalse(status.isPrepared)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        try await runtime.close()
    }

    func testWholeOversizedInputAndEmptyQuestionAreRejectedBeforeModelPreparation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try makeRuntime(root, model: root.appendingPathComponent("missing.mlpackage"))
        do { _ = try await runtime.embed(String(repeating: "a", count: 32_769)); XCTFail("Expected bound") }
        catch let error as MiniLMRuntimeError { XCTAssertEqual(error, .inputTooLarge) }
        do { _ = try await runtime.embed(" \n\t"); XCTFail("Expected empty input") }
        catch let error as MiniLMRuntimeError { XCTAssertEqual(error, .emptyInput) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        try await runtime.close()
    }

    func testNativeVectorsAndAllSavedRankingsAgreeAcrossThreeWarmRuns() async throws {
        let model = try modelURL()
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try makeRuntime(root, model: model)
        let oracle = try MiniLMFixture.read(EmbeddingOracle.self, "embedding-oracle.json")
        XCTAssertEqual(oracle.transformSHA256, MiniLMModelPin.transformSHA256)
        do {
            try await runtime.prepare()
            for repetition in 0..<3 {
                var actual: [String: [[Float]]] = [:]
                for item in oracle.cases {
                    let results = try await runtime.embed(item.text)
                    XCTAssertEqual(results.count, item.windows.count, item.id)
                    for (value, expected) in zip(results, item.windows) {
                        XCTAssertEqual(value.tokenStart, expected.tokenStart, item.id)
                        XCTAssertEqual(value.tokenEnd, expected.tokenEnd, item.id)
                        XCTAssertEqual(value.utf16Location, expected.utf16Range.location, item.id)
                        XCTAssertEqual(value.utf16Length, expected.utf16Range.length, item.id)
                        XCTAssertEqual(value.vector.count, 384)
                        XCTAssertTrue(value.vector.allSatisfy(\.isFinite))
                        let norm = sqrt(value.vector.reduce(0.0) { $0 + Double($1) * Double($1) })
                        XCTAssertEqual(norm, 1.0, accuracy: 0.00001)
                        let componentError = zip(value.vector, expected.vector).map { abs($0 - $1) }.max() ?? 1
                        XCTAssertLessThan(componentError, 0.0001, "\(item.id) run \(repetition)")
                        let cosine = zip(value.vector, expected.vector).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
                        XCTAssertGreaterThan(cosine, 0.99999)
                    }
                    actual[item.id] = results.map(\.vector)
                }
                let screenIDs = oracle.cases.filter { $0.kind == "screen" }.map(\.id)
                for (question, expected) in oracle.rankings {
                    let ranked = screenIDs.sorted { left, right in
                        func score(_ id: String) -> Double {
                            actual[question]!.flatMap { query in actual[id]!.map { screen in
                                zip(query, screen).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
                            }}.max()!
                        }
                        let lhs = score(left), rhs = score(right)
                        return lhs == rhs ? left < right : lhs > rhs
                    }
                    XCTAssertEqual(ranked, expected, "\(question) run \(repetition)")
                }
            }
        } catch { try? await runtime.close(); throw error }
        try await runtime.close()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testModelActuallyLoadedIsIndependentOfMutableSuppliedPaths() async throws {
        let suppliedModel = try modelURL()
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try directory(); defer { try? FileManager.default.removeItem(at: source) }
        let model = source.appendingPathComponent("model.mlpackage", isDirectory: true)
        let tokenizer = source.appendingPathComponent("tokenizer.json")
        try FileManager.default.copyItem(at: suppliedModel, to: model)
        try MiniLMFixture.data("tokenizer.json").write(to: tokenizer)
        let runtime = try makeRuntime(root, model: model, tokenizer: tokenizer)
        do {
            try await runtime.prepare()
            let before = try await runtime.embed("Cedar proposal status SENT, approval NOT GRANTED")
            try FileManager.default.removeItem(at: model)
            try Data("changed after verification".utf8).write(to: tokenizer)
            let after = try await runtime.embed("Cedar proposal status SENT, approval NOT GRANTED")
            XCTAssertEqual(before.map(\.vector), after.map(\.vector))
        } catch { try? await runtime.close(); throw error }
        try await runtime.close()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testChangedModelByteAndUnexpectedInventoryCannotLoad() async throws {
        let suppliedModel = try modelURL()
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try directory(); defer { try? FileManager.default.removeItem(at: source) }
        let model = source.appendingPathComponent("model.mlpackage", isDirectory: true)
        try FileManager.default.copyItem(at: suppliedModel, to: model)
        let weights = model.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        let handle = try FileHandle(forUpdating: weights)
        try handle.seek(toOffset: 17)
        let byte = try XCTUnwrap(handle.read(upToCount: 1)?.first)
        try handle.seek(toOffset: 17); try handle.write(contentsOf: Data([byte ^ 1])); try handle.close()
        let runtime = try makeRuntime(root, model: model)
        do { try await runtime.prepare(); XCTFail("Expected model hash rejection") }
        catch let error as MiniLMRuntimeError { XCTAssertEqual(error, .artifactInvalid) }
        try await runtime.close()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let restore = try FileHandle(forUpdating: weights)
        try restore.seek(toOffset: 17); try restore.write(contentsOf: Data([byte])); try restore.close()
        try Data([1]).write(to: model.appendingPathComponent("unlisted.bin"))
        let extra = try makeRuntime(root, model: model)
        do { try await extra.prepare(); XCTFail("Expected extra-file rejection") }
        catch let error as MiniLMRuntimeError { XCTAssertEqual(error, .artifactInvalid) }
        try await extra.close()
    }

    func testCancellationBetweenNativeWindowsReturnsNoPartialResultAndRemainsUsable() async throws {
        let model = try modelURL()
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let metrics = MiniLMTestMetrics()
        let runtime = try makeRuntime(root, model: model, metrics: metrics)
        try await runtime.prepare()
        let text = String(repeating: "The authored proposal budget is 42000. Approval remains pending.\n", count: 400)
        let task = Task { try await runtime.embed(text) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while await runtime.status().completedWindowCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation between windows") }
        catch is CancellationError { }
        let status = await runtime.status()
        XCTAssertGreaterThan(status.completedWindowCount, 0)
        XCTAssertLessThan(status.completedWindowCount, status.totalWindowCount)
        XCTAssertFalse(status.isEmbedding)
        let next = try await runtime.embed("Cedar proposal approval NOT GRANTED")
        XCTAssertEqual(next.count, 1)
        let recorded = metrics.values
        XCTAssertTrue(recorded.contains { $0.operation == .embedding && $0.outcome == .cancelled })
        try await runtime.close()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testWindowLimitNeverSilentlyDropsQuestionSuffix() async throws {
        let model = try modelURL()
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try makeRuntime(root, model: model)
        do { _ = try await runtime.embed(String(repeating: ". ", count: 9_000) + "NOT GRANTED"); XCTFail("Expected window bound") }
        catch let error as MiniLMRuntimeError { XCTAssertEqual(error, .inputTooLarge) }
        try await runtime.close()
    }

    func testConcurrentRequestIsBoundedAndCloseRevokesInFlightWindows() async throws {
        let model = try modelURL()
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let metrics = MiniLMTestMetrics()
        let runtime = try makeRuntime(root, model: model, metrics: metrics)
        try await runtime.prepare()
        let text = String(repeating: "The authored proposal budget is 42000. Approval remains pending.\n", count: 400)
        let task = Task { try await runtime.embed(text) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while await runtime.status().completedWindowCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        do { _ = try await runtime.embed("A concurrent authored request"); XCTFail("Expected bounded busy rejection") }
        catch let error as MiniLMRuntimeError { XCTAssertEqual(error, .busy) }
        let closing = Task { try await runtime.close() }
        closing.cancel()
        async let repeated: Void = runtime.close()
        try await closing.value
        let immediateStatus = await runtime.status()
        XCTAssertFalse(immediateStatus.isEmbedding, "Close must join the active operation")
        let countAtClose = metrics.values.count
        do { _ = try await task.value; XCTFail("Close must revoke unfinished windows") }
        catch let error as MiniLMRuntimeError { XCTAssertEqual(error, .closed) }
        try await repeated
        XCTAssertEqual(metrics.values.count, countAtClose, "No active-operation or duplicate close metric after joined close")
        let events = metrics.values
        let operationEnd = try XCTUnwrap(events.lastIndex { $0.operation == .embedding })
        let cleanupEnd = try XCTUnwrap(events.lastIndex { $0.operation == .cleanup })
        XCTAssertLessThan(operationEnd, cleanupEnd, "The metric owner may drain immediately after close returns")
        let status = await runtime.status()
        XCTAssertFalse(status.isPrepared)
        XCTAssertFalse(status.isEmbedding)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testCloseIsTerminalAndPreservesUnrelatedCacheFiles() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let keep = root.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: keep)
        let metrics = MiniLMTestMetrics()
        let runtime = try makeRuntime(root, model: root.appendingPathComponent("missing.mlpackage"), metrics: metrics)
        try await runtime.close(); try await runtime.close()
        let eventsAtClose = metrics.values.count
        do { _ = try await runtime.embed("authored"); XCTFail("Expected closed runtime") }
        catch let error as MiniLMRuntimeError { XCTAssertEqual(error, .closed) }
        do { try await runtime.prepare(); XCTFail("Expected closed runtime") }
        catch let error as MiniLMRuntimeError { XCTAssertEqual(error, .closed) }
        XCTAssertEqual(metrics.values.count, eventsAtClose, "Post-close calls must not write after the owner drains metrics")
        XCTAssertEqual(try Data(contentsOf: keep), Data("keep".utf8))
    }

    func testValidModelRootSymlinkIsRejectedBeforeNativeLoad() async throws {
        let model = try modelURL()
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try directory(); defer { try? FileManager.default.removeItem(at: source) }
        let link = source.appendingPathComponent("model.mlpackage")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: model)
        let runtime = try makeRuntime(root, model: link)
        do { try await runtime.prepare(); XCTFail("Expected model-root symlink rejection") }
        catch let error as MiniLMRuntimeError { XCTAssertEqual(error, .artifactInvalid) }
        try await runtime.close()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testSharedWritableCacheParentIsRejected() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
        let runtime = try makeRuntime(root, model: root.appendingPathComponent("missing.mlpackage"))
        do { try await runtime.prepare(); XCTFail("Expected private-parent rejection") }
        catch let error as MiniLMRuntimeError { XCTAssertEqual(error, .artifactInvalid) }
        try await runtime.close()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}

struct EmbeddingOracle: Decodable {
    struct Window: Decodable {
        let tokenStart: Int; let tokenEnd: Int; let utf16Range: Span; let vector: [Float]
    }
    struct Item: Decodable { let id: String; let kind: String; let text: String; let windows: [Window] }
    let transformSHA256: String; let cases: [Item]; let rankings: [String: [String]]
}

final class MiniLMTestMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MiniLMRuntimeMetric] = []
    var values: [MiniLMRuntimeMetric] { lock.withLock { storage } }
    func append(_ value: MiniLMRuntimeMetric) { lock.withLock { storage.append(value) } }
}
