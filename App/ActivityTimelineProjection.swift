import Foundation
import Shared

/// Rebuildable local presentation, separate from captured facts and downstream acknowledgements.
public enum ActivityTimelineProjection {
    public static func build(events: [PersistedActivityEvent], corrections: [ActivityCorrectionReceipt] = [],
                             grouped: Bool = true) -> [ActivityEpisode] {
        let ordered = events.sorted { $0.commitSequence < $1.commitSequence }
        let revoked = Set(corrections.filter { $0.command.confirmed && [.pending, .applied].contains($0.status) }
            .compactMap { $0.command.action == .revoke ? $0.command.revokesCommandID : nil })
        let accepted = corrections.filter {
            $0.command.confirmed && [.pending, .applied].contains($0.status) && !revoked.contains($0.command.id)
        }.sorted { $0.revision < $1.revision }
        let annotations = accepted.filter { [.hide, .rename, .assignProject].contains($0.command.action) }
            .map { (receipt: $0, targets: Set($0.command.targetEventIDs)) }
        func annotationIDs(eventIDs: [UUID], context: ActivityContext?) -> [UUID] {
            annotations.compactMap { annotation in
                let command = annotation.receipt.command
                let selected = eventIDs.contains(where: annotation.targets.contains)
                let reusable = annotation.receipt.status == .applied && command.scope == .document
                    && command.documentKey != nil && context?.stableDocumentKey == command.documentKey
                return selected || reusable ? command.id : nil
            }
        }
        var rows: [IntervalBuilder] = []
        var previous: PersistedActivityEvent?
        for stored in ordered {
            let event = stored.event
            let contiguous = previous.map { $0.event.sessionID == event.sessionID && $0.event.sequence + 1 == event.sequence
                && event.monotonicTime >= $0.event.monotonicTime } ?? true
            // A later document/pane sample starts its own interval. It may confirm
            // prior window focus, but cannot backdate newly observed identity.
            let currentEnrichment: Bool
            if event.kind == .enrichment, let related = event.relatedEventID,
               let last = rows.last, last.eventIDs.contains(related),
               let prior = last.context, let current = event.context {
                currentEnrichment = prior.processID == current.processID
                    && prior.processGeneration == current.processGeneration
                    && prior.windowID != nil && prior.windowID == current.windowID
                    && prior.windowGeneration != nil && prior.windowGeneration == current.windowGeneration
                    && prior.displayID == current.displayID
            } else { currentEnrichment = false }
            if let last = rows.last, let prior = previous {
                let gap = event.monotonicTime - prior.event.monotonicTime
                let knownTransition = contiguous && gap <= 35
                    && ([.focus, .reconciliation, .heartbeat, .pause, .sleep, .shutdown, .excluded].contains(event.kind) || currentEnrichment)
                if last.context == nil {
                    rows[rows.count - 1].endedAt = max(last.startedAt, event.observedAt)
                } else if knownTransition {
                    rows[rows.count - 1].focusDuration += max(0, event.monotonicTime - last.lastMonotonic)
                    rows[rows.count - 1].lastMonotonic = event.monotonicTime
                    rows[rows.count - 1].endedAt = max(last.startedAt, last.startedAt.addingTimeInterval(rows[rows.count - 1].focusDuration))
                }
                if !knownTransition && last.context != nil && event.kind != .gap {
                    rows.append(.unknown(between: last.endedAt, and: event.observedAt, following: stored))
                }
            }
            if event.kind == .heartbeat, contiguous, let last = rows.last, last.context == event.context,
               annotationIDs(eventIDs: last.eventIDs, context: last.context)
                == annotationIDs(eventIDs: [event.id], context: event.context) {
                rows[rows.count - 1].eventIDs.append(event.id)
            } else {
                let start: Date
                if event.kind == .gap, let last = rows.last { start = min(last.endedAt, event.observedAt) }
                else { start = event.observedAt }
                rows.append(IntervalBuilder(id: event.id, storeID: stored.storeID, eventIDs: [event.id],
                    context: event.context, coverage: event.coverage, startedAt: start,
                    endedAt: max(start, event.observedAt), focusDuration: 0, lastMonotonic: event.monotonicTime))
            }
            previous = stored
        }

        let separated = Set(accepted.filter { $0.command.action == .separate }.flatMap { $0.command.targetEventIDs })
        var groups: [[ActivityInterval]] = []
        for row in rows {
            let interval = row.interval
            if grouped, let key = interval.context?.stableDocumentKey,
               !interval.eventIDs.contains(where: separated.contains),
               let match = groups.lastIndex(where: { $0.first?.context?.stableDocumentKey == key }),
               let end = groups[match].last?.endedAt,
               interval.startedAt.timeIntervalSince(end) <= 60,
               groups[match...].flatMap({ $0 }).allSatisfy({ $0.context != nil && ![.unknown, .paused, .sleeping, .excluded, .stopped].contains($0.coverage)
                   && !$0.eventIDs.contains(where: separated.contains) }) {
                let joined = groups[match...].flatMap { $0 } + [interval]
                groups.replaceSubrange(match..., with: [joined])
            } else { groups.append([interval]) }
        }
        // Explicit selected-scope grouping preserves every intervening interval and unknown gap.
        if grouped {
            for receipt in accepted where receipt.command.action == .group && receipt.command.scope == .selection {
                let targets = Set(receipt.command.targetEventIDs)
                let indexes = groups.indices.filter { groups[$0].contains { !$0.eventIDs.allSatisfy({ !targets.contains($0) }) } }
                if let first = indexes.first, let last = indexes.last, first < last {
                    groups.replaceSubrange(first...last, with: [groups[first...last].flatMap { $0 }])
                }
            }
        }
        // Presentation corrections affect only their confirmed scope. Split at
        // annotation boundaries even when document continuity or an explicit
        // grouping command joined the surrounding observations.
        groups = groups.flatMap { intervals -> [[ActivityInterval]] in
            var runs: [[ActivityInterval]] = []
            var previousAnnotations: [UUID]?
            for interval in intervals {
                let current = annotationIDs(eventIDs: interval.eventIDs, context: interval.context)
                if current == previousAnnotations {
                    runs[runs.count - 1].append(interval)
                } else {
                    runs.append([interval])
                    previousAnnotations = current
                }
            }
            return runs
        }
        let revision = ordered.last?.commitSequence ?? 0
        return groups.compactMap { intervals in
            guard let first = intervals.first else { return nil }
            let ids = Set(intervals.flatMap(\.eventIDs))
            var title = first.context?.windowTitle ?? first.context?.appName ?? first.coverage.rawValue.capitalized
            var hidden = false
            var pending: [UUID] = []
            var classification = intervals.count > 1 ? "Local document identity; inferred continuity" : "Observed activity; unclassified"
            // Exact selected observations override inherited document mappings,
            // even when the reusable rule was acknowledged more recently.
            let applicable = accepted.sorted { lhs, rhs in
                let leftSelected = !ids.isDisjoint(with: lhs.command.targetEventIDs)
                let rightSelected = !ids.isDisjoint(with: rhs.command.targetEventIDs)
                if leftSelected != rightSelected { return !leftSelected }
                return lhs.revision < rhs.revision
            }
            for receipt in applicable where receipt.command.action != .revoke {
                let command = receipt.command
                let selected = !ids.isDisjoint(with: command.targetEventIDs)
                let reusable = receipt.status == .applied && command.scope == .document && command.documentKey != nil
                    && intervals.contains { $0.context?.stableDocumentKey == command.documentKey }
                guard selected || reusable else { continue }
                if receipt.status == .pending { pending.append(command.id) }
                if [.rename, .assignProject].contains(command.action), let label = command.label { title = label }
                if command.action == .hide { hidden = true }
                classification = receipt.status == .pending ? "Confirmed correction pending application" : "User-confirmed correction"
            }
            return ActivityEpisode(id: first.id, revision: revision, title: title, intervals: intervals,
                                   classification: classification, pendingCorrectionIDs: pending, hidden: hidden)
        }
    }

    private struct IntervalBuilder {
        var id: UUID
        var storeID: UUID
        var eventIDs: [UUID]
        var context: ActivityContext?
        var coverage: ActivityCoverage
        var startedAt: Date
        var endedAt: Date
        var focusDuration: TimeInterval
        var lastMonotonic: TimeInterval
        var interval: ActivityInterval {
            .init(id: id, storeID: storeID, eventIDs: eventIDs, context: context, coverage: coverage,
                  startedAt: startedAt, endedAt: endedAt, focusDuration: focusDuration)
        }
        static func unknown(between start: Date, and end: Date, following: PersistedActivityEvent) -> Self {
            // A deterministic gap identity cannot collide with a retained event ID in this projection.
            var bytes = following.id.uuid
            bytes.0 ^= 0xFF; bytes.15 ^= 0xFF
            return .init(id: UUID(uuid: bytes), storeID: following.storeID, eventIDs: [], context: nil,
                         coverage: .unknown, startedAt: start, endedAt: max(start, end), focusDuration: 0,
                         lastMonotonic: following.event.monotonicTime)
        }
    }
}
