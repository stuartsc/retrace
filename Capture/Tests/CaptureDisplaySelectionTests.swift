import CoreGraphics
import XCTest
@testable import Capture

final class CaptureDisplaySelectionTests: XCTestCase {
    func testSelectionSkipsTransparentDegenerateAndOtherProcessWindows() throws {
        let visible = window(id: 24, bounds: CGRect(x: 1800, y: 100, width: 800, height: 600))
        let windows = [window(id: 20, alpha: 0), window(id: 21, width: 1),
                       window(id: 22, pid: 99), window(id: 23, layer: 3), visible]
        let selected = try XCTUnwrap(CapturedWindowGeometry.firstWindow(processID: 42, in: windows))
        XCTAssertEqual(selected.index, 4)
        XCTAssertEqual(selected.windowID, 24)
        XCTAssertEqual(selected.bounds, CGRect(x: 1800, y: 100, width: 800, height: 600))
        XCTAssertNil(CapturedWindowGeometry.firstWindow(processID: 42, in: Array(windows.dropLast())))
    }

    func testLargestOverlapUsesTheSameDisplayForOffsetAndStraddlingWindows() {
        // Its centre is on the narrow upper display, but most visible pixels
        // belong to the lower display. Both capture and attribution use area.
        let displays: [(id: UInt32, bounds: CGRect)] = [
            (7, CGRect(x: 0, y: 0, width: 1800, height: 900)),
            (8, CGRect(x: 900, y: 900, width: 1600, height: 1200))
        ]
        let bounds = CGRect(x: 0, y: 500, width: 1800, height: 900)
        XCTAssertTrue(displays[1].bounds.contains(CGPoint(x: bounds.midX, y: bounds.midY)))
        XCTAssertEqual(CapturedWindowGeometry.displayID(for: bounds, displays: displays), 7)
        XCTAssertEqual(CapturedWindowGeometry.displayID(for: bounds, displays: Array(displays.reversed())), 7)
        XCTAssertNil(CapturedWindowGeometry.displayID(for: CGRect(x: -400, y: -400, width: 20, height: 20), displays: displays))
    }

    func testTiesAndMalformedGeometryCannotDependOnEnumerationOrder() {
        let bounds = CGRect(x: 50, y: 0, width: 100, height: 100)
        let displays: [(id: UInt32, bounds: CGRect)] = [
            (9, CGRect(x: 0, y: 0, width: 100, height: 100)),
            (7, CGRect(x: 100, y: 0, width: 100, height: 100))
        ]
        XCTAssertEqual(CapturedWindowGeometry.displayID(for: bounds, displays: displays), 7)
        XCTAssertEqual(CapturedWindowGeometry.displayID(for: bounds, displays: Array(displays.reversed())), 7)
        for invalid in [CGRect.null, CGRect.infinite, CGRect.zero] {
            XCTAssertNil(CapturedWindowGeometry.displayID(for: invalid, displays: displays))
        }
    }

    func testDisplaySelectionUsesVisibleWindowWithoutDependingOnAXAvailability() async throws {
        let bounds = CGRect(x: 1800, y: 50, width: 800, height: 600)
        let displays: [(id: UInt32, bounds: CGRect)] = [
            (7, CGRect(x: 0, y: 0, width: 1700, height: 1000)),
            (8, CGRect(x: 1700, y: 0, width: 1700, height: 1000))
        ]
        for permission in [false, true] {
            let monitor = DisplayMonitor(environment: .init(
                frontmostWindowBounds: { bounds },
                displayForBounds: { CapturedWindowGeometry.displayID(for: $0, displays: displays) },
                mainDisplayID: { 7 }, accessibilityPermission: { permission }))
            let result = await monitor.getActiveDisplayIDWithPermissionStatus()
            XCTAssertEqual(result.0, 8, "Unavailable AX must not move capture back to the main screen")
            XCTAssertEqual(result.1, permission, "CG selection must not manufacture Accessibility permission")
        }
    }

    private func window(id: UInt32, pid: Int32 = 42, layer: Int = 0, alpha: Double = 1,
                        width: Double = 800, bounds: CGRect? = nil) -> [String: Any] {
        // Exercise native CoreGraphics dictionary/geometry decoding at the
        // replaceable WindowServer boundary, not a preselected context object.
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
         kCGWindowLayer as String: layer, kCGWindowAlpha as String: alpha,
         kCGWindowIsOnscreen as String: true,
         kCGWindowBounds as String: (bounds ?? CGRect(x: 0, y: 0, width: width, height: 600)).dictionaryRepresentation]
    }
}
