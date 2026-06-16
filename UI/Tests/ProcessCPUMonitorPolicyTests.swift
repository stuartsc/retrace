import XCTest
@testable import Retrace

final class ProcessCPUMonitorPolicyTests: XCTestCase {
    func testProcessCPUMonitorDoesNotStartAtLaunchByDefault() {
        XCTAssertFalse(ProcessCPUMonitor.shouldStartAtLaunch(
            defaultsValue: nil,
            environmentValue: nil
        ))
    }

    func testProcessCPUMonitorCanStartAtLaunchForDiagnostics() {
        XCTAssertTrue(ProcessCPUMonitor.shouldStartAtLaunch(
            defaultsValue: nil,
            environmentValue: "true"
        ))
    }

    func testProcessCPUMonitorEnvironmentOverridesDefaults() {
        XCTAssertFalse(ProcessCPUMonitor.shouldStartAtLaunch(
            defaultsValue: true,
            environmentValue: "0"
        ))
    }
}
