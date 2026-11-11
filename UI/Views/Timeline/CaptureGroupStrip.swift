import App
import Shared
import SwiftUI

/// Companion displays come only from durable sampling receipts. Similar samples
/// retain their earlier source time; proximity never invents a relationship.
struct CaptureGroupStrip: View {
    let coordinator: AppCoordinator
    @ObservedObject var model: UnifiedWorkspaceModel
    let onSelect: @MainActor (ScreenEvidenceRef) async -> Void
    @State private var snapshot: CaptureGroupSnapshot?
    @State private var admitted: WorkspaceSelectionAdmission?
    @State private var unavailable = false

    var body: some View {
        Group {
            if let current = model.selectionAdmission, current == admitted, let snapshot {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(snapshot.members.enumerated()), id: \.element.target.attemptID) { index, member in
                            Button {
                                Task {
                                    guard model.admits(current), case .screen(let selected) = current.reference else { return }
                                    do {
                                        let target = try await coordinator.capturedMomentTarget(for: selected,
                                            attemptID: member.target.attemptID)
                                        guard model.admits(current), !Task.isCancelled, let reference = target else { return }
                                        await onSelect(reference)
                                    } catch {
                                        guard model.admits(current), admitted == current else { return }
                                        self.snapshot = nil; unavailable = true
                                    }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Label("Display \(index + 1)", systemImage: "display")
                                        .font(.caption.bold())
                                    Text(member.outcome?.comparison?.method == .exactPixelsV1 && member.state == .similar
                                         ? "Unchanged · image reused" : label(member.state)).font(.caption2)
                                    if member.outcome?.comparison?.method == .exactPixelsV1,
                                       let checked = member.outcome?.pixelReceipt?.interval.endedAt {
                                        Text("Confirmed \(checked.formatted(date: .omitted, time: .standard))")
                                            .font(.caption2.monospacedDigit())
                                    }
                                    if let at = member.evidenceTimestamp {
                                        Text("Image \(at.formatted(date: .omitted, time: .standard))")
                                            .font(.caption2.monospacedDigit())
                                    }
                                }.padding(8).frame(minWidth: 116, alignment: .leading)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain).disabled(member.reference == nil)
                            .accessibilityIdentifier("workspace.display.\(index)")
                            .accessibilityLabel("Display \(index + 1), \(label(member.state))")
                        }
                    }
                }.scrollIndicators(.hidden)
                Text("Each display has its own sample time.").font(.caption2).foregroundStyle(.secondary)
            } else if unavailable {
                Text("Display details are unavailable for this moment.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task(id: model.selectionAdmission) {
            snapshot = nil; admitted = nil; unavailable = false
            guard let admission = model.selectionAdmission, case .screen(let reference) = admission.reference else { return }
            while model.admits(admission), !Task.isCancelled {
                do {
                    let result = try await coordinator.capturedMoment(for: reference)
                    guard model.admits(admission), !Task.isCancelled else { return }
                    if let result { try await coordinator.revalidateCapturedMoment(result.stamp) }
                    guard model.admits(admission), !Task.isCancelled else { return }
                    snapshot = result; admitted = admission; unavailable = false
                    // Old/imported evidence has no group to keep refreshing.
                    if result == nil { return }
                } catch {
                    guard model.admits(admission), !Task.isCancelled else { return }
                    snapshot = nil; unavailable = true
                }
                // Pending retention/deletion can change without moving a pinned
                // selection. The view owns and cancels this one bounded reader.
                do { try await Task.sleep(for: .seconds(2), clock: .continuous) }
                catch { return }
            }
        }
    }

    private func label(_ state: CaptureGroupRetentionState) -> String {
        switch state {
        case .stored: return "Recorded"
        case .similar: return "Similar · earlier sample"
        case .pending: return "Retention pending"
        case .deleted: return "Deleted"
        case .excluded: return "Unavailable under current settings"
        case .interrupted: return "Capture interrupted"
        case .unavailable: return "Capture unavailable"
        case .dropped: return "Capture gap"
        case .cancelled: return "Capture stopped"
        }
    }
}
