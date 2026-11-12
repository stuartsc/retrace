import AppKit
import Foundation
import XCTest

/// Starts AppKit from a native run-loop callback after an opt-in async test
/// suspends, so a running MainActor job does not surround NSApp.run. The calling
/// test owns its private window and readiness assertions. A command-level
/// watchdog must also bound a stalled native menu/event loop. No keyboard or
/// mouse events are synthesized, consumed, or redirected by this helper.
@MainActor
final class NativeAppKitObservationLoop: NSObject {
    private let wake: NSEvent
    private let activate: () -> Void
    private let verifyReadiness: () -> Void
    private let finished: () -> Void
    private let duration: TimeInterval
    private var timers: [Timer] = []
    private(set) var checkedReadiness = false
    private(set) var deadlineReached = false
    private(set) var returnedFromRun = false

    init(wake: NSEvent, activate: @escaping () -> Void,
         verifyReadiness: @escaping () -> Void, finished: @escaping () -> Void,
         duration: TimeInterval = 90) {
        self.wake = wake; self.activate = activate
        self.verifyReadiness = verifyReadiness; self.finished = finished
        self.duration = duration
    }

    func schedule() { addTimer(after: 0.01, selector: #selector(run(_:))) }

    private func addTimer(after interval: TimeInterval, selector: Selector) {
        let timer = Timer(timeInterval: interval, target: self, selector: selector, userInfo: nil, repeats: false)
        timers.append(timer)
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func run(_ timer: Timer) {
        guard !NSApp.isRunning else {
            XCTFail("The isolated native diagnostic must own its AppKit run loop")
            finished()
            return
        }
        addTimer(after: 0.5, selector: #selector(checkReadiness(_:)))
        addTimer(after: duration, selector: #selector(stop(_:)))
        activate()
        NSApp.run()
        returnedFromRun = true
        invalidateTimers()
        finished()
    }

    @objc private func checkReadiness(_ timer: Timer) {
        checkedReadiness = true
        verifyReadiness()
    }

    @objc private func stop(_ timer: Timer) {
        deadlineReached = true
        NSApp.stop(nil)
        // stop() takes effect after the current event is processed. This neutral
        // application event wakes nextEvent without performing a user action.
        NSApp.postEvent(wake, atStart: true)
    }

    func invalidateTimers() {
        timers.forEach { $0.invalidate() }
        timers.removeAll()
    }
}
