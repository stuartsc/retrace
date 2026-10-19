import Foundation

/// One native timer shared by initial capture and window-change rescheduling.
@MainActor
enum CapturePollingTimer {
    static func schedule(interval: TimeInterval, tick: @escaping @Sendable () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in tick() }
        // The default mode pauses while AppKit tracks menus and mouse input.
        // Capture keeps its existing cadence and admission checks in those modes.
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
