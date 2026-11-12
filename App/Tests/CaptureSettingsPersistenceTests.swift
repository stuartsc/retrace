import Foundation
import Shared
import XCTest
@testable import App

final class CaptureSettingsPersistenceTests: XCTestCase {
    func testAcceptedSettingsReopenAndKeepExistingApplicationLabels() throws {
        let name = "test.retrace.capture-settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("[{\"bundleID\":\"test.authored\",\"name\":\"Authored app\",\"iconPath\":null}]", forKey: "excludedApps")
        let store = CaptureSettingsPersistence(defaults: defaults)
        let config = CaptureConfig(captureIntervalSeconds: 10, adaptiveCaptureEnabled: false,
            deduplicationThreshold: 0.995, excludedAppBundleIDs: ["com.apple.loginwindow", "test.authored"],
            redactWindowTitlePatterns: ["Authored secret"], redactBrowserURLPatterns: ["private.example"],
            captureOnWindowChange: false)
        try store.save(config)
        let reopened = try XCTUnwrap(CaptureSettingsPersistence(defaults: defaults).load())
        XCTAssertEqual(reopened.captureIntervalSeconds, 10)
        XCTAssertFalse(reopened.adaptiveCaptureEnabled)
        XCTAssertEqual(reopened.excludedAppBundleIDs, config.excludedAppBundleIDs)
        XCTAssertEqual(reopened.redactWindowTitlePatterns, ["Authored secret"])
        XCTAssertEqual(reopened.redactBrowserURLPatterns, ["private.example"])
        XCTAssertFalse(reopened.captureOnWindowChange)
        XCTAssertEqual(defaults.double(forKey: "captureIntervalSeconds"), 10)
        XCTAssertTrue(try XCTUnwrap(defaults.string(forKey: "excludedApps")).contains("Authored app"))
        let prior = defaults.data(forKey: CaptureSettingsPersistence.key)
        XCTAssertThrowsError(try store.save(CaptureConfig(captureIntervalSeconds: .infinity)))
        XCTAssertEqual(defaults.data(forKey: CaptureSettingsPersistence.key), prior)
    }
}
