import Foundation
import XCTest
@testable import Retrace

final class AppResourceBundleTests: XCTestCase {
    func testPackagedAppLoadsNestedResourcesWithoutEvaluatingSwiftPMFallback() throws {
        let app = try makeAppBundle()
        let nestedURL = try XCTUnwrap(app.resourceURL).appendingPathComponent("Retrace_Retrace.bundle")
        let nested = try makeResourceBundle(at: nestedURL, marker: "packaged resource")
        var fallbackCalls = 0

        let resolved = AppResourceBundle.resolve(appBundle: app) {
            fallbackCalls += 1
            return app
        }

        XCTAssertEqual(resolved.bundleURL.standardizedFileURL.path, nested.bundleURL.standardizedFileURL.path)
        XCTAssertEqual(try marker(in: resolved), "packaged resource")
        XCTAssertEqual(fallbackCalls, 0, "Bundle.module may fatalError when the build directory is absent; packaged apps must never evaluate it")
    }

    func testDirectSwiftPMRunUsesFallbackWhenNestedBundleIsAbsent() throws {
        let app = try makeAppBundle()
        let fallbackURL = app.bundleURL.deletingLastPathComponent().appendingPathComponent("SwiftPM.bundle")
        let fallback = try makeResourceBundle(at: fallbackURL, marker: "direct SwiftPM resource")
        var fallbackCalls = 0

        let resolved = AppResourceBundle.resolve(appBundle: app) {
            fallbackCalls += 1
            return fallback
        }

        XCTAssertEqual(resolved.bundleURL.standardizedFileURL.path, fallback.bundleURL.standardizedFileURL.path)
        XCTAssertEqual(try marker(in: resolved), "direct SwiftPM resource")
        XCTAssertEqual(fallbackCalls, 1)
    }

    func testXcodeLayoutKeepsResourcesInMainAppBundle() throws {
        let app = try makeAppBundle()
        let resourceURL = try XCTUnwrap(app.resourceURL).appendingPathComponent("resource-marker.txt")
        try Data("Xcode resource".utf8).write(to: resourceURL)

        let resolved = AppResourceBundle.resolve(appBundle: app) { app }

        XCTAssertEqual(resolved.bundleURL.standardizedFileURL.path, app.bundleURL.standardizedFileURL.path)
        XCTAssertEqual(try marker(in: resolved), "Xcode resource")
    }

    func testRegularFileAtNestedBundlePathDoesNotOverrideFallback() throws {
        let app = try makeAppBundle()
        let nestedURL = try XCTUnwrap(app.resourceURL).appendingPathComponent("Retrace_Retrace.bundle")
        try Data("not a bundle".utf8).write(to: nestedURL)
        let fallbackURL = app.bundleURL.deletingLastPathComponent().appendingPathComponent("SwiftPM.bundle")
        let fallback = try makeResourceBundle(at: fallbackURL, marker: "fallback resource")

        let resolved = AppResourceBundle.resolve(appBundle: app) { fallback }

        XCTAssertEqual(try marker(in: resolved), "fallback resource")
    }

    private func makeAppBundle() throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppResourceBundleTests-\(UUID())")
        let appURL = root.appendingPathComponent("Retrace.app")
        let contents = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = [
            "CFBundleIdentifier": "io.retrace.resource-tests.\(UUID().uuidString)",
            "CFBundleName": "Retrace",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: appURL))
    }

    private func makeResourceBundle(at url: URL, marker: String) throws -> Bundle {
        // Match SwiftPM's flat generated bundle, including the absence of Info.plist.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: url.appendingPathComponent("resource-marker.txt"))
        return try XCTUnwrap(Bundle(url: url))
    }

    private func marker(in bundle: Bundle) throws -> String {
        let url = try XCTUnwrap(bundle.url(forResource: "resource-marker", withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8)
    }
}
