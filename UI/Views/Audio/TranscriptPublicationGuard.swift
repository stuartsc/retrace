import App
import Database
import Foundation
import Shared

/// An observation starts before reads and stays owned through visible publication.
/// The same lock serialises invalidation and the final synchronous MainActor write.
final class TranscriptPublicationGuard: @unchecked Sendable {
    let id = UUID()
    private let lock = NSRecursiveLock()
    private var valid = true
    private var published = false
    private var dependencies = NativeSourceDependencies.unknown
    private var jobs: Set<String>?
    private var onInvalidated: (@Sendable (CompanionSpeakerChange) -> Void)?
    private var observation: UUID?
    private let remove: @Sendable (UUID) -> Void

    convenience init(owner: CompanionController) {
        self.init(register: { try owner.addSpeakerChangeObserver(invalidate: $0) },
                  remove: { owner.removeSpeakerChangeObserver($0) })
    }

    init(register: (@escaping @Sendable (CompanionSpeakerChange) -> Void) throws -> UUID,
         remove: @escaping @Sendable (UUID) -> Void) {
        self.remove = remove
        do {
            observation = try register { [weak self] change in self?.invalidate(change) }
        } catch {
            valid = false
        }
    }

    deinit { if let observation { remove(observation) } }

    private func invalidate(_ change: CompanionSpeakerChange) {
        lock.lock()
        let affected: Bool
        switch change {
        case .all: affected = true
        case .source(let value): affected = !published || value.affects(dependencies)
        case .correction(let jobID, _): affected = !published || (jobs?.contains(jobID) ?? true)
        }
        if affected { valid = false }
        let callback = affected ? onInvalidated : nil
        lock.unlock()
        callback?(change)
    }

    func narrow(recordings: [AudioTranscription], speakers: [CompanionSpeakerPresentation]) {
        lock.lock(); defer { lock.unlock() }
        var targets = Set(recordings.map { NativeSourceTarget.audioRow($0.id) })
        for row in recordings {
            if let path = row.batchAudioPath ?? row.audioPath { targets.insert(.audioBatch(path)) }
        }
        dependencies = speakers.reduce(NativeSourceDependencies(targets: targets)) { $0.merging($1.sourceDependencies) }
        jobs = Set(speakers.map(\.jobID))
    }

    func withAdmission<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard valid else { throw CompanionError.staleEvidence }
        return try body()
    }

    /// Called inside admission while installing the visible owner, without an await.
    func observeVisibleInvalidation(_ callback: @escaping @Sendable (CompanionSpeakerChange) -> Void) {
        lock.lock(); defer { lock.unlock() }
        onInvalidated = callback
        published = true
    }
}
