import XCTest

// Eager arguments let async SQLite operations finish before XCTest evaluates assertions.
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual, expected, file: file, line: line)
}
func expectNotEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNotEqual(actual, expected, file: file, line: line)
}
func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNil(value, file: file, line: line) }
func expectNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNotNil(value, file: file, line: line) }
func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(value, file: file, line: line) }
func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(value, file: file, line: line) }
func expectGreaterThan<T: Comparable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertGreaterThan(actual, expected, file: file, line: line)
}
func requireValue<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
