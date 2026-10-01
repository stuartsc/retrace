import Foundation
import XCTest
import Shared
@testable import App

final class ResourceUsageMonitorTests: XCTestCase {
    func testCPUUsesMonotonicTimeAndOneCoreUnitsDespiteWallClockChange() {
        var series = ResourceUsageSeries()
        _ = series.append(reading(uptime: 10, cpu: 2, wall: 100))
        let result = series.append(reading(uptime: 12, cpu: 5, wall: -500))
        XCTAssertEqual(result.cpuPercent ?? -1, 150, accuracy: 0.001)
        XCTAssertEqual(result.oneMinute.cpuPercent ?? -1, 150, accuracy: 0.001)
        XCTAssertEqual(result.oneMinute.sampledSeconds, 2)
    }

    func testMissingCounterAndLongGapAreNotZeroCPUOrValidCoverage() {
        var series = ResourceUsageSeries()
        _ = series.append(reading(uptime: 0, cpu: 0))
        _ = series.append(reading(uptime: 1, cpu: 1))
        let missing = series.append(reading(uptime: 2, cpu: nil))
        XCTAssertNil(missing.cpuPercent)
        XCTAssertFalse(missing.isCurrent)
        _ = series.append(reading(uptime: 3, cpu: 2))
        let resumed = series.append(reading(uptime: 4, cpu: 3))
        XCTAssertEqual(resumed.oneMinute.cpuPercent ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(resumed.oneMinute.coverage, 0.5, accuracy: 0.001)
        let slept = series.append(reading(uptime: 120, cpu: 4))
        XCTAssertNil(slept.cpuPercent)
        XCTAssertEqual(slept.oneMinute.sampledSeconds, 0)
        XCTAssertEqual(slept.oneMinute.elapsedSeconds, 60)
    }

    func testCounterResetDoesNotCreateNegativeOrWrappedCPU() {
        var series = ResourceUsageSeries()
        _ = series.append(reading(uptime: 0, cpu: 10))
        XCTAssertNil(series.append(reading(uptime: 1, cpu: 1)).cpuPercent)
        XCTAssertEqual(series.append(reading(uptime: 2, cpu: 1.5)).cpuPercent ?? -1, 50, accuracy: 0.001)
    }

    func testMinuteSystemAggregateDoesNotSubstituteLastFiveSeconds() throws {
        var series = ResourceUsageSeries()
        var busy: UInt32 = 0, idle: UInt32 = 0
        for second in 0...60 {
            let amount: UInt32 = second > 55 ? 90 : 10
            if second > 0 { busy += amount; idle += 100 - amount }
            _ = series.append(.init(uptime: Double(second), date: Date(), cpuSeconds: Double(second) / 10,
                systemTicks: .init(user: busy, system: 0, idle: idle, nice: 0), physicalFootprintBytes: nil, logicalCoreCount: 10))
        }
        XCTAssertEqual(try XCTUnwrap(series.snapshot.systemFiveSecondCPUPercent), 90, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(series.systemMinuteAverage), 1000.0 / 60, accuracy: 0.001)
    }

    func testRollingAverageClipsBoundaryAndStorageIsBounded() {
        var series = ResourceUsageSeries()
        for second in 0...4000 {
            _ = series.append(reading(uptime: Double(second), cpu: Double(second) / 2))
        }
        let result = series.snapshot
        XCTAssertEqual(result.fifteenMinutes.sampledSeconds, 900)
        XCTAssertEqual(result.fifteenMinutes.cpuPercent ?? -1, 50, accuracy: 0.001)
        XCTAssertLessThanOrEqual(series.retainedSampleCount, 901)
    }

    func testNativeProbeReadsRealProcessAndSystemCounters() throws {
        let first = NativeResourceUsageProbe.read()
        let second = NativeResourceUsageProbe.read()
        XCTAssertGreaterThan(second.uptime, first.uptime)
        XCTAssertNotNil(first.cpuSeconds)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(second.cpuSeconds), try XCTUnwrap(first.cpuSeconds))
        XCTAssertNotNil(first.systemTicks)
        XCTAssertGreaterThan(try XCTUnwrap(first.physicalFootprintBytes), 0)
    }

    func testMonitorStartsExplicitlyAndCloseJoinsSampling() async throws {
        let monitor = ResourceUsageMonitor(interval: .milliseconds(20))
        let unused = await monitor.snapshot()
        XCTAssertNil(unused.observedAt)
        await monitor.start()
        try await Task.sleep(for: .milliseconds(100))
        let running = await monitor.snapshot()
        XCTAssertNotNil(running.observedAt)
        await monitor.close()
        let stopped = await monitor.snapshot()
        XCTAssertFalse(stopped.isCurrent)
        try await Task.sleep(for: .milliseconds(40))
        let later = await monitor.snapshot()
        XCTAssertEqual(stopped.observedAt, later.observedAt)
    }

    private func reading(uptime: Double, cpu: Double?, wall: Double = 100) -> ResourceUsageReading {
        .init(uptime: uptime, date: Date(timeIntervalSince1970: wall), cpuSeconds: cpu,
              systemTicks: .init(user: UInt32(max(0, uptime) * 40),
                                 system: UInt32(max(0, uptime) * 10),
                                 idle: UInt32(max(0, uptime) * 50), nice: 0),
              physicalFootprintBytes: 1024, logicalCoreCount: 10)
    }
}
