import Foundation
import Darwin
import Shared

struct SystemCPUTicks: Sendable {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32

    func busyPercent(since old: Self) -> Double? {
        // Native counters are unsigned 32-bit ticks and may wrap during uptime.
        let busy = UInt64(user &- old.user) + UInt64(system &- old.system) + UInt64(nice &- old.nice)
        let total = busy + UInt64(idle &- old.idle)
        return total > 0 ? Double(busy) / Double(total) * 100 : nil
    }
}

struct ResourceUsageReading: Sendable {
    let uptime: Double
    let date: Date
    let cpuSeconds: Double?
    let systemTicks: SystemCPUTicks?
    let physicalFootprintBytes: UInt64?
    let logicalCoreCount: Int
}

enum NativeResourceUsageProbe {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static var uptime: Double {
        Double(mach_continuous_time()) * Double(timebase.numer) / Double(max(1, timebase.denom)) / 1e9
    }

    static func read() -> ResourceUsageReading {
        var usage = rusage()
        let hasCPU = getrusage(RUSAGE_SELF, &usage) == 0
        let seconds = Double(usage.ru_utime.tv_sec) + Double(usage.ru_stime.tv_sec)
            + (Double(usage.ru_utime.tv_usec) + Double(usage.ru_stime.tv_usec)) / 1e6
        var hostInfo = host_cpu_load_info_data_t()
        var hostCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        let hostResult = withUnsafeMutablePointer(to: &hostInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(hostCount)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &hostCount)
            }
        }
        mach_port_deallocate(mach_task_self_, host)
        let ticks: SystemCPUTicks? = hostResult == KERN_SUCCESS
            ? .init(user: hostInfo.cpu_ticks.0, system: hostInfo.cpu_ticks.1,
                    idle: hostInfo.cpu_ticks.2, nice: hostInfo.cpu_ticks.3) : nil
        var memory = task_vm_info_data_t()
        var memoryCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let memoryResult = withUnsafeMutablePointer(to: &memory) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(memoryCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &memoryCount)
            }
        }
        return .init(uptime: uptime, date: Date(), cpuSeconds: hasCPU ? seconds : nil,
                     systemTicks: ticks, physicalFootprintBytes: memoryResult == KERN_SUCCESS ? memory.phys_footprint : nil,
                     logicalCoreCount: ProcessInfo.processInfo.activeProcessorCount)
    }
}

/// Weighted windows retain unknown time in their denominator/coverage, not as
/// invented zero-CPU measurements. No process enumeration or filesystem access.
struct ResourceUsageSeries {
    private struct Interval {
        let start: Double
        let end: Double
        let cpu: Double?
        let system: Double?
    }
    private var previous: ResourceUsageReading?
    private var started: Double?
    private var intervals: [Interval] = []
    private(set) var snapshot = ResourceUsageSnapshot.unavailable
    var retainedSampleCount: Int { intervals.count }
    var systemMinuteAverage: Double? {
        previous.map { systemAverage(seconds: 60, now: $0.uptime) } ?? nil
    }

    @discardableResult mutating func append(_ reading: ResourceUsageReading) -> ResourceUsageSnapshot {
        if started == nil { started = reading.uptime }
        var cpu: Double?
        var system: Double?
        if let previous {
            let duration = reading.uptime - previous.uptime
            if duration > 0, duration <= 5 {
                if let current = reading.cpuSeconds, let old = previous.cpuSeconds,
                   current.isFinite, old.isFinite, current >= old {
                    cpu = (current - old) / duration * 100
                }
                if let current = reading.systemTicks, let old = previous.systemTicks {
                    system = current.busyPercent(since: old)
                }
            }
            if duration > 0 {
                intervals.append(.init(start: previous.uptime, end: reading.uptime, cpu: cpu, system: system))
            } else {
                // A replaced clock/probe starts a new series, never negative time.
                intervals.removeAll(keepingCapacity: true)
                started = reading.uptime
            }
        }
        previous = reading
        intervals.removeAll { $0.end <= reading.uptime - 900 }
        if intervals.count > 4096 { intervals.removeFirst(intervals.count - 4096) }
        let systemWindow = systemAverage(seconds: 5, now: reading.uptime)
        snapshot = .init(observedAt: reading.date, sampleUptime: reading.uptime, cpuPercent: cpu,
                         systemCPUPercent: system, systemFiveSecondCPUPercent: systemWindow,
                         physicalFootprintBytes: reading.physicalFootprintBytes, logicalCoreCount: reading.logicalCoreCount,
                         oneMinute: window(seconds: 60, now: reading.uptime),
                         fifteenMinutes: window(seconds: 900, now: reading.uptime),
                         isCurrent: cpu != nil && system != nil)
        return snapshot
    }

    private func window(seconds: Double, now: Double) -> ResourceUsageWindow {
        var duration = 0.0, weightedCPU = 0.0
        var peak: Double?
        for interval in intervals where interval.end > now - seconds {
            guard let cpu = interval.cpu else { continue }
            let part = interval.end - max(interval.start, now - seconds)
            duration += part
            weightedCPU += part * cpu
            peak = max(peak ?? cpu, cpu)
        }
        return .init(cpuPercent: duration > 0 ? weightedCPU / duration : nil, peakCPUPercent: peak,
                     sampledSeconds: duration, elapsedSeconds: min(seconds, max(0, now - (started ?? now))))
    }

    private func systemAverage(seconds: Double, now: Double) -> Double? {
        var duration = 0.0, weighted = 0.0
        for interval in intervals where interval.end > now - seconds {
            guard let system = interval.system else { continue }
            let part = interval.end - max(interval.start, now - seconds)
            duration += part
            weighted += part * system
        }
        // The overload gate needs a complete five-second observation, not one tick.
        return duration >= seconds - 0.001 ? weighted / duration : nil
    }
}

/// App-owned lightweight sampler. Explicit start/close owns and joins both
/// sampling and bounded metric delivery; opening a UI never starts another loop.
public actor ResourceUsageMonitor: ResourceUsageProviding {
    private let interval: Duration
    private var series = ResourceUsageSeries()
    private var sampler: Task<Void, Never>?
    private var delivery: Task<Void, Never>?
    private var events: AsyncStream<ResourceUsageMinute>.Continuation?
    private var lastMinuteUptime: Double?
    private var droppedMinutes = 0
    private var closing: Task<Void, Never>?
    private var lifecycleGeneration: UInt64 = 0

    public init(interval: Duration = .seconds(1)) { self.interval = interval }

    public func start(recordMinute: (@Sendable (ResourceUsageMinute) async -> Void)? = nil) async {
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        if let closing {
            await closing.value
            guard generation == lifecycleGeneration else { return }
            self.closing = nil
        }
        guard sampler == nil else { return }
        series = ResourceUsageSeries()
        lastMinuteUptime = nil
        droppedMinutes = 0
        if let recordMinute {
            let stream = AsyncStream<ResourceUsageMinute>.makeStream(bufferingPolicy: .bufferingNewest(60))
            events = stream.continuation
            delivery = Task { for await minute in stream.stream { await recordMinute(minute) } }
        }
        sampler = Task { [weak self, interval] in
            while !Task.isCancelled {
                await self?.collect()
                do { try await Task.sleep(for: interval, clock: .continuous) } catch { break }
            }
        }
    }

    public func snapshot() -> ResourceUsageSnapshot {
        var result = series.snapshot
        if sampler == nil || NativeResourceUsageProbe.uptime - (result.sampleUptime ?? -.infinity) > 3 {
            result.isCurrent = false
            result.cpuPercent = nil
            result.systemCPUPercent = nil
        }
        return result
    }

    private func collect() {
        guard !Task.isCancelled else { return }
        let reading = NativeResourceUsageProbe.read()
        let sample = series.append(reading)
        guard let lastMinuteUptime else {
            self.lastMinuteUptime = reading.uptime
            return
        }
        guard reading.uptime - lastMinuteUptime >= 60 else { return }
        self.lastMinuteUptime = reading.uptime
        let minute = ResourceUsageMinute(timestamp: reading.date, cpu: sample.oneMinute,
                                         systemCPUPercent: series.systemMinuteAverage,
                                         physicalFootprintBytes: sample.physicalFootprintBytes,
                                         droppedMinutes: droppedMinutes)
        if case .dropped = events?.yield(minute) { droppedMinutes += 1 } else { droppedMinutes = 0 }
    }

    public func close() async {
        lifecycleGeneration &+= 1
        if let closing { await closing.value; return }
        let sampling = sampler, metrics = delivery, continuation = events
        sampler = nil
        delivery = nil
        events = nil
        sampling?.cancel()
        let close = Task {
            await sampling?.value
            continuation?.finish()
            await metrics?.value
        }
        closing = close
        await close.value
    }
}
