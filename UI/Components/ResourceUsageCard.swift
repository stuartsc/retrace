import SwiftUI
import Shared

struct ResourceUsageCard: View {
    let usage: ResourceUsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Retrace CPU", systemImage: "cpu").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 12) {
                reading("Now", value: usage.isCurrent ? usage.cpuPercent : nil)
                reading("1-minute average", value: usage.oneMinute.cpuPercent)
                reading("15-minute average", value: usage.fifteenMinutes.cpuPercent)
                reading("15-minute peak", value: usage.fifteenMinutes.peakCPUPercent)
            }
            Text("100% = one logical core. Active-use target: 20%; short operations can exceed it.")
                .font(.caption).foregroundStyle(.secondary)
            if let system = usage.systemCPUPercent, usage.isCurrent {
                Text("Whole Mac: \(system.formatted(.number.precision(.fractionLength(1))))% of all cores")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Sampling coverage: \((usage.oneMinute.coverage * 100).formatted(.number.precision(.fractionLength(0))))% across \(usage.oneMinute.elapsedSeconds.formatted(.number.precision(.fractionLength(0)))) observed seconds in the 1-minute window; \((usage.fifteenMinutes.coverage * 100).formatted(.number.precision(.fractionLength(0))))% across \(usage.fifteenMinutes.elapsedSeconds.formatted(.number.precision(.fractionLength(0)))) seconds in the 15-minute window.")
                .font(.caption).foregroundStyle(.secondary)
            if !usage.isCurrent {
                Text("Waiting for current CPU measurements. Missing samples are not counted as idle time.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("App CPU excludes shared macOS services. Whole-system energy is not measured here.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.retraceCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func reading(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { "\($0.formatted(.number.precision(.fractionLength(1))))%" } ?? "—")
                .font(.title3.monospacedDigit())
        }
    }
}
