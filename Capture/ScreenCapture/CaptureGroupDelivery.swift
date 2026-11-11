import Foundation
import Shared

/// The source and manager share this bounded, awaited delivery owner. Candidate
/// acknowledgement precedes pixel forwarding; sampling-ended is independent of
/// the member's downstream decision. There is no lossy event queue or task per
/// event. App alone finalizes candidates that have crossed the output stream.
actor CaptureGroupDelivery {
    private enum State { case pending, candidate(CapturePixelReceipt), writing, resolved, forwarded }
    private struct Entry {
        let group: CaptureSamplingGroup
        var members: [UUID: State]
        let beginEvent: CaptureGroupEvent
        var beginAcknowledged = false
        var failedWrites: [UUID: CaptureGroupEvent] = [:]
        var pendingEnd: CaptureGroupEvent?
        var samplingEnded = false
    }
    private let journal: any CaptureGroupJournalProtocol
    private let maximumGroups: Int
    private var groups: [UUID: Entry] = [:]

    init(journal: any CaptureGroupJournalProtocol, maximumGroups: Int = 8) {
        self.journal = journal
        self.maximumGroups = min(max(maximumGroups, 1), 8)
    }

    func begin(_ group: CaptureSamplingGroup) async throws {
        guard groups.count < maximumGroups else { throw CaptureGroupJournalError.capacityExceeded }
        guard groups[group.groupID] == nil else { throw CaptureGroupJournalError.invalidTransition }
        let event = CaptureGroupEvent(payload: .began(group))
        _ = try event.validatedEncoding()
        groups[group.groupID] = Entry(group: group,
            members: Dictionary(uniqueKeysWithValues: group.targets.map { ($0.attemptID, .pending) }), beginEvent: event)
        try await journal.appendCaptureGroupEvent(event)
        groups[group.groupID]?.beginAcknowledged = true
    }

    func candidate(_ member: CaptureGroupFrameReceipt, receipt: CapturePixelReceipt) async throws {
        try await append(.init(member: member, disposition: .retainedCandidate, pixelReceipt: receipt))
    }

    func terminal(_ outcome: CaptureAttemptOutcome) async throws {
        guard outcome.disposition != .retainedCandidate, outcome.disposition != .suppressedSimilar else {
            throw CaptureGroupJournalError.invalidTransition
        }
        try await append(outcome)
    }

    /// A missing/deleted prior admission is recoverable: the caller still owns
    /// freshly read current pixels and retains them instead of inventing a link.
    func suppress(_ member: CaptureGroupFrameReceipt, receipt: CapturePixelReceipt,
                  reference: CaptureAttemptReference, comparison: CaptureSimilarityComparison) async throws -> Bool {
        do {
            try await append(.init(member: member, disposition: .suppressedSimilar,
                pixelReceipt: receipt, similarReference: reference, comparison: comparison))
            return true
        } catch CaptureGroupJournalError.referenceUnavailable { return false }
    }

    /// Exact cached evidence can belong to a pruned group. Its durable validation
    /// happens in the canonical journal; this checks only the current handoff.
    func forwarded(_ member: CaptureGroupFrameReceipt) throws {
        guard let entry = groups[member.groupID], let state = entry.members[member.attemptID],
              let target = entry.group.targets.first(where: { $0.attemptID == member.attemptID }),
              member == CaptureGroupFrameReceipt(group: entry.group, target: target),
              case .candidate = state else {
            throw CaptureGroupJournalError.invalidTransition
        }
        groups[member.groupID]?.members[member.attemptID] = .forwarded
        prune(member.groupID)
    }

    func samplingEnded(_ group: CaptureSamplingGroup, reason: CaptureSamplingEndReason) async throws {
        guard let entry = groups[group.groupID], entry.group == group, !entry.samplingEnded else {
            throw CaptureGroupJournalError.invalidTransition
        }
        let event = CaptureGroupEvent(payload: .samplingEnded(.init(groupID: group.groupID,
            sessionID: group.sessionID, reason: reason)))
        _ = try event.validatedEncoding(group: group)
        groups[group.groupID]?.pendingEnd = event
        try await journal.appendCaptureGroupEvent(event)
        groups[group.groupID]?.pendingEnd = nil
        groups[group.groupID]?.samplingEnded = true
        prune(group.groupID)
    }

    /// Called by the one joined source cycle. Do not cancel candidates already
    /// queued for the manager; only unresolved, never-read targets remain here.
    func cancelPending(in group: CaptureSamplingGroup, reason: CaptureGroupOutcomeReason,
                       receipts: [UUID: CapturePixelReceipt] = [:]) async throws {
        for target in group.targets {
            guard let state = groups[group.groupID]?.members[target.attemptID], case .pending = state else { continue }
            try await terminal(.init(member: .init(group: group, target: target), disposition: .cancelled,
                reason: reason, pixelReceipt: receipts[target.attemptID]))
        }
    }

    /// Stop joins source and forwarding before calling this. Forwarded members
    /// never receive a Capture cancellation, even if App has not stored them yet.
    func cancelUnforwarded(reason: CaptureGroupOutcomeReason) async throws {
        let descriptors = groups.values.map(\.group)
        var firstFailure: (any Error)?
        for group in descriptors {
            do {
                try await retryFailedAcknowledgements(in: group.groupID)
                for target in group.targets {
                    let receipt: CapturePixelReceipt?
                    switch groups[group.groupID]?.members[target.attemptID] {
                    case .some(.pending): receipt = nil
                    case .some(.candidate(let value)): receipt = value
                    case .some(.writing): throw CaptureGroupJournalError.invalidTransition
                    default: continue
                    }
                    try await terminal(.init(member: .init(group: group, target: target),
                        disposition: .cancelled, reason: reason, pixelReceipt: receipt))
                }
                if let entry = groups[group.groupID], !entry.samplingEnded {
                    try await samplingEnded(group, reason: reason == .configurationChanged ? .configurationChanged : .cancelled)
                }
            } catch { if firstFailure == nil { firstFailure = error } }
            // All native/forwarding producers are joined. A failed journal
            // remains explicitly pending on disk and the stop throws; retaining
            // a dead local entry would permanently exhaust future sessions.
            groups.removeValue(forKey: group.groupID)
        }
        if let firstFailure { throw firstFailure }
    }

    /// A native read may have happened before a journal ACK was lost. Preserve
    /// its exact envelope and receipt so restart cleanup can retry idempotently;
    /// do not replace it with a new event or a fabricated receiptless outcome.
    private func retryFailedAcknowledgements(in id: UUID) async throws {
        guard let entry = groups[id] else { return }
        if !entry.beginAcknowledged {
            try await journal.appendCaptureGroupEvent(entry.beginEvent)
            groups[id]?.beginAcknowledged = true
        }
        for event in entry.failedWrites.values.sorted(by: { $0.monotonicTime < $1.monotonicTime }) {
            guard case .attemptOutcome(let outcome) = event.payload else { throw CaptureGroupJournalError.invalidTransition }
            do { try await journal.appendCaptureGroupEvent(event) }
            catch CaptureGroupJournalError.referenceUnavailable where outcome.disposition == .suppressedSimilar {
                // The exact old anchor was deleted before this write committed.
                // The current known candidate can still receive cancellation.
                groups[id]?.failedWrites.removeValue(forKey: outcome.member.attemptID)
                continue
            }
            groups[id]?.failedWrites.removeValue(forKey: outcome.member.attemptID)
            finish(outcome)
        }
        if let end = groups[id]?.pendingEnd {
            try await journal.appendCaptureGroupEvent(end)
            groups[id]?.pendingEnd = nil
            groups[id]?.samplingEnded = true
            prune(id)
        }
    }

    private func append(_ outcome: CaptureAttemptOutcome) async throws {
        let id = outcome.member.groupID, attempt = outcome.member.attemptID
        guard let entry = groups[id], entry.beginAcknowledged, entry.failedWrites[attempt] == nil,
              let before = entry.members[attempt] else {
            throw CaptureGroupJournalError.invalidTransition
        }
        switch (before, outcome.disposition) {
        case (.pending, .retainedCandidate), (.pending, .unavailable), (.pending, .cancelled),
             (.candidate(_), .suppressedSimilar), (.candidate(_), .dropped), (.candidate(_), .cancelled): break
        default: throw CaptureGroupJournalError.invalidTransition
        }
        if case .candidate(let receipt) = before, outcome.pixelReceipt != receipt {
            throw CaptureGroupJournalError.invalidTransition
        }
        let event = CaptureGroupEvent(payload: .attemptOutcome(outcome))
        _ = try event.validatedEncoding(group: entry.group)
        groups[id]?.members[attempt] = .writing
        do { try await journal.appendCaptureGroupEvent(event) }
        catch {
            groups[id]?.members[attempt] = before
            if let journalError = error as? CaptureGroupJournalError, case .referenceUnavailable = journalError { }
            else { groups[id]?.failedWrites[attempt] = event }
            throw error
        }
        finish(outcome)
    }

    private func finish(_ outcome: CaptureAttemptOutcome) {
        let id = outcome.member.groupID, attempt = outcome.member.attemptID
        // Re-read the actor's current entry after the await. Source and manager
        // may have completed a different member while this journal write ran.
        if outcome.disposition == .retainedCandidate, let receipt = outcome.pixelReceipt {
            groups[id]?.members[attempt] = .candidate(receipt)
        } else { groups[id]?.members[attempt] = .resolved }
        prune(id)
    }

    private func prune(_ id: UUID) {
        guard let entry = groups[id], entry.samplingEnded,
              entry.members.values.allSatisfy({ state in
                  switch state { case .resolved, .forwarded: return true; default: return false }
              }) else { return }
        groups.removeValue(forKey: id)
    }
}
