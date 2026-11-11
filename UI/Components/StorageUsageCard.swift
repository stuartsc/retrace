import SwiftUI
import Shared
import App

/// Only cached snapshots are read by this view. Directory traversal belongs to
/// the App-owned periodic service, including when this view is not on screen.
struct StorageUsageCard: View {
    let coordinator: AppCoordinator
    @State private var snapshot = StorageUsageSnapshot()
    @State private var refreshing = false

    private var report: StorageUsageReport? {
        snapshot.latestReport?.isComplete == true ? snapshot.latestReport
            : (snapshot.lastCompleteReport ?? snapshot.latestReport)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Storage breakdown", systemImage: "externaldrive")
                    .font(.headline)
                Spacer()
                Button("Refresh now") {
                    refreshing = true
                    Task {
                        snapshot = await coordinator.refreshStorageUsage()
                        refreshing = false
                    }
                }
                .disabled(refreshing || snapshot.isScanning || snapshot.isClosed)
            }
            if let report {
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.bytes(report.total.allocatedBytes))
                        .font(.title2.bold())
                    Text("allocated file space • \(Self.bytes(report.total.logicalBytes)) logical")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                    ForEach(StorageUsageCategory.allCases, id: \.rawValue) { category in
                        if let amount = report.categories[category], amount.fileCount > 0 {
                            GridRow {
                                Text(Self.label(category))
                                Text(Self.bytes(amount.allocatedBytes)).monospacedDigit()
                                    .gridColumnAlignment(.trailing)
                                Text("\(amount.fileCount.formatted()) files")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                ForEach(report.volumes, id: \.deviceID) { volume in
                    Text("Volume free space: \(Self.bytes(volume.availableBytes)) of \(Self.bytes(volume.totalBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Updated \(report.finishedAt.formatted(date: .abbreviated, time: .shortened)). Checked every 15 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Shared APFS blocks can appear in several files. Allocated totals are not a promise of space recovered by deletion.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(snapshot.isScanning ? "Measuring storage…" : "Storage has not been measured yet.")
                    .foregroundStyle(.secondary)
            }
            if snapshot.isScanning { ProgressView("Updating storage totals…").controlSize(.small) }
            if let latest = snapshot.latestReport, !latest.isComplete {
                Text(snapshot.lastCompleteReport == nil
                     ? "Incomplete measurement: some locations could not be counted. These totals are partial."
                     : "The latest check was incomplete. Showing the last complete measurement.")
                    .font(.caption).foregroundStyle(.orange)
                ForEach(latest.roots.filter { $0.status == .partial || $0.status == .unavailable }, id: \.rootID) { root in
                    Text("\(Self.rootLabel(root.rootID)): \(root.status.rawValue)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.retraceCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task {
            while !Task.isCancelled {
                snapshot = await coordinator.storageUsageSnapshot()
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .binary)
    }

    private static func rootLabel(_ id: String) -> String {
        switch id {
        case "native": return "Recording library"
        case "backups": return "Backups"
        case "candidates": return "Candidate copies"
        case "imported": return "Imported Rewind history"
        case "selectedLocalModel": return "Selected local model"
        case "nativeLogs": return "Diagnostic logs"
        case "nativeCaches": return "Timeline and application caches"
        case "searchThumbnails": return "Search thumbnails"
        case "searchResults": return "Cached search results"
        case "otherApps": return "Cached application list"
        default: return "Storage location"
        }
    }

    private static func label(_ category: StorageUsageCategory) -> String {
        switch category {
        case .screenVideo: return "Screen recordings"
        case .audio: return "Audio recordings"
        case .database: return "Database and SQLite journals"
        case .originals: return "Originals awaiting processing"
        case .indexes: return "Search indexes"
        case .models: return "Local models"
        case .caches: return "Caches and temporary files"
        case .logs: return "Logs"
        case .backups: return "Backup copies"
        case .candidates: return "Candidate copies and validation"
        case .imported: return "Imported Rewind history"
        case .other: return "Other files"
        }
    }
}
