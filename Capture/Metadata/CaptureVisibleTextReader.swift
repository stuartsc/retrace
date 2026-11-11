import ApplicationServices
import CoreGraphics
import Foundation
import Shared

/// Content-free, opt-in diagnostics for the owned native fixture. The reader
/// emits at most one preparation and one revalidation receipt per attempt.
/// Attribute values, window/process identity and captured strings are excluded.
struct CaptureVisibleTextDiagnostic: Sendable {
    enum Phase: String, Sendable { case preflight, preparation, revalidation }
    enum Operation: String, Sendable {
        case preflight, contextIdentity, contextProcess, contextWindow, contextLifetime, contextDisplay
        case pixelInventory, observerCreate, observerAdd
        case focusedWindow, windowProof, windowLabel, role, subrole, parent, position, size, hidden
        case title, titleElement, minimized, childrenCount, childrenPage, visibleRange
        case characterCount, lineForIndex, rangeForLine, boundsForRange, stringForRange
        case hitTest, processIdentity, messagingTimeout, attribute, parameter, complete
    }
    /// Fixed categories only; count is capped at the native node bound. A
    /// rejected range may have more than one independent conservative cause.
    enum Rejection: String, Sendable {
        case windowChrome, outsideDisplay, outsideAncestor, emptyVisibleRange
        case unsupportedSubrole, secureTextField, textField, scrollBar, button, unknownRole
        case unsupportedVisibleRange, clippedLine, unsupportedLine, invalidRangeBounds
        case outsideFrameOrWindow, privacyMask, ownedWindowOcclusion, otherWindowOcclusion
        case nodeClipping, ancestorClipping, siblingOcclusion, hitTestUnavailable, hitTestMismatch
    }
    struct RejectionCount: Sendable {
        let count: Int
        let operation: Operation
        let nativeStatus: Int32?
    }
    let rejections: [Rejection: RejectionCount]
    let phase: Phase
    let operation: Operation
    let nativeStatus: Int32?
    let proofFailure: CaptureTextPixelProof.CurrentFailure?
    let windowMatch: CaptureTextPixelProof.WindowMatch?
    let visitedNodes: Int
    let registrations: Int
    let retainedRuns: Int
    let reasons: [CaptureTextReason]
}

/// Opt-in capture-time direct text. Native AX objects never leave the owned
/// reader thread; its observer is removed before its final continuation resumes.
/// Public AX and pixels are bracketed observations, never an atomic snapshot.
enum CaptureVisibleTextReader {
    private static let countLock = NSLock()
    private static var readers = 0
    static var activeNativeReaderCount: Int { countLock.withLock { readers } }
    fileprivate static func noteReader(_ delta: Int) { countLock.withLock { readers += delta } }

    static func readImage(proof: CaptureTextPixelProof?, context: ActivityContext?, enabled: Bool,
                          backend: CaptureBackend,
                          diagnostic: (@Sendable (CaptureVisibleTextDiagnostic) -> Void)? = nil,
                          outcome: (@Sendable (CaptureTextOutcome) -> Void)? = nil,
                          observedMutation: (@Sendable () -> Void)? = nil,
                          reservedAttemptID: UUID? = nil,
                          pixelReadCompleted: (@Sendable (CapturePixelReceipt) -> Void)? = nil,
                          readPixels: @Sendable () async throws -> CGImage?) async rethrows -> CapturePixelImageRead? {
        let attempt = reservedAttemptID ?? UUID()
        let failure: CaptureTextReason?
        if !enabled { failure = .disabled }
        else if !AXIsProcessTrusted() { failure = .permissionUnavailable }
        else if context == nil { failure = .focusedWindowUnavailable }
        else if proof == nil { failure = .windowIdentityUnproved }
        else if !proof!.includedWindowIDs.contains(context!.windowID ?? 0) ||
            (backend == .screenCaptureKitCandidate && !proof!.privacyMaskBounds.isEmpty) { failure = .privacyMasked }
        else { failure = nil }
        if let failure {
            diagnostic?(CaptureVisibleTextDiagnostic(rejections: [:], phase: .preflight, operation: .preflight,
                nativeStatus: nil, proofFailure: nil, windowMatch: nil, visitedNodes: 0, registrations: 0, retainedRuns: 0, reasons: [failure]))
        }
        let session: CaptureAXReadSession? = failure == nil ? CaptureAXReadSession(proof: proof!, context: context!,
            observedMutation: observedMutation, diagnostic: diagnostic) : nil
        return try await withTaskCancellationHandler {
            await session?.start()
            guard !Task.isCancelled else {
                let native = await session?.finish(validPixels: false)
                if enabled { emit(native ?? .unavailable(.cancelled), observation: nil, backend: backend, outcome: outcome) }
                return nil
            }
            do {
                let start = CaptureReadStart()
                let image: CGImage?
                do { image = try await readPixels() }
                catch {
                    pixelReadCompleted?(CapturePixelReceipt(attemptID: attempt, interval: start.end()))
                    throw error
                }
                let receipt = CapturePixelReceipt(attemptID: attempt, interval: start.end())
                pixelReadCompleted?(receipt)
                let dimensionsMatch = image.map { proof == nil || ($0.width == proof!.frameWidth && $0.height == proof!.frameHeight) } ?? false
                let native = await session?.finish(validPixels: dimensionsMatch && !Task.isCancelled)
                guard let image, !Task.isCancelled,
                      receipt.interval.endedAt >= receipt.interval.startedAt,
                      receipt.interval.endedUptime >= receipt.interval.startedUptime else {
                    if enabled { emit(native ?? .unavailable(Task.isCancelled ? .cancelled : .captureFailed),
                                      observation: nil, backend: backend, outcome: outcome) }
                    return nil
                }
                guard enabled else { return CapturePixelImageRead(image: image, pixelReceipt: receipt, captureText: nil) }
                var result = native ?? .unavailable(failure ?? .captureFailed)
                if !dimensionsMatch { result = result.discarding(.invalidGeometry) }
                var observation: CaptureTextObservation? = result.observation(context: context, receipt: receipt)
                if let displayID = proof?.displayID ?? context?.displayID {
                    while true {
                        do {
                            _ = try observation!.retainedTextEncoding(frameWidth: image.width, frameHeight: image.height,
                                displayID: displayID, frameTimestamp: receipt.interval.startedAt,
                                frameMonotonicTime: receipt.interval.startedUptime, pixelReceipt: receipt, sourceContext: context)
                            break
                        } catch CaptureTextObservation.ValidationError.sizeLimit where !result.runs.isEmpty {
                            // Omit a whole native range, with an explicit budget
                            // outcome. Never clip its text or claim its old bounds.
                            result.runs.removeLast(); result.reasons.insert(.budgetExceeded)
                            observation = result.observation(context: context, receipt: receipt)
                        } catch {
                            result = result.discarding(.captureFailed)
                            let unavailable = CaptureTextObservation(captureAttemptID: receipt.attemptID, sourceContext: nil,
                                preRead: nil, pixelRead: nil, postRead: nil, availability: .unavailable,
                                reasons: [.captureFailed], consistency: nil, runs: [])
                            observation = (try? unavailable.retainedTextEncoding(frameWidth: image.width, frameHeight: image.height,
                                displayID: displayID, frameTimestamp: receipt.interval.startedAt,
                                frameMonotonicTime: receipt.interval.startedUptime, pixelReceipt: receipt, sourceContext: context)) == nil
                                ? nil : unavailable
                            break
                        }
                    }
                }
                emit(result, observation: observation, backend: backend, outcome: outcome)
                return CapturePixelImageRead(image: image, pixelReceipt: receipt, captureText: observation)
            } catch {
                session?.cancel()
                let native = await session?.finish(validPixels: false)
                if enabled { emit(native ?? .unavailable(Task.isCancelled ? .cancelled : .captureFailed),
                                  observation: nil, backend: backend, outcome: outcome) }
                throw error
            }
        } onCancel: { session?.cancel() }
    }

    private static func emit(_ result: CaptureAXReadResult, observation: CaptureTextObservation?,
                             backend: CaptureBackend, outcome: (@Sendable (CaptureTextOutcome) -> Void)?) {
        let pre = result.preRead.map { ($0.endedUptime - $0.startedUptime) * 1000 }
        let post = result.postRead.map { ($0.endedUptime - $0.startedUptime) * 1000 }
        if let pre { Log.recordLatency("capture.ax_pre", valueMs: pre, category: .capture) }
        if let post { Log.recordLatency("capture.ax_post", valueMs: post, category: .capture) }
        outcome?(CaptureTextOutcome(backend: backend, availability: observation?.availability ?? .unavailable,
            reasons: observation?.reasons ?? result.reasons.sorted { $0.rawValue < $1.rawValue },
            visitedNodes: result.visitedNodes, retainedRuns: observation?.runs.count ?? 0,
            retainedUTF16Units: observation?.runs.reduce(0, { $0 + $1.text.utf16.count }) ?? 0,
            preReadMilliseconds: pre, postReadMilliseconds: post))
    }
}

private struct CaptureReadStart {
    let date = Date()
    let uptime = ProcessInfo.processInfo.systemUptime
    func end() -> CaptureReadInterval {
        CaptureReadInterval(startedAt: date, endedAt: Date(), startedUptime: uptime,
                            endedUptime: ProcessInfo.processInfo.systemUptime)
    }
}

private struct CaptureAXReadResult: Sendable {
    var runs: [CaptureTextRun] = []
    var reasons: Set<CaptureTextReason> = []
    var visitedNodes = 0
    var preRead: CaptureReadInterval?
    var postRead: CaptureReadInterval?
    static func unavailable(_ reason: CaptureTextReason) -> Self { Self(reasons: [reason]) }
    func discarding(_ reason: CaptureTextReason) -> Self {
        var result = self; result.runs.removeAll(); result.reasons = [reason]; return result
    }
    func observation(context: ActivityContext?, receipt: CapturePixelReceipt) -> CaptureTextObservation {
        var reasons = reasons
        if runs.isEmpty, reasons.isEmpty { reasons.insert(.noVisibleText) }
        return CaptureTextObservation(captureAttemptID: receipt.attemptID, sourceContext: runs.isEmpty ? nil : context,
            preRead: preRead, pixelRead: receipt.interval, postRead: postRead,
            availability: runs.isEmpty ? .unavailable : (reasons.isEmpty ? .available : .partial),
            reasons: reasons.sorted { $0.rawValue < $1.rawValue },
            consistency: runs.isEmpty ? nil : .sameWindowBracketed, runs: runs)
    }
}

/// One native thread per bounded attempt. The enclosing source has one active
/// pixel operation, and start/stop/configuration changes join that operation.
/// Cancellation marks this session synchronously; it never abandons an AX call.
private final class CaptureAXReadSession: @unchecked Sendable {
    private let lock = NSLock()
    private let proof: CaptureTextPixelProof
    private let context: ActivityContext
    private let observedMutation: (@Sendable () -> Void)?
    private let diagnostic: (@Sendable (CaptureVisibleTextDiagnostic) -> Void)?
    private var cancelled = false
    private var finishRequest: Bool?
    private var finalResult: CaptureAXReadResult?
    private var finishWaiters: [CheckedContinuation<CaptureAXReadResult, Never>] = []
    private var runLoop: CFRunLoop?

    init(proof: CaptureTextPixelProof, context: ActivityContext, observedMutation: (@Sendable () -> Void)?,
         diagnostic: (@Sendable (CaptureVisibleTextDiagnostic) -> Void)?) {
        self.proof = proof; self.context = context; self.observedMutation = observedMutation
        self.diagnostic = diagnostic
    }
    func start() async {
        await withCheckedContinuation { ready in
            let thread = Thread { [self] in
                CaptureVisibleTextReader.noteReader(1)
                let loop = CFRunLoopGetCurrent()!
                lock.withLock { runLoop = loop }
                let reader = CaptureAXNativeReader(proof: proof, context: context,
                    observedMutation: observedMutation, diagnostic: diagnostic, isCancelled: { self.isCancelled })
                let result = reader.prepare()
                ready.resume()
                var final = result
                if !result.runs.isEmpty {
                    // Public AX notifications arrive through this owned loop
                    // while the asynchronous screenshot reads its pixels.
                    let deadline = ProcessInfo.processInfo.systemUptime + 2
                    while true {
                        let state = lock.withLock { (cancelled, finishRequest) }
                        if state.0 { final = result.discarding(.cancelled); break }
                        if let valid = state.1 {
                            final = valid ? reader.revalidate(result) : result.discarding(.captureFailed)
                            break
                        }
                        if ProcessInfo.processInfo.systemUptime >= deadline { final = result.discarding(.budgetExceeded); break }
                        CFRunLoopRunInMode(.defaultMode, 0.025, true)
                    }
                }
                reader.close()
                CaptureVisibleTextReader.noteReader(-1)
                let waiters = lock.withLock { () -> [CheckedContinuation<CaptureAXReadResult, Never>] in
                    runLoop = nil; finalResult = final
                    let waiters = finishWaiters; finishWaiters.removeAll(); return waiters
                }
                // Every native call and observer cleanup has finished here.
                for waiter in waiters { waiter.resume(returning: final) }
            }
            thread.name = "Retrace bounded visible AX"
            thread.qualityOfService = .utility
            thread.start()
        }
    }
    private var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() {
        let loop = lock.withLock { cancelled = true; return runLoop }
        if let loop { CFRunLoopWakeUp(loop) }
    }
    func finish(validPixels: Bool) async -> CaptureAXReadResult {
        await withCheckedContinuation { continuation in
            let state = lock.withLock { () -> (CaptureAXReadResult?, CFRunLoop?) in
                if let finalResult { return (finalResult, nil) }
                finishRequest = (finishRequest ?? true) && validPixels
                finishWaiters.append(continuation)
                return (nil, runLoop)
            }
            if let result = state.0 { continuation.resume(returning: result) }
            if let loop = state.1 { CFRunLoopWakeUp(loop) }
        }
    }
}

/// All fields below are confined to its AX session's native thread.
private final class CaptureAXNativeReader {
    private struct Failure: Error { let reason: CaptureTextReason }
    private struct Node {
        let element: AXUIElement
        let rawRole: String
        let rawSubrole: String?
        let bounds: CGRect
        let hidden: Bool
        let ancestors: [Int]
        let container: CaptureTextAncestorRole?
        let textRole: CaptureTextRole?
        let children: [AXUIElement]
    }
    private struct ReadRun {
        let elementIndex: Int
        let range: CFRange
        let visibleRange: CFRange
        let screenBounds: CGRect
        let text: String
    }
    private let proof: CaptureTextPixelProof
    private let context: ActivityContext
    private let isCancelled: () -> Bool
    private let mutation: CaptureAXMutationState
    private var observer: AXObserver?
    private var registrations: [(AXUIElement, CFString)] = []
    private var application: AXUIElement?
    private var window: AXUIElement?
    private var nodes: [Node] = []
    private var readRuns: [ReadRun] = []
    private var deadline = 0.0
    private var workSeconds = 0.0
    private var closed = false
    private let diagnostic: (@Sendable (CaptureVisibleTextDiagnostic) -> Void)?
    private var operation: CaptureVisibleTextDiagnostic.Operation = .contextIdentity
    private var nativeStatus: Int32?
    private var proofFailure: CaptureTextPixelProof.CurrentFailure?
    private var windowMatch: CaptureTextPixelProof.WindowMatch?
    private var rejections: [CaptureVisibleTextDiagnostic.Rejection: CaptureVisibleTextDiagnostic.RejectionCount] = [:]

    init(proof: CaptureTextPixelProof, context: ActivityContext, observedMutation: (@Sendable () -> Void)?,
         diagnostic: (@Sendable (CaptureVisibleTextDiagnostic) -> Void)?, isCancelled: @escaping () -> Bool) {
        self.proof = proof; self.context = context; self.isCancelled = isCancelled
        self.diagnostic = diagnostic
        mutation = CaptureAXMutationState(observedMutation: observedMutation)
    }

    func prepare() -> CaptureAXReadResult {
        let start = CaptureReadStart()
        deadline = start.uptime + 0.150
        var result = CaptureAXReadResult()
        do {
            try check()
            mark(.contextProcess)
            guard context.processID > 0 else { throw fail(.windowIdentityUnproved) }
            mark(.contextWindow)
            guard context.windowID.map({ $0 > 0 }) == true else { throw fail(.windowIdentityUnproved) }
            mark(.contextLifetime)
            guard context.windowGeneration?.isEmpty == false, !context.processGeneration.isEmpty else { throw fail(.windowIdentityUnproved) }
            mark(.contextDisplay)
            guard context.displayID == proof.displayID else { throw fail(.windowIdentityUnproved) }
            guard currentProofIsValid() else { throw fail(.windowIdentityUnproved) }
            let app = AXUIElementCreateApplication(context.processID); application = app
            var made: AXObserver?
            mark(.observerCreate)
            let observerStatus = AXObserverCreate(context.processID, captureVisibleTextAXCallback, &made)
            nativeStatus = observerStatus.rawValue
            guard observerStatus == .success,
                  let made else { throw fail(.mutationObserverUnavailable) }
            observer = made
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(made), .defaultMode)
            try observe(app, notifications: [kAXFocusedWindowChangedNotification])
            let focused = try element(attribute: kAXFocusedWindowAttribute, of: app)
            window = focused
            try observe(focused, notifications: [kAXTitleChangedNotification, kAXMovedNotification,
                kAXResizedNotification, kAXLayoutChangedNotification, kAXUIElementDestroyedNotification])
            try proveWindow(focused)
            try visit(focused, ancestors: [], result: &result)
            // All potentially occluding nodes are bounded before any content is
            // read. A truncated tree cannot attest earlier nodes as unobscured.
            for index in nodes.indices where nodes[index].textRole != nil {
                try readText(index, result: &result)
            }
            try check()
            guard !mutation.changed else { throw fail(.textChanged) }
            mark(.pixelInventory)
            guard currentProofIsValid() else { throw fail(.sourceChanged) }
            if result.runs.isEmpty, result.reasons.isEmpty { result.reasons.insert(.noVisibleText) }
        } catch let error as Failure { result = result.discarding(error.reason) }
        catch { result = result.discarding(.captureFailed) }
        result.visitedNodes = nodes.count
        result.preRead = start.end()
        workSeconds = result.preRead!.endedUptime - start.uptime
        report(.preparation, result: result)
        return result
    }

    func revalidate(_ prepared: CaptureAXReadResult) -> CaptureAXReadResult {
        let start = CaptureReadStart()
        deadline = start.uptime + max(0, 0.150 - workSeconds)
        var result = prepared
        do {
            try check()
            guard !mutation.changed, let app = application, let window,
                  CFEqual(try element(attribute: kAXFocusedWindowAttribute, of: app), window),
                  currentProofIsValid() else { throw fail(.sourceChanged) }
            try proveWindow(window)
            for node in nodes {
                try check()
                if let parent = node.ancestors.last {
                    guard CFEqual(try element(attribute: kAXParentAttribute, of: node.element), nodes[parent].element) else {
                        throw fail(.sourceChanged)
                    }
                }
                guard try role(of: node.element) == node.rawRole,
                      try subrole(of: node.element) == node.rawSubrole,
                      try isHidden(node.element) == node.hidden else { throw fail(.visibilityUnverified) }
                if node.hidden { continue }
                guard try rectangle(of: node.element) == node.bounds else { throw fail(.visibilityUnverified) }
                let now = try children(of: node.element, container: node.container != nil)
                guard now.count == node.children.count,
                      zip(now, node.children).allSatisfy({ CFEqual($0, $1) }) else { throw fail(.sourceChanged) }
            }
            for run in readRuns {
                let node = nodes[run.elementIndex]
                guard try sameRange(visibleRange(of: node.element), run.visibleRange),
                      try bounds(of: node.element, range: run.range) == run.screenBounds,
                      try visible(run.screenBounds, nodeIndex: run.elementIndex),
                      try text(of: node.element, range: run.range).utf16.elementsEqual(run.text.utf16) else {
                    throw fail(.textChanged)
                }
            }
            try check()
            guard !mutation.changed, currentProofIsValid() else { throw fail(.textChanged) }
        } catch let error as Failure { result = result.discarding(mutation.changed ? .textChanged : error.reason) }
        catch { result = result.discarding(.captureFailed) }
        result.postRead = start.end()
        report(.revalidation, result: result)
        return result
    }

    private func visit(_ element: AXUIElement, ancestors: [Int], result: inout CaptureAXReadResult) throws {
        try check()
        guard nodes.count < 256, ancestors.count <= 12,
              !nodes.contains(where: { CFEqual($0.element, element) }) else { throw fail(.budgetExceeded) }
        let rawRole = try role(of: element), rawSubrole = try subrole(of: element)
        var pid: pid_t = 0
        mark(.processIdentity)
        let pidStatus = AXUIElementGetPid(element, &pid); nativeStatus = pidStatus.rawValue
        guard pidStatus == .success, pid == context.processID else { throw fail(.windowIdentityUnproved) }
        if let parent = ancestors.last {
            guard CFEqual(try self.element(attribute: kAXParentAttribute, of: element), nodes[parent].element) else {
                throw fail(.windowIdentityUnproved)
            }
        }
        // These reads reveal structure/geometry only. Never read value, title,
        // description or descendants of an unknown/secure/text-field subtree.
        if try isHidden(element) {
            // Keep structural identity and explicit hidden state. Otherwise a
            // hidden sibling could become a visible occluder after pre-read and
            // remain absent from both the occlusion and revalidation inventory.
            nodes.append(Node(element: element, rawRole: rawRole, rawSubrole: rawSubrole,
                bounds: .zero, hidden: true, ancestors: ancestors, container: nil, textRole: nil, children: []))
            try observe(element, notifications: [kAXValueChangedNotification, kAXLayoutChangedNotification,
                kAXUIElementDestroyedNotification])
            return
        }
        let rect = try rectangle(of: element)
        let container = ancestorRole(rawRole)
        let safeSubrole = rawSubrole == nil ||
            (rawRole == kAXWindowRole && [kAXStandardWindowSubrole, kAXDialogSubrole, kAXFloatingWindowSubrole].contains(rawSubrole!))
        let textRole: CaptureTextRole? = !safeSubrole ? nil :
            (rawRole == kAXTextAreaRole ? .textArea : (rawRole == kAXStaticTextRole ? .staticText : nil))
        let safeContainer = safeSubrole ? container : nil
        guard !ancestors.isEmpty || safeContainer == .window else { throw fail(.windowIdentityUnproved) }
        let children = try self.children(of: element, container: safeContainer != nil)
        let index = nodes.count
        nodes.append(Node(element: element, rawRole: rawRole, rawSubrole: rawSubrole, bounds: rect,
                          hidden: false, ancestors: ancestors, container: safeContainer, textRole: textRole, children: children))
        // A system title proxy is covered by the already-observed window's
        // title/move/resize/layout notifications. Prove that public AX relation;
        // an arbitrary unobservable static-text sibling receives no exception.
        let titleProxy = try isWindowTitleProxy(element, ancestors: ancestors)
        if !titleProxy {
            try observe(element, notifications: [kAXMovedNotification, kAXResizedNotification,
                kAXUIElementDestroyedNotification, kAXLayoutChangedNotification])
        }
        if safeContainer != nil || rawRole == kAXScrollBarRole {
            try observe(element, notifications: [kAXValueChangedNotification])
        }
        if safeContainer == nil, textRole == nil {
            let category: CaptureVisibleTextDiagnostic.Rejection
            if rawSubrole == kAXSecureTextFieldSubrole { category = .secureTextField }
            else if !safeSubrole { category = .unsupportedSubrole }
            else if rawRole == kAXTextFieldRole { category = .textField }
            else if rawRole == kAXScrollBarRole { category = .scrollBar }
            else if rawRole == kAXButtonRole { category = .button }
            else { category = .unknownRole }
            noteRejection(category)
            result.reasons.insert(.unsupportedRole); return
        }
        if safeContainer != nil {
            for child in children { try visit(child, ancestors: ancestors + [index], result: &result) }
        }
    }

    private func readText(_ index: Int, result: inout CaptureAXReadResult) throws {
        let node = nodes[index]
        guard let role = node.textRole, !node.ancestors.isEmpty else { return }
        // Window chrome may expose synthetic static-text proxies without a
        // mutable text observer. The first reader admits only content nested
        // in a proved container; window titles already have their own metadata.
        guard !(role == .staticText && node.ancestors.count < 2) else {
            noteRejection(.windowChrome); result.reasons.insert(.visibilityUnverified); return
        }
        guard proof.displayBounds.intersects(node.bounds) else {
            noteRejection(.outsideDisplay); result.reasons.insert(.visibilityUnverified); return
        }
        guard node.ancestors.allSatisfy({ nodes[$0].bounds.intersects(node.bounds) }) else {
            noteRejection(.outsideAncestor); result.reasons.insert(.visibilityUnverified); return
        }
        let visible: CFRange
        do { visible = try visibleRange(of: node.element) }
        catch let failure as Failure where failure.reason == .unsupportedRange {
            noteRejection(.unsupportedVisibleRange); result.reasons.insert(.unsupportedRange); return
        }
        guard visible.length > 0 else { noteRejection(.emptyVisibleRange); return }
        let lines = try lineRanges(of: node.element, visible: visible)
        result.reasons.formUnion(lines.reasons)
        for range in lines.ranges {
            try check()
            guard result.runs.count < CaptureTextObservation.maximumRuns,
                  range.length <= CaptureTextObservation.maximumUTF16Units - result.runs.reduce(0, { $0 + $1.text.utf16.count }) else {
                result.reasons.insert(.budgetExceeded); break
            }
            let rect: CGRect
            do { rect = try bounds(of: node.element, range: range) }
            catch let failure as Failure where [.unsupportedRange, .invalidGeometry].contains(failure.reason) {
                noteRejection(.invalidRangeBounds); result.reasons.insert(failure.reason); continue
            }
            let pixelBounds: CGRect
            switch proof.pixelBounds(for: rect, context: context) {
            case .success(let bounds): pixelBounds = bounds
            case .failure(.invalidGeometry):
                noteRejection(.outsideFrameOrWindow); result.reasons.insert(.invalidGeometry); continue
            case .failure(.privacyMasked):
                noteRejection(.privacyMask); result.reasons.insert(.privacyMasked); continue
            case .failure(.occluded):
                if let windowIndex = proof.windows.firstIndex(where: { $0.id == context.windowID }) {
                    let occluders = proof.windows.prefix(windowIndex).filter { $0.bounds.intersects(rect) }
                    if occluders.contains(where: { $0.processID == context.processID }) { noteRejection(.ownedWindowOcclusion) }
                    if occluders.contains(where: { $0.processID != context.processID }) { noteRejection(.otherWindowOcclusion) }
                }
                result.reasons.insert(.occluded); continue
            }
            guard try self.visible(rect, nodeIndex: index) else { result.reasons.insert(.visibilityUnverified); continue }
            try observe(node.element, notifications: [kAXValueChangedNotification,
                kAXUIElementDestroyedNotification, kAXLayoutChangedNotification])
            let value = try text(of: node.element, range: range)
            guard value.utf16.count == range.length else { throw fail(.textChanged) }
            // Recheck role/security after the content read as well. No string
            // normalization or trimming may alter exact AX code-unit coordinates.
            guard try self.role(of: node.element) == node.rawRole,
                  try subrole(of: node.element) == node.rawSubrole else { throw fail(.sourceChanged) }
            let ancestorRoles = node.ancestors.compactMap { nodes[$0].container }
            guard ancestorRoles.count == node.ancestors.count else { throw fail(.unsupportedRole) }
            result.runs.append(CaptureTextRun(id: result.runs.count, elementOrdinal: index, text: value,
                elementUTF16Range: EvidenceUTF16Range(location: range.location, length: range.length),
                boundsInFramePixels: pixelBounds, role: role, ancestors: ancestorRoles))
            readRuns.append(ReadRun(elementIndex: index, range: range, visibleRange: visible, screenBounds: rect, text: value))
        }
    }

    private func visible(_ rect: CGRect, nodeIndex: Int) throws -> Bool {
        let node = nodes[nodeIndex]
        guard node.bounds.contains(rect) else { noteRejection(.nodeClipping); return false }
        guard node.ancestors.allSatisfy({ nodes[$0].bounds.contains(rect) }) else {
            noteRejection(.ancestorClipping); return false
        }
        // Ancestors describe clipping. Every other exposed subtree is a possible
        // in-window occluder; geometry overlap is rejected rather than guessed.
        for index in nodes.indices where index != nodeIndex && !node.ancestors.contains(index) {
            if !nodes[index].hidden, nodes[index].bounds.intersects(rect) {
                noteRejection(.siblingOcclusion); return false
            }
        }
        guard let application else { noteRejection(.hitTestUnavailable); return false }
        let points = [CGPoint(x: rect.midX, y: rect.midY),
                      CGPoint(x: rect.minX + min(0.25, rect.width / 4), y: rect.minY + min(0.25, rect.height / 4)),
                      CGPoint(x: rect.maxX - min(0.25, rect.width / 4), y: rect.maxY - min(0.25, rect.height / 4))]
        for point in points {
            try configure(application)
            var hit: AXUIElement?
            mark(.hitTest)
            let status = AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit)
            nativeStatus = status.rawValue
            guard status == .success, let hit else { noteRejection(.hitTestUnavailable); return false }
            guard CFEqual(hit, node.element) else { noteRejection(.hitTestMismatch); return false }
        }
        return true
    }

    private func isWindowTitleProxy(_ element: AXUIElement, ancestors: [Int]) throws -> Bool {
        guard ancestors.count == 1, nodes[ancestors[0]].container == .window, let window,
              let title = try optionalAttribute(kAXTitleUIElementAttribute, of: window),
              CFGetTypeID(title) == AXUIElementGetTypeID() else { return false }
        return CFEqual(element, title)
    }

    private func proveWindow(_ window: AXUIElement) throws {
        var pid: pid_t = 0
        mark(.windowProof)
        let status = AXUIElementGetPid(window, &pid); nativeStatus = status.rawValue
        guard status == .success, pid == context.processID,
              try role(of: window) == kAXWindowRole,
              let title = try attribute(kAXTitleAttribute, of: window) as? String else {
            throw fail(.windowIdentityUnproved)
        }
        let bounds = try rectangle(of: window)
        mark(.windowProof)
        windowMatch = proof.windowMatch(context: context, bounds: bounds, title: title)
        guard windowMatch == .matched else { throw fail(.windowIdentityUnproved) }
        mark(.windowLabel)
        let safe = CapturedURLPolicy.sanitizeLabel(title)
        guard safe?.utf16.elementsEqual(context.windowTitle?.utf16 ?? "".utf16) == true else {
            throw fail(.windowIdentityUnproved)
        }
        if let minimized = try optionalAttribute(kAXMinimizedAttribute, of: window) as? Bool, minimized {
            throw fail(.visibilityUnverified)
        }
    }

    private func children(of element: AXUIElement, container: Bool) throws -> [AXUIElement] {
        try configure(element)
        var count: CFIndex = 0
        mark(.childrenCount)
        let status = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
        nativeStatus = status.rawValue
        guard status == .success, count >= 0, count <= 256 else {
            throw fail(status == .success ? .budgetExceeded : .visibilityUnverified)
        }
        // An opaque subtree with unknown clipping could cover any sibling.
        // Do not retain earlier content on an incomplete occlusion inventory.
        if !container {
            guard count == 0 else { throw fail(.visibilityUnverified) }
            return []
        }
        var result: [AXUIElement] = []
        for offset in stride(from: 0, to: count, by: 16) {
            try configure(element)
            var page: CFArray?
            let size = min(16, count - offset)
            mark(.childrenPage)
            let status = AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, offset, size, &page)
            nativeStatus = status.rawValue
            guard status == .success,
                  let page, CFArrayGetCount(page) == size else { throw fail(.visibilityUnverified) }
            for index in 0..<size {
                let value = unsafeBitCast(CFArrayGetValueAtIndex(page, index), to: CFTypeRef.self)
                guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw fail(.visibilityUnverified) }
                result.append(value as! AXUIElement)
            }
        }
        return result
    }

    private func lineRanges(of element: AXUIElement, visible: CFRange) throws -> (ranges: [CFRange], reasons: Set<CaptureTextReason>) {
        let number: CFTypeRef
        do { number = try parameter(kAXLineForIndexParameterizedAttribute, of: element, value: NSNumber(value: visible.location)) }
        catch let error as Failure where error.reason == .unsupportedRange { return ([visible], []) }
        guard let number = number as? NSNumber, number.intValue >= 0 else { throw fail(.unsupportedRange) }
        var line = number.intValue
        var result: [CFRange] = []
        var reasons = Set<CaptureTextReason>()
        var lastEnd = visible.location
        while result.count < CaptureTextObservation.maximumRuns, line < Int.max {
            let value: CFTypeRef
            do { value = try parameter(kAXRangeForLineParameterizedAttribute, of: element, value: NSNumber(value: line)) }
            catch let error as Failure where error.reason == .unsupportedRange {
                if result.isEmpty { return ([visible], []) }
                noteRejection(.unsupportedLine); reasons.insert(.unsupportedRange); break
            }
            let range = try nativeRange(value)
            guard range.length > 0, range.location < visible.location + visible.length else { break }
            if range.location >= visible.location && range.location + range.length <= visible.location + visible.length {
                guard range.location >= lastEnd else { throw fail(.unsupportedRange) }
                result.append(range); lastEnd = range.location + range.length
            } else {
                noteRejection(.clippedLine); reasons.insert(.visibilityUnverified)
            }
            // A fully read visible endpoint is the stopping condition. Asking
            // AppKit for a following non-existent line returns illegalArgument;
            // that is unnecessary work, not evidence against the valid ranges.
            // A clipped terminal line also cannot lead to another visible line.
            if range.location + range.length >= visible.location + visible.length { break }
            line += 1
        }
        if result.count == CaptureTextObservation.maximumRuns, lastEnd < visible.location + visible.length {
            reasons.insert(.budgetExceeded)
        }
        return (result, reasons)
    }

    private func visibleRange(of element: AXUIElement) throws -> CFRange {
        let range = try nativeRange(attribute(kAXVisibleCharacterRangeAttribute, of: element))
        guard let count = try attribute(kAXNumberOfCharactersAttribute, of: element) as? NSNumber,
              count.intValue >= 0, range.location + range.length <= count.intValue else { throw fail(.unsupportedRange) }
        return range
    }
    private func sameRange(_ lhs: CFRange, _ rhs: CFRange) -> Bool {
        lhs.location == rhs.location && lhs.length == rhs.length
    }
    private func nativeRange(_ value: CFTypeRef) throws -> CFRange {
        var range = CFRange()
        guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .cfRange,
              AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0,
              !range.location.addingReportingOverflow(range.length).overflow else { throw fail(.unsupportedRange) }
        return range
    }
    private func bounds(of element: AXUIElement, range: CFRange) throws -> CGRect {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { throw fail(.unsupportedRange) }
        let result = try parameter(kAXBoundsForRangeParameterizedAttribute, of: element, value: value)
        var rect = CGRect.zero
        guard CFGetTypeID(result) == AXValueGetTypeID(), AXValueGetType(result as! AXValue) == .cgRect,
              AXValueGetValue(result as! AXValue, .cgRect, &rect), CaptureTextPixelProof.valid(rect) else { throw fail(.invalidGeometry) }
        return rect
    }
    private func text(of element: AXUIElement, range: CFRange) throws -> String {
        guard range.length > 0, range.length <= CaptureTextObservation.maximumUTF16Units else { throw fail(.budgetExceeded) }
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { throw fail(.unsupportedRange) }
        let raw = try parameter(kAXStringForRangeParameterizedAttribute, of: element, value: value)
        guard CFGetTypeID(raw) == CFStringGetTypeID(), CFStringGetLength(raw as! CFString) == range.length,
              let string = raw as? String else { throw fail(.unsupportedRange) }
        return string
    }
    private func rectangle(of element: AXUIElement) throws -> CGRect {
        let position = try attribute(kAXPositionAttribute, of: element), size = try attribute(kAXSizeAttribute, of: element)
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else {
            throw fail(.invalidGeometry)
        }
        let result = CGRect(origin: point, size: dimensions)
        guard CaptureTextPixelProof.valid(result) else { throw fail(.invalidGeometry) }
        return result
    }
    private func role(of element: AXUIElement) throws -> String {
        guard let role = try attribute(kAXRoleAttribute, of: element) as? String, role.utf8.count <= 64 else { throw fail(.unsupportedRole) }
        return role
    }
    private func subrole(of element: AXUIElement) throws -> String? {
        guard let value = try optionalAttribute(kAXSubroleAttribute, of: element) else { return nil }
        guard let subrole = value as? String, subrole.utf8.count <= 128 else { throw fail(.unsupportedRole) }
        return subrole
    }
    private func isHidden(_ element: AXUIElement) throws -> Bool {
        // AXHidden is not a general required node attribute. Absence is not a
        // visibility grant: range geometry, ancestors, occluders and hit tests
        // must independently prove visibility before a content read.
        guard let value = try optionalAttribute(kAXHiddenAttribute, of: element) else { return false }
        guard CFGetTypeID(value) == CFBooleanGetTypeID(), let hidden = value as? Bool else {
            throw fail(.visibilityUnverified)
        }
        return hidden
    }
    private func ancestorRole(_ role: String) -> CaptureTextAncestorRole? {
        switch role {
        case kAXWindowRole: return .window
        case kAXGroupRole: return .group
        case kAXSplitGroupRole: return .splitGroup
        case kAXScrollAreaRole: return .scrollArea
        case "AXWebArea": return .webArea
        case kAXSheetRole: return .sheet
        case kAXTabGroupRole: return .tabGroup
        default: return nil
        }
    }
    private func element(attribute name: String, of element: AXUIElement) throws -> AXUIElement {
        let value = try attribute(name, of: element)
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw fail(.windowIdentityUnproved) }
        return value as! AXUIElement
    }
    private func attribute(_ name: String, of element: AXUIElement) throws -> CFTypeRef {
        guard let value = try optionalAttribute(name, of: element) else { throw fail(.unsupportedRange) }
        return value
    }
    private func optionalAttribute(_ name: String, of element: AXUIElement) throws -> CFTypeRef? {
        try configure(element)
        var value: CFTypeRef?
        mark(Self.operation(for: name))
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        nativeStatus = status.rawValue
        if status == .attributeUnsupported || status == .noValue { return nil }
        guard status == .success else { throw fail(.visibilityUnverified) }
        return value
    }
    private func parameter(_ name: String, of element: AXUIElement, value: CFTypeRef) throws -> CFTypeRef {
        try configure(element)
        var result: CFTypeRef?
        mark(Self.operation(for: name))
        let status = AXUIElementCopyParameterizedAttributeValue(element, name as CFString, value, &result)
        nativeStatus = status.rawValue
        guard status == .success, let result else { throw fail(status == .parameterizedAttributeUnsupported ? .unsupportedRange : .visibilityUnverified) }
        return result
    }
    private func configure(_ element: AXUIElement) throws {
        try check()
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        mark(.messagingTimeout)
        guard remaining > 0 else { throw fail(.budgetExceeded) }
        let status = AXUIElementSetMessagingTimeout(element, Float(min(0.025, remaining)))
        nativeStatus = status.rawValue
        guard status == .success else {
            throw fail(.budgetExceeded)
        }
    }
    private func observe(_ element: AXUIElement, notifications: [String]) throws {
        guard let observer else { throw fail(.mutationObserverUnavailable) }
        for notification in notifications {
            try configure(element)
            if registrations.contains(where: { CFEqual($0.0, element) && ($0.1 as String) == notification }) { continue }
            mark(.observerAdd)
            guard registrations.count < 1_024 else { throw fail(.mutationObserverUnavailable) }
            let status = AXObserverAddNotification(observer, element, notification as CFString,
                Unmanaged.passUnretained(mutation).toOpaque())
            nativeStatus = status.rawValue
            guard status == .success else { throw fail(.mutationObserverUnavailable) }
            registrations.append((element, notification as CFString))
        }
    }
    private func check() throws {
        guard !isCancelled() else { throw fail(.cancelled) }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw fail(.budgetExceeded) }
        // Drain already-delivered native signals before and after AX messages.
        // Public APIs still cannot prove absence of an undelivered future signal.
        for _ in 0..<32 {
            if CFRunLoopRunInMode(.defaultMode, 0, true) != .handledSource { break }
        }
        guard !mutation.changed else { throw fail(.textChanged) }
    }
    private func currentProofIsValid() -> Bool {
        mark(.pixelInventory)
        proofFailure = proof.currentFailure()
        return proofFailure == nil
    }
    private func mark(_ value: CaptureVisibleTextDiagnostic.Operation) {
        operation = value; nativeStatus = nil
    }
    private func noteRejection(_ reason: CaptureVisibleTextDiagnostic.Rejection) {
        guard diagnostic != nil else { return }
        rejections[reason] = .init(count: min(256, (rejections[reason]?.count ?? 0) + 1),
                                  operation: operation, nativeStatus: nativeStatus)
    }
    private func report(_ phase: CaptureVisibleTextDiagnostic.Phase, result: CaptureAXReadResult) {
        diagnostic?(CaptureVisibleTextDiagnostic(rejections: rejections, phase: phase, operation: operation, nativeStatus: nativeStatus,
            proofFailure: proofFailure, windowMatch: windowMatch,
            visitedNodes: nodes.count, registrations: registrations.count, retainedRuns: result.runs.count,
            reasons: result.reasons.sorted { $0.rawValue < $1.rawValue }))
    }
    private static func operation(for name: String) -> CaptureVisibleTextDiagnostic.Operation {
        switch name {
        case kAXFocusedWindowAttribute: return .focusedWindow
        case kAXRoleAttribute: return .role
        case kAXSubroleAttribute: return .subrole
        case kAXParentAttribute: return .parent
        case kAXPositionAttribute: return .position
        case kAXSizeAttribute: return .size
        case kAXHiddenAttribute: return .hidden
        case kAXTitleAttribute: return .title
        case kAXTitleUIElementAttribute: return .titleElement
        case kAXMinimizedAttribute: return .minimized
        case kAXVisibleCharacterRangeAttribute: return .visibleRange
        case kAXNumberOfCharactersAttribute: return .characterCount
        case kAXLineForIndexParameterizedAttribute: return .lineForIndex
        case kAXRangeForLineParameterizedAttribute: return .rangeForLine
        case kAXBoundsForRangeParameterizedAttribute: return .boundsForRange
        case kAXStringForRangeParameterizedAttribute: return .stringForRange
        default: return .attribute
        }
    }
    private func fail(_ reason: CaptureTextReason) -> Failure { Failure(reason: reason) }
    func close() {
        guard !closed else { return }; closed = true
        if let observer {
            for (element, notification) in registrations { AXObserverRemoveNotification(observer, element, notification) }
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        registrations.removeAll(); observer = nil
    }
}

private final class CaptureAXMutationState {
    var changed = false // Only the owned observer's native run loop accesses this.
    let observedMutation: (@Sendable () -> Void)?
    init(observedMutation: (@Sendable () -> Void)?) { self.observedMutation = observedMutation }
    func note() { changed = true; observedMutation?() }
}
private func captureVisibleTextAXCallback(_ observer: AXObserver, _ element: AXUIElement,
                                         _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<CaptureAXMutationState>.fromOpaque(refcon).takeUnretainedValue().note()
}
