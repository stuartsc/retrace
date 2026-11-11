import CoreGraphics
import CoreMedia
import CryptoKit
import Foundation
import ScreenCaptureKit
import Shared

struct CaptureDisplayTarget: Sendable, Equatable {
    let displayID: UInt32
    /// Monitor UUID, geometry and pixel mode; an ID alone is not a lifetime.
    let identity: String
    let descriptor: CaptureDisplayDescriptor?
    let isAsleep: Bool

    init(displayID: UInt32, identity: String) {
        self.displayID = displayID; self.identity = identity; descriptor = nil; isAsleep = false
    }
    init(descriptor: CaptureDisplayDescriptor, isAsleep: Bool = false) {
        self.descriptor = descriptor; displayID = descriptor.displayID; self.isAsleep = isAsleep
        identity = "\(descriptor.monitorUUID):\(descriptor.bounds):\(descriptor.pixelWidth)x\(descriptor.pixelHeight):\(descriptor.rotationDegrees):\(descriptor.refreshRateHz):\(descriptor.modeID)"
    }
}

struct ScreenCaptureEnvironment: Sendable {
    let displays: @Sendable () async throws -> [CaptureDisplayTarget]
    let context: @Sendable (CaptureDisplayTarget, CaptureConfig) async -> CapturedWindowSample
    let attributedPixels: @Sendable (CaptureDisplayTarget, CaptureConfig, ActivityContext?,
        (@Sendable (CaptureTextOutcome) -> Void)?, CapturePixelAttempt?) async throws -> CaptureAttributedPixelRead?
    let beginSession: @Sendable () async throws -> Void
    let endSession: @Sendable () async throws -> Void
    let retainDisplays: @Sendable ([CaptureDisplayTarget]) async throws -> Void

    /// Existing native-boundary fixtures retain their exact pixel path.
    init(displays: @escaping @Sendable () async throws -> [CaptureDisplayTarget],
         context: @escaping @Sendable (CaptureDisplayTarget, CaptureConfig) async -> CapturedWindowSample,
         pixels: @escaping @Sendable (CaptureDisplayTarget, CaptureConfig) async throws -> CapturedFrame?,
         beginSession: @escaping @Sendable () async throws -> Void = {},
         endSession: @escaping @Sendable () async throws -> Void = {},
         retainDisplays: @escaping @Sendable ([CaptureDisplayTarget]) async throws -> Void = { _ in }) {
        self.displays = displays; self.context = context
        self.beginSession = beginSession; self.endSession = endSession; self.retainDisplays = retainDisplays
        self.attributedPixels = { display, config, _, _, _ in
            guard let frame = try await pixels(display, config) else { return nil }
            return CaptureAttributedPixelRead(frame: frame)
        }
    }
    init(displays: @escaping @Sendable () async throws -> [CaptureDisplayTarget],
                 context: @escaping @Sendable (CaptureDisplayTarget, CaptureConfig) async -> CapturedWindowSample,
                 attributedPixels: @escaping @Sendable (CaptureDisplayTarget, CaptureConfig, ActivityContext?,
                    (@Sendable (CaptureTextOutcome) -> Void)?, CapturePixelAttempt?) async throws -> CaptureAttributedPixelRead?,
                 beginSession: @escaping @Sendable () async throws -> Void = {},
                 endSession: @escaping @Sendable () async throws -> Void = {},
                 retainDisplays: @escaping @Sendable ([CaptureDisplayTarget]) async throws -> Void = { _ in }) {
        self.displays = displays; self.context = context; self.attributedPixels = attributedPixels
        self.beginSession = beginSession; self.endSession = endSession; self.retainDisplays = retainDisplays
    }

    static func live() -> Self {
        let privacy = CGWindowListCapture()
        let streams = ScreenCaptureStreamPool()
        return Self(displays: { try activeDisplays() }, context: { display, config in
            await ActivityContextSource.live.sampleCandidateCapture(config: config, displayID: display.displayID)
        }, attributedPixels: { display, config, context, outcome, attempt in
            do {
                guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }
                let result = try await privacy.captureFilteredCandidatePixels(displayID: display.displayID, config: config) { permitted, masks in
                    try await streamedImage(display: display, config: config, context: context,
                        permittedWindows: permitted, privacyMasks: masks, outcome: outcome, attempt: attempt, streams: streams)
                }
                if result == nil { try await streams.invalidate(displayID: display.displayID) }
                return result
            } catch {
                try await streams.invalidate(displayID: display.displayID)
                throw error
            }
        }, beginSession: { try await streams.beginSession() }, endSession: { try await streams.stop() },
        retainDisplays: { displays in
            try await streams.reconcile(Dictionary(uniqueKeysWithValues:
                displays.filter { !$0.isAsleep }.map { ($0.displayID, $0.identity) }))
        })
    }

    private static func activeDisplays() throws -> [CaptureDisplayTarget] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count <= 64 else {
            throw CaptureError.noDisplaysAvailable
        }
        var identifiers = [UInt32](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &identifiers, &count) == .success, Int(count) <= identifiers.count else {
            throw CaptureError.noDisplaysAvailable
        }
        return try identifiers.prefix(Int(count)).map { id in
            guard id > 0, CGDisplayIsOnline(id) != 0,
                  let nativeUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let uuid = UUID(uuidString: CFUUIDCreateString(nil, nativeUUID) as String),
                  let mode = CGDisplayCopyDisplayMode(id) else { throw CaptureError.noDisplaysAvailable }
            let descriptor = CaptureDisplayDescriptor(displayID: id, monitorUUID: uuid,
                bounds: CGDisplayBounds(id), pixelWidth: CGDisplayPixelsWide(id), pixelHeight: CGDisplayPixelsHigh(id),
                rotationDegrees: CGDisplayRotation(id), refreshRateHz: mode.refreshRate,
                modeID: UInt32(bitPattern: mode.ioDisplayModeID))
            return CaptureDisplayTarget(descriptor: descriptor, isAsleep: CGDisplayIsAsleep(id) != 0)
        }.sorted { $0.displayID < $1.displayID }
    }

    private static func streamedImage(display: CaptureDisplayTarget, config: CaptureConfig, context: ActivityContext?,
                                   permittedWindows: Set<CapturePermittedWindow>, privacyMasks: [CGRect],
                                   outcome: (@Sendable (CaptureTextOutcome) -> Void)?, attempt: CapturePixelAttempt?,
                                   streams: ScreenCaptureStreamPool) async throws -> CapturePixelImageRead? {
        guard #available(macOS 14.0, *) else {
            throw CaptureError.captureSessionFailed(underlying: "ScreenCaptureKit streams are unavailable")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard !display.isAsleep, try activeDisplays().contains(display),
              let nativeDisplay = content.displays.first(where: { $0.displayID == display.displayID }) else {
            throw CaptureError.noDisplaysAvailable
        }
        let width = CGDisplayPixelsWide(display.displayID), height = CGDisplayPixelsHigh(display.displayID)
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 33_554_432 else {
            throw CaptureError.captureSessionFailed(underlying: "Display dimensions exceed bounded capture capacity")
        }
        guard content.windows.count <= 4096, permittedWindows.count <= 4096 else {
            throw CaptureError.captureSessionFailed(underlying: "Window inventory exceeds bounded capture capacity")
        }
        let permittedByID = Dictionary(grouping: permittedWindows, by: \.windowID)
        let included = content.windows.filter { window in
            guard let owner = window.owningApplication,
                  let proof = permittedByID[window.windowID], proof.count == 1 else { return false }
            return proof[0].admits(windowID: window.windowID, processID: owner.processID,
                                   bundleID: owner.bundleIdentifier, title: window.title, config: config)
        }
        // Empty includes must never become an unrestricted display capture.
        guard !included.isEmpty, Set(included.map(\.windowID)).count == included.count else {
            throw CaptureError.captureSessionFailed(underlying: "No window has current capture permission")
        }
        let filter = SCContentFilter(display: nativeDisplay, including: included)
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.captureResolution = .best
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = config.showCursor
        // ScreenCaptureKit's documented minimum native surface pool is three.
        // The app mailbox separately retains only its latest immutable image.
        configuration.queueDepth = 3
        configuration.capturesAudio = false
        // Native proof must arrive inside the existing two-second context/AX
        // bracket. This is a bounded low-rate source, never a display-rate stream.
        configuration.minimumFrameInterval = CMTime(seconds: min(max(config.captureIntervalSeconds, 0.25), 1),
                                                     preferredTimescale: 1_000_000)
        if #available(macOS 14.2, *) { configuration.includeChildWindows = false }
        // This is the final native include filter, not the earlier CG inventory.
        // AX begins only after this immutable pixel plan has been chosen.
        let proof = config.captureVisibleTextEnabled ? CaptureTextPixelProof.copy(displayID: display.displayID,
            includedWindowIDs: Set(included.map(\.windowID)), privacyMaskBounds: privacyMasks) : nil
        let identity = StreamFilterIdentity(policy: try ScreenEvidenceAccessPolicy(config: config).fingerprintSHA256(),
            notificationRevision: ObservedWindowGenerations.shared.notificationRevision,
            showCursor: config.showCursor, interval: config.captureIntervalSeconds,
            windows: included.sorted { $0.windowID < $1.windowID }.map {
                .init(id: $0.windowID, processID: $0.owningApplication!.processID,
                      bundle: $0.owningApplication!.bundleIdentifier, bounds: $0.frame)
            }, masks: privacyMasks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(identity)
        let key = ScreenCaptureStreamKey(displayID: display.displayID, displayIdentity: display.identity,
            width: width, height: height, configurationIdentity: SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined())
        let session = NativeScreenCaptureStreamSession(filter: filter, configuration: configuration)
        return try await CaptureVisibleTextReader.readImage(proof: proof, context: context,
            enabled: config.captureVisibleTextEnabled, backend: .screenCaptureKitCandidate, outcome: outcome,
            reservedAttemptID: attempt?.id, pixelReadCompleted: attempt?.didRead) {
                try await streams.read(key: key, timeout: .milliseconds(1250)) { session }.image
            }
    }

    private struct StreamFilterIdentity: Encodable {
        struct Window: Encodable { let id: UInt32; let processID: Int32; let bundle: String; let bounds: CGRect }
        let policy: String
        let notificationRevision: UInt64
        let showCursor: Bool
        let interval: Double
        let windows: [Window]
        let masks: [CGRect]
    }
}

/// Bounded observation cycles over persistent native streams. Only one batch
/// and one requested pixel proof exist at once. Each display retains its own
/// receipt; independent stream output does not imply simultaneous observations.
actor ScreenCaptureKitCapture: CaptureFrameSource {
    private let environment: ScreenCaptureEnvironment
    private let automaticallyPoll: Bool
    private let displayAttachments: CaptureDisplayAttachmentTracker
    private var groupDelivery: CaptureGroupDelivery?
    private var groupedSamplingActive = false
    private var sourceSessionID = UUID()
    private var stopGroupReason: CaptureGroupOutcomeReason = .sourceStopped
    private var active = false
    private var transitioning = false
    private var generation: UInt64 = 0
    private var config: CaptureConfig?
    private var activeDisplayID: UInt32?
    private var continuation: AsyncStream<CapturedFrame>.Continuation?
    private var polling: Task<Void, Never>?
    private var cycle: (id: UUID, task: Task<Void, Never>)?
    private var knownDisplays: [UInt32: CaptureDisplayTarget] = [:]
    private var gapStates: [UInt32: CaptureCoverageGapReason] = [:]
    private var coverageHandler: (@Sendable (CaptureCoverageEvent) -> Void)?
    private var textOutcomeHandler: (@Sendable (CaptureTextOutcome) -> Void)?
    private var environmentNeedsCleanup = false
    private var environmentCleanup: (id: UUID, task: Task<Void, Error>)?
    #if DEBUG
    private var invalidationCheckpoint: (@Sendable () -> Void)?
    private var coalescingCheckpoint: (@Sendable () -> Void)?
    func setInvalidationCheckpoint(_ value: (@Sendable () -> Void)?) { invalidationCheckpoint = value }
    func setCoalescingCheckpoint(_ value: (@Sendable () -> Void)?) { coalescingCheckpoint = value }
    #endif

    init(environment: ScreenCaptureEnvironment = .live(), automaticallyPoll: Bool = true,
         displayAttachments: CaptureDisplayAttachmentTracker = .init()) {
        self.environment = environment; self.automaticallyPoll = automaticallyPoll
        self.displayAttachments = displayAttachments
    }

    func setGroupDelivery(_ delivery: CaptureGroupDelivery?) async { groupDelivery = delivery }

    func suspendGroupedSampling() async {
        guard config?.captureGroupReceiptsEnabled == true else { return }
        groupedSamplingActive = false
        stopGroupReason = .configurationChanged
        generation &+= 1
        let oldPolling = polling, oldCycle = cycle?.task
        polling = nil; cycle = nil
        oldPolling?.cancel(); oldCycle?.cancel()
        #if DEBUG
        invalidationCheckpoint?()
        #endif
        await oldCycle?.value; await oldPolling?.value
        do { try await endEnvironment() }
        catch { report(.captureFailed, displayID: nil) }
    }

    /// Called only after CaptureManager has acknowledged policy activation and
    /// established its processing generation. A prepared policy grants no reads.
    func activateGroupedSampling(expectedPolicySHA256: String) async throws {
        guard let config, config.captureGroupReceiptsEnabled else { return }
        guard active, groupDelivery != nil, !transitioning,
              try ScreenEvidenceAccessPolicy(config: config).fingerprintSHA256() == expectedPolicySHA256 else {
            throw CaptureGroupJournalError.inactive
        }
        guard !groupedSamplingActive else { return }
        let admittedGeneration = generation
        try await beginEnvironment()
        guard active, !transitioning, generation == admittedGeneration else { throw CaptureGroupJournalError.inactive }
        groupedSamplingActive = true
        schedulePolling(generation: generation)
    }

    func setCoverageHandler(_ handler: (@Sendable (CaptureCoverageEvent) -> Void)?) async { coverageHandler = handler }
    func setTextOutcomeHandler(_ handler: (@Sendable (CaptureTextOutcome) -> Void)?) async { textOutcomeHandler = handler }

    func startCapture(config: CaptureConfig, frameContinuation: AsyncStream<CapturedFrame>.Continuation,
                      displayID: CGDirectDisplayID?) async throws {
        guard !active else { return }
        try validate(config)
        if config.captureGroupReceiptsEnabled {
            guard groupDelivery != nil else { throw CaptureGroupJournalError.unavailable }
            try displayAttachments.start()
        }
        sourceSessionID = UUID()
        groupedSamplingActive = false
        generation &+= 1
        let admittedGeneration = generation
        active = true
        transitioning = true
        self.config = config; continuation = frameContinuation; activeDisplayID = displayID
        do {
            let displays = try await environment.displays()
            try Task.checkCancellation()
            guard active, generation == admittedGeneration else { throw CancellationError() }
            guard !displays.isEmpty, displays.count <= 64 else { throw CaptureError.noDisplaysAvailable }
            try await beginEnvironment()
            try Task.checkCancellation()
            guard active, generation == admittedGeneration else { throw CancellationError() }
            knownDisplays = displays.reduce(into: [:]) { $0[$1.displayID] = $1 }
            transitioning = false
            schedulePolling(generation: admittedGeneration)
        } catch {
            if generation == admittedGeneration {
                active = false; transitioning = false; continuation = nil; displayAttachments.stop()
            }
            try await endEnvironment()
            throw error
        }
    }

    func stopCapture() async throws {
        active = false
        transitioning = false
        groupedSamplingActive = false
        stopGroupReason = .sourceStopped
        generation &+= 1
        let oldPolling = polling, oldCycle = cycle?.task
        polling = nil; cycle = nil; continuation = nil
        oldPolling?.cancel(); oldCycle?.cancel()
        #if DEBUG
        invalidationCheckpoint?()
        #endif
        await oldCycle?.value
        await oldPolling?.value
        try await endEnvironment()
        knownDisplays.removeAll(); gapStates.removeAll(); displayAttachments.stop()
    }

    func updateConfig(_ config: CaptureConfig) async throws {
        try validate(config)
        if config.captureGroupReceiptsEnabled, groupDelivery == nil { throw CaptureGroupJournalError.unavailable }
        let previouslyGrouped = self.config?.captureGroupReceiptsEnabled == true
        groupedSamplingActive = false
        stopGroupReason = .configurationChanged
        generation &+= 1
        let admittedGeneration = generation
        transitioning = true
        self.config = config
        let oldPolling = polling, oldCycle = cycle?.task
        polling = nil; cycle = nil
        oldPolling?.cancel(); oldCycle?.cancel()
        report(.configurationChanged, displayID: nil)
        #if DEBUG
        invalidationCheckpoint?()
        #endif
        await oldCycle?.value
        await oldPolling?.value
        try await endEnvironment()
        try Task.checkCancellation()
        guard active, generation == admittedGeneration else { return }
        if config.captureGroupReceiptsEnabled, !previouslyGrouped { try displayAttachments.start() }
        else if !config.captureGroupReceiptsEnabled { displayAttachments.stop() }
        try await beginEnvironment()
        guard active, generation == admittedGeneration, !Task.isCancelled else { return }
        transitioning = false
        schedulePolling(generation: admittedGeneration)
    }

    func captureImmediateAndResetTimer() async {
        guard active else { return }
        await captureCycle(generation: generation)
    }

    private func validate(_ config: CaptureConfig) throws {
        guard config.captureIntervalSeconds.isFinite, config.captureIntervalSeconds > 0 else {
            throw CaptureError.captureSessionFailed(underlying: "Capture interval must be positive and finite")
        }
    }

    private func beginEnvironment() async throws {
        if environmentNeedsCleanup { try await endEnvironment() }
        try Task.checkCancellation()
        environmentNeedsCleanup = true
        try await environment.beginSession()
    }

    private func endEnvironment() async throws {
        guard environmentNeedsCleanup else { return }
        let operation: (id: UUID, task: Task<Void, Error>)
        if let cleanup = environmentCleanup { operation = cleanup }
        else {
            let environment = self.environment
            operation = (UUID(), Task { try await environment.endSession() })
            environmentCleanup = operation
        }
        do {
            try await operation.task.value
            if environmentCleanup?.id == operation.id { environmentCleanup = nil; environmentNeedsCleanup = false }
        } catch {
            if environmentCleanup?.id == operation.id { environmentCleanup = nil }
            throw error
        }
    }

    private func schedulePolling(generation admittedGeneration: UInt64) {
        guard automaticallyPoll, config?.captureGroupReceiptsEnabled != true || groupedSamplingActive else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, await self.isCurrent(admittedGeneration) else { return }
                await self.captureCycle(generation: admittedGeneration)
                guard let interval = await self.currentInterval(admittedGeneration) else { return }
                do { try await Task.sleep(for: .seconds(interval), clock: .continuous) }
                catch { return }
            }
        }
    }

    private func isCurrent(_ value: UInt64) -> Bool {
        active && !transitioning && generation == value && !Task.isCancelled &&
            (config?.captureGroupReceiptsEnabled != true || groupedSamplingActive)
    }
    private func currentInterval(_ value: UInt64) -> Double? {
        guard isCurrent(value), let config else { return nil }
        return min(max(config.captureIntervalSeconds, 0.25), 3600)
    }

    private func captureCycle(generation admittedGeneration: UInt64) async {
        guard isCurrent(admittedGeneration), let config, let continuation else { return }
        if let cycle {
            report(.busy, displayID: nil)
            #if DEBUG
            coalescingCheckpoint?()
            #endif
            await cycle.task.value
            return
        }
        let id = UUID()
        let task = Task { await performCapture(config: config, continuation: continuation, generation: admittedGeneration) }
        cycle = (id, task)
        await task.value
        if cycle?.id == id { cycle = nil }
    }

    private func performCapture(config: CaptureConfig, continuation: AsyncStream<CapturedFrame>.Continuation,
                                generation admittedGeneration: UInt64) async {
        let started = ContinuousClock.now
        if config.captureGroupReceiptsEnabled {
            await performGroupedCapture(config: config, continuation: continuation, generation: admittedGeneration)
            return
        }
        do {
            let capturePolicySHA256 = try ScreenEvidenceAccessPolicy(config: config).fingerprintSHA256()
            let attached = try await environment.displays()
            guard isCurrent(admittedGeneration) else { return }
            guard attached.count <= 64, Set(attached.map(\.displayID)).count == attached.count,
                  attached.allSatisfy({ $0.displayID > 0 && !$0.identity.isEmpty }) else {
                try await environment.retainDisplays([])
                report(.displayUnavailable, displayID: nil); return
            }
            let current = attached.reduce(into: [UInt32: CaptureDisplayTarget]()) { $0[$1.displayID] = $1 }
            for (id, previous) in knownDisplays where current[id] != previous { report(.displayUnavailable, displayID: id) }
            knownDisplays = current
            let selected = attached.filter { config.displayPolicy == .allDisplays || $0.displayID == activeDisplayID }
                .sorted { $0.displayID < $1.displayID }
            try await environment.retainDisplays(selected)
            guard !selected.isEmpty else { report(.displayUnavailable, displayID: activeDisplayID); return }
            let textOutcome = textOutcomeHandler
            for display in selected {
                guard isCurrent(admittedGeneration) else { return }
                guard !display.isAsleep else { report(.displayUnavailable, displayID: display.displayID); continue }
                do {
                    let frame = try await CaptureSnapshotSequencer.captureAttributed(displayID: display.displayID, allowDisplayOnly: true,
                        capturePolicySHA256: capturePolicySHA256,
                        readContext: { await self.environment.context(display, config) },
                        capturePixels: { context in
                            try await self.environment.attributedPixels(display, config, context, textOutcome, nil)
                        })
                    guard isCurrent(admittedGeneration) else { return }
                    let after = try await environment.displays()
                    guard isCurrent(admittedGeneration) else { return }
                    guard after.contains(display) else { report(.displayUnavailable, displayID: display.displayID); continue }
                    guard let frame else {
                        try await environment.retainDisplays(selected.filter { $0.displayID != display.displayID })
                        report(.unstableContext, displayID: display.displayID); continue
                    }
                    switch continuation.yield(frame) {
                    case .enqueued: recover(displayID: display.displayID)
                    case .dropped: report(.consumerBackpressure, displayID: display.displayID)
                    case .terminated: return
                    @unknown default: report(.consumerBackpressure, displayID: display.displayID)
                    }
                } catch {
                    guard isCurrent(admittedGeneration) else { return }
                    report(.captureFailed, displayID: display.displayID)
                }
            }
            let duration = started.duration(to: .now)
            let elapsed = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            Log.recordLatency("capture.screencapturekit_batch", valueMs: elapsed * 1000, category: .capture)
            if elapsed > config.captureIntervalSeconds { report(.busy, displayID: nil) }
            else { recover(displayID: nil) }
        } catch {
            guard isCurrent(admittedGeneration) else { return }
            try? await environment.retainDisplays([])
            report(.captureFailed, displayID: nil)
        }
    }

    private func performGroupedCapture(config: CaptureConfig, continuation: AsyncStream<CapturedFrame>.Continuation,
                                       generation admittedGeneration: UInt64) async {
        guard let delivery = groupDelivery else { await failGroupedCapture(continuation); return }
        var begun: CaptureSamplingGroup?
        var observedReceipts: [UUID: CapturePixelReceipt] = [:]
        var candidateAwaitingYield: (member: CaptureGroupFrameReceipt, receipt: CapturePixelReceipt)?
        var cancellationReason: CaptureGroupOutcomeReason?
        let started = ContinuousClock.now
        do {
            let policy = try ScreenEvidenceAccessPolicy(config: config).fingerprintSHA256()
            let enumerationDate = Date(), enumerationUptime = ProcessInfo.processInfo.systemUptime
            let attached: [CaptureDisplayTarget]
            do { attached = try await environment.displays() }
            catch {
                try? await environment.retainDisplays([])
                if isCurrent(admittedGeneration) { report(.displayUnavailable, displayID: nil) }; return
            }
            guard isCurrent(admittedGeneration) else { return }
            guard !attached.isEmpty, attached.count <= CaptureSamplingGroup.maximumTargets,
                  attached.allSatisfy({ $0.descriptor != nil }) else {
                try await environment.retainDisplays([])
                report(.displayUnavailable, displayID: nil); return
            }
            let attachments: [UInt32: CaptureDisplayAttachment]
            do { attachments = try displayAttachments.sample(attached.compactMap(\.descriptor)) }
            catch { report(.displayUnavailable, displayID: nil); return }
            let selected = attached.filter { config.displayPolicy == .allDisplays || $0.displayID == activeDisplayID }
                .sorted { $0.displayID < $1.displayID }
            try await environment.retainDisplays(selected)
            guard !selected.isEmpty else { report(.displayUnavailable, displayID: activeDisplayID); return }
            let targets = try selected.map { display -> CaptureSamplingTarget in
                guard let attachment = attachments[display.displayID] else { throw CaptureError.noDisplaysAvailable }
                return CaptureSamplingTarget(attemptID: UUID(), attachment: attachment)
            }
            let group = CaptureSamplingGroup(groupID: UUID(), sessionID: sourceSessionID,
                configurationGeneration: admittedGeneration, backend: .screenCaptureKitCandidate,
                displayPolicy: config.displayPolicy, capturePolicySHA256: policy,
                enumeration: .init(startedAt: enumerationDate, endedAt: Date(), startedUptime: enumerationUptime,
                    endedUptime: ProcessInfo.processInfo.systemUptime), targets: targets)
            // No context/AX/native pixels start until this write commits. Targets
            // remain durable pending if the process dies after acknowledgement.
            try await delivery.begin(group)
            begun = group
            guard isCurrent(admittedGeneration) else { throw CancellationError() }
            let current = attached.reduce(into: [UInt32: CaptureDisplayTarget]()) { $0[$1.displayID] = $1 }
            for (id, old) in knownDisplays where current[id] != old { report(.displayUnavailable, displayID: id) }
            knownDisplays = current
            let textOutcome = textOutcomeHandler
            for (display, target) in zip(selected, targets) {
                guard isCurrent(admittedGeneration) else { throw CancellationError() }
                let member = CaptureGroupFrameReceipt(group: group, target: target)
                if display.isAsleep || !displayAttachments.isCurrent(target.attachment) {
                    try await delivery.terminal(.init(member: member, disposition: .unavailable,
                        reason: display.isAsleep ? .displayAsleep : .displayReconfigured))
                    report(.displayUnavailable, displayID: display.displayID)
                    continue
                }
                let box = CapturePixelReceiptBox()
                let attempt = CapturePixelAttempt(id: target.attemptID, didRead: { box.store($0) })
                let frame: CapturedFrame?
                do {
                    frame = try await CaptureSnapshotSequencer.captureAttributed(displayID: display.displayID,
                        allowDisplayOnly: true, capturePolicySHA256: policy,
                        readContext: { await self.environment.context(display, config) },
                        capturePixels: { context in
                            guard self.displayAttachments.isCurrent(target.attachment), !Task.isCancelled else { return nil }
                            return try await self.environment.attributedPixels(display, config, context, textOutcome, attempt)
                        })
                } catch {
                    if let receipt = box.value { observedReceipts[target.attemptID] = receipt }
                    guard isCurrent(admittedGeneration) else { throw CancellationError() }
                    try await delivery.terminal(.init(member: member, disposition: .unavailable,
                        reason: .captureFailed, pixelReceipt: box.value))
                    report(.captureFailed, displayID: display.displayID)
                    continue
                }
                if let receipt = box.value { observedReceipts[target.attemptID] = receipt }
                guard isCurrent(admittedGeneration) else { throw CancellationError() }
                let after: [CaptureDisplayTarget]
                do { after = try await environment.displays() }
                catch {
                    guard isCurrent(admittedGeneration) else { throw CancellationError() }
                    try await delivery.terminal(.init(member: member, disposition: .unavailable,
                        reason: .displayUnavailable, pixelReceipt: box.value))
                    report(.displayUnavailable, displayID: display.displayID); continue
                }
                guard isCurrent(admittedGeneration) else { throw CancellationError() }
                // Reconcile every attachment, including removal, before testing
                // this completion. A notification ABA cannot be erased by an
                // equal final descriptor because it rotates attachment identity.
                guard after.count <= CaptureSamplingGroup.maximumTargets, after.allSatisfy({ $0.descriptor != nil }) else {
                    try await delivery.terminal(.init(member: member, disposition: .unavailable,
                        reason: .displayUnavailable, pixelReceipt: box.value))
                    report(.displayUnavailable, displayID: display.displayID); continue
                }
                do { _ = try displayAttachments.sample(after.compactMap(\.descriptor)) }
                catch {
                    try await delivery.terminal(.init(member: member, disposition: .unavailable,
                        reason: .displayUnavailable, pixelReceipt: box.value))
                    report(.displayUnavailable, displayID: display.displayID); continue
                }
                guard after.contains(display), displayAttachments.isCurrent(target.attachment) else {
                    try await delivery.terminal(.init(member: member, disposition: .unavailable,
                        reason: .displayReconfigured, pixelReceipt: box.value))
                    report(.displayUnavailable, displayID: display.displayID); continue
                }
                guard let frame else {
                    try await environment.retainDisplays(selected.filter { $0.displayID != display.displayID })
                    try await delivery.terminal(.init(member: member, disposition: .unavailable,
                        reason: .unstableContext, pixelReceipt: box.value))
                    report(.unstableContext, displayID: display.displayID); continue
                }
                guard let receipt = frame.metadata.pixelReceipt, receipt == box.value,
                      receipt.attemptID == target.attemptID,
                      frame.width == target.attachment.pixelWidth, frame.height == target.attachment.pixelHeight else {
                    try await delivery.terminal(.init(member: member, disposition: .unavailable,
                        reason: .pixelReceiptUnavailable, pixelReceipt: box.value))
                    report(.captureFailed, displayID: display.displayID); continue
                }
                try await delivery.candidate(member, receipt: receipt)
                candidateAwaitingYield = (member, receipt)
                guard isCurrent(admittedGeneration) else { throw CancellationError() }
                let grouped = CapturedFrame(timestamp: frame.timestamp, imageData: frame.imageData,
                    width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow,
                    metadata: frame.metadata.linkingCaptureGroup(member))
                switch continuation.yield(grouped) {
                case .enqueued:
                    candidateAwaitingYield = nil
                    recover(displayID: display.displayID)
                case .dropped(let dropped):
                    candidateAwaitingYield = nil
                    if let droppedMember = dropped.metadata.captureGroup, let pixels = dropped.metadata.pixelReceipt {
                        try await delivery.terminal(.init(member: droppedMember, disposition: .dropped,
                            reason: .rawBufferBackpressure, pixelReceipt: pixels))
                    } else { throw CaptureGroupJournalError.invalidTransition }
                    report(.consumerBackpressure, displayID: dropped.metadata.displayID)
                case .terminated:
                    cancellationReason = .streamCancelled
                    throw CancellationError()
                @unknown default: throw CaptureGroupJournalError.invalidTransition
                }
            }
            try await delivery.samplingEnded(group, reason: .completed)
            begun = nil
            let duration = started.duration(to: .now)
            let elapsed = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            Log.recordLatency("capture.screencapturekit_group", valueMs: elapsed * 1000, category: .capture)
            if elapsed > config.captureIntervalSeconds { report(.busy, displayID: nil) }
            else { recover(displayID: nil) }
        } catch is CancellationError {
            guard let group = begun else { return }
            let reason = cancellationReason ?? stopGroupReason, receipts = observedReceipts
            let candidate = candidateAwaitingYield
            do {
                // This single owned cleanup task does not inherit caller
                // cancellation; source stop/configuration joins its completion.
                try await Task {
                    if let candidate {
                        try await delivery.terminal(.init(member: candidate.member, disposition: .cancelled,
                            reason: reason, pixelReceipt: candidate.receipt))
                    }
                    try await delivery.cancelPending(in: group, reason: reason, receipts: receipts)
                    try await delivery.samplingEnded(group, reason: reason == .configurationChanged ? .configurationChanged : .cancelled)
                }.value
            } catch { await failGroupedCapture(continuation) }
        } catch {
            // A journal error must never become an ordinary capture miss. Leave
            // unresolved durable members for restart; no future reads may run.
            await failGroupedCapture(continuation)
        }
    }

    private func failGroupedCapture(_ stream: AsyncStream<CapturedFrame>.Continuation) async {
        groupedSamplingActive = false
        active = false
        generation &+= 1
        polling?.cancel(); polling = nil
        report(.groupJournalUnavailable, displayID: nil)
        stream.finish()
        try? await endEnvironment()
    }

    private func report(_ reason: CaptureCoverageGapReason, displayID: UInt32?) {
        let key = displayID ?? 0
        guard gapStates[key] != reason else { return }
        if gapStates.count >= 128 { gapStates.removeAll() }
        gapStates[key] = reason
        coverageHandler?(CaptureCoverageEvent(backend: .screenCaptureKitCandidate, displayID: displayID, state: .gap(reason)))
    }

    private func recover(displayID: UInt32?) {
        guard gapStates.removeValue(forKey: displayID ?? 0) != nil else { return }
        coverageHandler?(CaptureCoverageEvent(backend: .screenCaptureKitCandidate, displayID: displayID, state: .recovered))
    }
}

/// Backend replacement remains inside CaptureManager's serialized admission
/// bracket; the candidate cannot silently fall back after a failed native start.
actor CaptureSourceRouter: CaptureFrameSource {
    private let legacy: any CaptureFrameSource
    private let candidate: any CaptureFrameSource
    private var selected: (any CaptureFrameSource)?
    private var selectionID: UUID?
    private var config: CaptureConfig?
    private var continuation: AsyncStream<CapturedFrame>.Continuation?
    private var displayID: UInt32?

    init(legacy: any CaptureFrameSource = CGWindowListCapture(),
         candidate: any CaptureFrameSource = ScreenCaptureKitCapture()) {
        self.legacy = legacy; self.candidate = candidate
    }

    func setCoverageHandler(_ handler: (@Sendable (CaptureCoverageEvent) -> Void)?) async {
        await legacy.setCoverageHandler(handler)
        await candidate.setCoverageHandler(handler)
    }

    func setTextOutcomeHandler(_ handler: (@Sendable (CaptureTextOutcome) -> Void)?) async {
        await legacy.setTextOutcomeHandler(handler)
        await candidate.setTextOutcomeHandler(handler)
    }

    func setGroupDelivery(_ delivery: CaptureGroupDelivery?) async {
        await candidate.setGroupDelivery(delivery)
    }
    func suspendGroupedSampling() async { await selected?.suspendGroupedSampling() }
    func activateGroupedSampling(expectedPolicySHA256: String) async throws {
        try await selected?.activateGroupedSampling(expectedPolicySHA256: expectedPolicySHA256)
    }

    func startCapture(config: CaptureConfig, frameContinuation: AsyncStream<CapturedFrame>.Continuation,
                      displayID: CGDirectDisplayID?) async throws {
        // A failed stop retains the old owner. Even a different backend cannot
        // replace it until its native cleanup has acknowledged completion.
        if selected != nil { try await stopCapture() }
        try Task.checkCancellation()
        guard selected == nil else { throw ScreenCaptureStreamError.busy }
        let source = config.backend == .legacy ? legacy : candidate
        selected = source; selectionID = UUID()
        self.config = config; continuation = frameContinuation; self.displayID = displayID
        try await source.startCapture(config: config, frameContinuation: frameContinuation, displayID: displayID)
    }

    func stopCapture() async throws {
        let source = selected, retiringID = selectionID
        try await source?.stopCapture()
        // Concurrent joined stops must not clear a replacement's ownership.
        if selectionID == retiringID { selected = nil; selectionID = nil; continuation = nil }
    }

    func updateConfig(_ config: CaptureConfig) async throws {
        guard let selected, let continuation else { self.config = config; return }
        if self.config?.backend != config.backend {
            try await stopCapture()
            try Task.checkCancellation()
            try await startCapture(config: config, frameContinuation: continuation, displayID: displayID)
        } else {
            self.config = config
            try await selected.updateConfig(config)
        }
    }

    func captureImmediateAndResetTimer() async { await selected?.captureImmediateAndResetTimer() }
}
