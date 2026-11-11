import Foundation
import XCTest
@testable import Search

final class MiniLMWordPieceTokenizerTests: XCTestCase {
    func testPinnedUpstreamIDsOffsetsAndCompleteBenchmarkWindows() throws {
        let oracle = try MiniLMFixture.read(TokenizerOracle.self, "tokenizer-oracle.json")
        let tokenizer = try MiniLMWordPieceTokenizer(data: MiniLMFixture.data("tokenizer.json"))
        XCTAssertEqual(oracle.cases.count, 45)
        for item in oracle.cases {
            let tokens = try tokenizer.tokenize(item.text)
            XCTAssertEqual(tokens.map(\.id), item.ids, item.id)
            XCTAssertEqual(tokens.map { Span(location: $0.utf16Location, length: $0.utf16Length) }, item.utf16Ranges, item.id)
            let windows = try tokenizer.windows(item.text)
            XCTAssertEqual(windows.count, item.windows.count, item.id)
            var covered = Set<Int>()
            for (actual, expected) in zip(windows, item.windows) {
                XCTAssertEqual(actual.tokenStart, expected.tokenStart, item.id)
                XCTAssertEqual(actual.tokenEnd, expected.tokenEnd, item.id)
                XCTAssertEqual(actual.content.map(\.id), expected.ids, item.id)
                XCTAssertEqual(actual.utf16Location, expected.utf16Range.location, item.id)
                XCTAssertEqual(actual.utf16Length, expected.utf16Range.length, item.id)
                XCTAssertEqual(actual.inputIDs.count, 256)
                XCTAssertEqual(actual.attentionMask.count, 256)
                XCTAssertEqual(actual.attentionMask.reduce(0, +), Int32(actual.content.count + 2))
                XCTAssertEqual(actual.inputIDs[actual.content.count + 1], 102)
                covered.formUnion(actual.tokenStart..<actual.tokenEnd)
            }
            XCTAssertEqual(covered, Set(tokens.indices), item.id)
        }
        XCTAssertEqual(oracle.transformSHA256, MiniLMModelPin.transformSHA256)
    }

    func testChangedTokenizerBytesCannotBeLoaded() throws {
        var data = try MiniLMFixture.data("tokenizer.json")
        data[data.count / 2] ^= 1
        XCTAssertThrowsError(try MiniLMWordPieceTokenizer(data: data))
        XCTAssertThrowsError(try MiniLMWordPieceTokenizer(data: Data()))
        XCTAssertThrowsError(try MiniLMWordPieceTokenizer(data: data + Data([0])))
    }

    func testUTF16LimitRejectsWholeInputWithoutTruncation() throws {
        let tokenizer = try MiniLMWordPieceTokenizer(data: MiniLMFixture.data("tokenizer.json"))
        XCTAssertNoThrow(try tokenizer.tokenize(String(repeating: " ", count: 32_768)))
        XCTAssertThrowsError(try tokenizer.tokenize(String(repeating: " ", count: 32_769)))
        XCTAssertThrowsError(try tokenizer.tokenize(String(repeating: "🚀", count: 16_385)))
    }

    func testCancelledTokenizationReturnsNoPartialTokens() async throws {
        let tokenizer = try MiniLMWordPieceTokenizer(data: MiniLMFixture.data("tokenizer.json"))
        let gate = MiniLMTestGate()
        let task = Task {
            await gate.wait()
            return try tokenizer.windows("An authored complete question whose answer is NOT GRANTED.")
        }
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }
}

struct Span: Codable, Equatable { let location: Int; let length: Int }
struct TokenizerOracle: Decodable {
    struct Window: Decodable {
        let tokenStart: Int; let tokenEnd: Int; let ids: [Int32]; let utf16Range: Span
    }
    struct Item: Decodable {
        let id: String; let text: String; let ids: [Int32]
        let utf16Ranges: [Span]; let windows: [Window]
    }
    let transformSHA256: String
    let cases: [Item]
}

enum MiniLMFixture {
    static func url(_ name: String) throws -> URL {
        guard let root = Bundle.module.url(forResource: "MiniLM", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root.appendingPathComponent(name)
    }
    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }
    static func read<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: data(name))
    }
}

actor MiniLMTestGate {
    private var open = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if open { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { open = true; continuation?.resume(); continuation = nil }
}
