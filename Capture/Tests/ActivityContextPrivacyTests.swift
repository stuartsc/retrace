import XCTest
import Shared
@testable import Capture

final class ActivityContextPrivacyTests: XCTestCase {
    func testURLSecretsAreRemovedBeforeAnyMetadataSink() {
        let inputs = [
            "https://alice:password@example.org/report?Token=secret#access_token=secret",
            "https://alice%3Apassword@example.org/report?%74%6Fken=secret&safe=opaque",
            "https://example.org/report?X-Amz-Signature=secret&X-Amz-Credential=secret",
            "https://example.org/report#eyJhbGciOiJIUzI1NiJ9.signature"
        ]
        for input in inputs {
            XCTAssertEqual(CapturedURLPolicy.sanitize(input), "https://example.org/report")
        }
        XCTAssertEqual(CapturedURLPolicy.sanitize("https://example.org/reset-password/opaque-secret-value"), "https://example.org/")
        XCTAssertEqual(CapturedURLPolicy.sanitize("https://example.org/%2574oken/secret"), "https://example.org/")
        XCTAssertNil(CapturedURLPolicy.sanitize("javascript:alert('secret')"))
        XCTAssertNil(CapturedURLPolicy.sanitize("data:text/plain,secret"))
    }

    func testOpaqueNavigationIdentityDoesNotCollapseAfterScrubbing() {
        let first = "https://example.org/report?document=first"
        let second = "https://example.org/report?document=second"
        XCTAssertEqual(CapturedURLPolicy.sanitize(first), CapturedURLPolicy.sanitize(second))
        XCTAssertNotEqual(CapturedURLPolicy.navigationIdentity(first), CapturedURLPolicy.navigationIdentity(second))
        XCTAssertFalse(CapturedURLPolicy.navigationIdentity(first).contains("document"))
    }

    func testOpaqueConversationURLUsesHostWhileOrdinaryDocumentPathsRemainUseful() {
        XCTAssertEqual(CapturedURLPolicy.sanitize("https://chatgpt.com/c/12345678-abcd-4567-abcd-123456789012?token=secret"),
                       "https://chatgpt.com/")
        XCTAssertEqual(CapturedURLPolicy.sanitize("file:///Users/example/Report.docx?token=secret"),
                       "file:///Users/example/Report.docx")
    }

    func testUnvalidatedOpaquePathsAreRemovedFromURLsAndLabelsWithoutMergingIdentity() {
        let paths = [
            "https://example.test/8a78e29d-7349-43d3-a7d8-064f0c97d94e",
            "https://example.test/s/a1b2c3d4e5f60718293a4b5c6d7e8f901",
            "https://example.test/%38a78e29d-7349-43d3-a7d8-064f0c97d94e",
            "https://example.test/s/%25611b2c3d4e5f60718293a4b5c6d7e8f901"
        ]
        for path in paths {
            XCTAssertEqual(CapturedURLPolicy.sanitize(path), "https://example.test/")
            let label = CapturedURLPolicy.sanitizeLabel("Captured tab: \(path)")
            XCTAssertEqual(label, "Captured tab: https://example.test/")
        }
        XCTAssertNotEqual(CapturedURLPolicy.navigationIdentity(paths[0]), CapturedURLPolicy.navigationIdentity(paths[1]),
                          "Scrubbing a URL cannot merge separately observed documents")
        XCTAssertFalse(CapturedURLPolicy.navigationIdentity(paths[0]).contains("8a78e29d"))
    }
}
