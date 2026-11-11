import AppKit
import CoreAudio
import Darwin
import Foundation
import Shared

/// Kernel process start time closes PID-reuse races around process-scoped IO.
/// A missing/unreadable birth record is not affirmative termination evidence.
struct MeetingProcessBirth: Equatable, Sendable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64
    static func read(pid: Int32) -> Self? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let bytes = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, bytes)
        guard read == bytes, info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0,
              info.pbi_start_tvusec < 1_000_000 else { return nil }
        return Self(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }
    static func hasExited(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == -1 && errno == ESRCH
    }
}

struct MeetingReadStart {
    let date = Date()
    let uptime = ProcessInfo.processInfo.systemUptime
    func interval() -> CaptureReadInterval {
        CaptureReadInterval(startedAt: date, endedAt: Date(), startedUptime: uptime,
                            endedUptime: ProcessInfo.processInfo.systemUptime)
    }
}

enum MeetingCoreAudioInput {
    /// Only reads public HAL metadata. Does not open a device, create a tap,
    /// request recording permission or equate generic input IO with a call.
    static func observe(application: MeetingApplicationIdentity, birth: MeetingProcessBirth) -> MeetingObservation {
        let start = MeetingReadStart()
        func result(_ signal: MeetingSignal, _ reason: MeetingUncertainty? = nil) -> MeetingObservation {
            MeetingObservation(interval: start.interval(), source: .coreAudioProcessInput, signal: signal,
                               application: application, uncertainty: reason)
        }
        guard application.processID == birth.pid, MeetingProcessBirth.read(pid: birth.pid) == birth else {
            return result(.unavailable, .identityUnproved)
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = application.processID
        var object = AudioObjectID(kAudioObjectUnknown)
        var bytes = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<Int32>.size), &pid, &bytes, &object)
        guard status == noErr, bytes == MemoryLayout<AudioObjectID>.size else {
            return result(.unavailable, .nativeUnavailable)
        }
        // Apple's documented no-client result is an unknown object with no
        // error. Revalidate the process lifetime before reporting observed idle.
        if object == kAudioObjectUnknown {
            guard MeetingProcessBirth.read(pid: birth.pid) == birth else { return result(.unavailable, .sourceChanged) }
            return result(.idleInput)
        }
        func read(_ selector: AudioObjectPropertySelector) -> UInt32? {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
                  size == MemoryLayout<UInt32>.size else { return nil }
            return value
        }
        guard read(kAudioProcessPropertyPID) == UInt32(application.processID),
              let input = read(kAudioProcessPropertyIsRunningInput), input <= 1,
              read(kAudioProcessPropertyPID) == UInt32(application.processID),
              MeetingProcessBirth.read(pid: birth.pid) == birth else {
            return result(.unavailable, .sourceChanged)
        }
        return result(input == 1 ? .runningInput : .idleInput)
    }
}

/// One serial inventory/native read owner. NSRunningApplication is documented
/// thread-safe; no LaunchServices/property lookup occurs on MainActor here.
final class MeetingNativeObservationSource: @unchecked Sendable {
    private struct Entry: @unchecked Sendable {
        let app: NSRunningApplication
        let birth: MeetingProcessBirth
        let identity: MeetingApplicationIdentity
    }
    private struct Inventory: Sendable {
        let entries: [Entry]
        let observations: [MeetingObservation]
        let selected: Entry?
    }
    private let queue = DispatchQueue(label: "retrace.meeting.native-evidence", qos: .utility)
    private let captureConfig: (@Sendable () async -> MeetingCapturePolicySnapshot?)?
    private let applications: @Sendable (String) -> [NSRunningApplication]?
    private var identities: [Int32: Entry] = [:] // Accessed only on the serial native queue.

    init(captureConfig: (@Sendable () async -> MeetingCapturePolicySnapshot?)?,
         applications: @escaping @Sendable (String) -> [NSRunningApplication]? = {
             NSRunningApplication.runningApplications(withBundleIdentifier: $0)
         }) {
        self.captureConfig = captureConfig; self.applications = applications
    }

    func sample(bundleIDs: Set<String>, comparisonEnabled: Bool, previous: MeetingApplicationIdentity?) async -> MeetingSample {
        guard !Task.isCancelled else { return unavailable(.cancelled) }
        guard let snapshot = await captureConfig?(),
              let fingerprint = try? ScreenEvidenceAccessPolicy(config: snapshot.configuration).fingerprintSHA256() else {
            return unavailable(.policyUnavailable)
        }
        let config = snapshot.configuration
        guard !Task.isCancelled else { return unavailable(.cancelled) }
        let inventory = await inventory(bundleIDs: bundleIDs, config: config, previous: previous)
        guard !Task.isCancelled else { return unavailable(.cancelled) }
        var observations = inventory.observations
        var visited = 0
        if comparisonEnabled, let selected = inventory.selected {
            // The AX reader owns its observer/thread until this exact input read
            // and postvalidation finish. Global audio is never assigned to it.
            let input = MeetingInputReceiptBox()
            let controls = await MeetingCallControlReader.read(application: selected.identity,
                birth: selected.birth, config: config, between: { [queue] in
                    let observation = await withCheckedContinuation { continuation in
                        queue.async { continuation.resume(returning:
                            MeetingCoreAudioInput.observe(application: selected.identity, birth: selected.birth)) }
                    }
                    input.set(observation)
                })
            visited = controls.visitedNodes
            observations.append(controls.observation)
            // An unavailable control read may skip its bracket; still sample
            // input metadata once, for a possible-call uncertainty account.
            if input.get() == nil {
                let observation = await withCheckedContinuation { continuation in
                    queue.async { continuation.resume(returning:
                        MeetingCoreAudioInput.observe(application: selected.identity, birth: selected.birth)) }
                }
                input.set(observation)
            }
            if let input = input.get() { observations.append(input) }
        }
        guard !Task.isCancelled else { return unavailable(.cancelled) }
        guard let latest = await captureConfig?(),
              latest.revision == snapshot.revision,
              (try? ScreenEvidenceAccessPolicy(config: latest.configuration).fingerprintSHA256()) == fingerprint else {
            return unavailable(.policyUnavailable)
        }
        return MeetingSample(observations: observations, observedAt: Date(), observedUptime: ProcessInfo.processInfo.systemUptime,
                             candidateCount: inventory.entries.count, controlsVisited: visited)
    }

    func reset() async {
        await withCheckedContinuation { continuation in
            queue.async { self.identities.removeAll(); continuation.resume() }
        }
    }

    /// Content-free resource count for bounded native-lifecycle regressions.
    func retainedIdentityCount() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.identities.count) }
        }
    }

    private func inventory(bundleIDs: Set<String>, config: CaptureConfig,
                           previous: MeetingApplicationIdentity?) async -> Inventory {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.copyInventory(bundleIDs: bundleIDs, config: config, previous: previous)) }
        }
    }

    private func copyInventory(bundleIDs: Set<String>, config: CaptureConfig,
                                          previous: MeetingApplicationIdentity?) -> Inventory {
        let start = MeetingReadStart()
        func unavailable(_ reason: MeetingUncertainty) -> Inventory {
            Inventory(entries: [], observations: [MeetingObservation(interval: start.interval(), source: .applicationInventory,
                signal: .unavailable, uncertainty: reason)], selected: nil)
        }
        guard !bundleIDs.isEmpty else { return unavailable(.noCorroboration) }
        guard bundleIDs.count <= 32, bundleIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
            return unavailable(.budgetExceeded)
        }
        let previousEntry = previous.flatMap { identities[$0.processID] }
        var entries: [Entry] = []
        // Commit process handles only after a complete admitted inventory.
        // Early native/budget failures retain the previous bounded registry.
        var nextIdentities: [Int32: Entry] = [:]
        for bundle in bundleIDs.sorted() {
            guard ProcessInfo.processInfo.systemUptime - start.uptime <= 0.250 else { return unavailable(.budgetExceeded) }
            guard let apps = applications(bundle) else { return unavailable(.nativeUnavailable) }
            guard apps.count <= 16 - entries.count else { return unavailable(.budgetExceeded) }
            if !apps.isEmpty, config.excludedAppBundleIDs.contains(bundle) { return unavailable(.privacyExcluded) }
            for app in apps {
                let pid = app.processIdentifier
                guard !app.isTerminated, app.bundleIdentifier == bundle,
                      let birth = MeetingProcessBirth.read(pid: pid) else { return unavailable(.identityUnproved) }
                let existing = identities[pid]
                let identity = existing?.birth == birth && existing?.app.isEqual(app) == true ? existing!.identity :
                    MeetingApplicationIdentity(bundleID: bundle, processID: pid, processGeneration: UUID())
                let entry = Entry(app: app, birth: birth, identity: identity)
                nextIdentities[pid] = entry; entries.append(entry)
            }
        }
        guard ProcessInfo.processInfo.systemUptime - start.uptime <= 0.250 else { return unavailable(.budgetExceeded) }
        var observations: [MeetingObservation] = []
        if let previous, let old = previousEntry, old.identity == previous {
            if MeetingProcessBirth.hasExited(pid: previous.processID) ||
                MeetingProcessBirth.read(pid: previous.processID).map({ $0 != old.birth }) == true {
                observations.append(MeetingObservation(interval: start.interval(), source: .applicationInventory,
                    signal: .processEnded, application: previous))
            }
        }
        for entry in entries {
            guard !entry.app.isTerminated, entry.app.processIdentifier == entry.identity.processID,
                  entry.app.bundleIdentifier == entry.identity.bundleID,
                  MeetingProcessBirth.read(pid: entry.identity.processID) == entry.birth else { return unavailable(.sourceChanged) }
            observations.append(MeetingObservation(interval: start.interval(), source: .applicationInventory,
                                                   signal: .present, application: entry.identity))
        }
        guard ProcessInfo.processInfo.systemUptime - start.uptime <= 0.250 else { return unavailable(.budgetExceeded) }
        if entries.isEmpty { observations.append(MeetingObservation(interval: start.interval(), source: .applicationInventory, signal: .noCandidates)) }
        if let previous, let old = previousEntry, old.identity == previous,
           nextIdentities[previous.processID] == nil {
            nextIdentities[previous.processID] = old
        }
        identities = nextIdentities
        let selected = entries.first(where: { $0.app.isActive && !$0.app.isHidden }) ??
            entries.first(where: { $0.identity == previous && !$0.app.isHidden }) ?? entries.first(where: { !$0.app.isHidden })
        return Inventory(entries: entries, observations: observations, selected: selected)
    }

    private func unavailable(_ reason: MeetingUncertainty) -> MeetingSample {
        let start = MeetingReadStart()
        return MeetingSample(observations: [MeetingObservation(interval: start.interval(), source: .applicationInventory,
            signal: .unavailable, uncertainty: reason)], observedAt: Date(), observedUptime: ProcessInfo.processInfo.systemUptime,
            candidateCount: 0, controlsVisited: 0)
    }
}

private final class MeetingInputReceiptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MeetingObservation?
    func set(_ observation: MeetingObservation) { lock.withLock { value = observation } }
    func get() -> MeetingObservation? { lock.withLock { value } }
}
