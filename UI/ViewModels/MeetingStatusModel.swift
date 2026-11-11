import App
import Combine
import Foundation

/// Schedules expiry independently of slower source polling. SwiftUI only reads
/// published values; no native/system lookup belongs to a view's body.
@MainActor
final class MeetingStatusModel: ObservableObject {
    @Published private(set) var snapshot: MeetingHealthSnapshot?
    @Published private(set) var summary = "Call state unavailable"
    private var expiry: Task<Void, Never>?
    private var generation = UUID()

    func update(_ snapshot: MeetingHealthSnapshot) {
        expiry?.cancel(); generation = UUID()
        self.snapshot = snapshot
        let uptime = ProcessInfo.processInfo.systemUptime
        summary = snapshot.summary(at: uptime)
        guard snapshot.monitoring, let assessment = snapshot.assessment,
              assessment.isFresh(at: uptime) else { return }
        let delay = assessment.validUntilUptime - uptime
        guard delay.isFinite, (0...60).contains(delay) else { summary = "Call state unavailable"; return }
        let token = generation
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay), clock: .continuous) }
            catch { return }
            guard let self, !Task.isCancelled, generation == token else { return }
            // The lease has ended; do not wait for another view render or poll.
            summary = "Call state unavailable"
            expiry = nil
        }
    }

    func close() {
        generation = UUID(); expiry?.cancel(); expiry = nil
        snapshot = nil; summary = "Call state unavailable"
    }

    deinit { expiry?.cancel() }
}
