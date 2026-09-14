import Foundation
import Combine
import Shared

/// Keeps only one bounded text page. Earlier pages are revalidated when revisited.
@MainActor
final class EvidenceTextViewModel: ObservableObject {
    typealias Expand = @Sendable (ScreenEvidenceExpansionRequest) async throws -> ScreenEvidenceExpansionPage
    @Published private(set) var reference: ScreenEvidenceRef?
    @Published private(set) var page: ScreenEvidenceExpansionPage?
    @Published private(set) var isLoading = false
    @Published private(set) var error: EvidenceUnavailableReason?
    @Published private(set) var pageNumber = 1
    var canGoBack: Bool { !history.isEmpty }
    private let report: @Sendable (String, Int) async -> Void
    private let expand: Expand
    private let blockLimit: Int
    private let maximumUTF8Bytes: Int
    private var history: [ScreenEvidenceExpansionCursor?] = []
    private var cursor: ScreenEvidenceExpansionCursor?
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    init(blockLimit: Int = 32, maximumUTF8Bytes: Int = 16_384,
         report: @escaping @Sendable (String, Int) async -> Void = { _, _ in }, expand: @escaping Expand) {
        self.blockLimit = blockLimit; self.maximumUTF8Bytes = maximumUTF8Bytes; self.report = report; self.expand = expand
    }
    func open(_ reference: ScreenEvidenceRef) async {
        guard !Task.isCancelled else { return }
        if self.reference == reference {
            if let task { await task.value; return }
            if page != nil { return }
        }
        cancel()
        self.reference = reference
        await load(reference, cursor: nil, history: [], pageNumber: 1)
    }

    func next() async {
        guard !Task.isCancelled else { return }
        if let task { await task.value; return }
        guard let reference, let next = page?.nextCursor else { return }
        await load(reference, cursor: next, history: history + [cursor], pageNumber: pageNumber + 1)
    }

    func previous() async {
        guard !Task.isCancelled else { return }
        if let task { await task.value; return }
        guard let reference, let previous = history.last else { return }
        await load(reference, cursor: previous, history: Array(history.dropLast()), pageNumber: pageNumber - 1)
    }

    func cancel() {
        generation &+= 1
        task?.cancel(); task = nil
        reference = nil; page = nil; error = nil
        history = []; cursor = nil; pageNumber = 1; isLoading = false
    }

    private func load(_ reference: ScreenEvidenceRef, cursor: ScreenEvidenceExpansionCursor?,
                      history: [ScreenEvidenceExpansionCursor?], pageNumber: Int) async {
        generation &+= 1
        let token = generation
        let request = ScreenEvidenceExpansionRequest(reference: reference, blockLimit: blockLimit,
            maximumUTF8Bytes: maximumUTF8Bytes, cursor: cursor)
        page = nil; error = nil; isLoading = true
        let expand = expand, report = report
        let owned = Task { [weak self] in
            do {
                let result = try await expand(request)
                guard let self, self.isCurrent(token) else {
                    await report("cancelled", 0)
                    return
                }
                // The service owns access checks; this boundary also rejects
                // a misrouted or over-budget page before it reaches SwiftUI.
                guard result.reference == reference,
                      result.textUTF8Bytes <= request.maximumUTF8Bytes,
                      result.fragments.count <= request.blockLimit,
                      result.fragments.allSatisfy({ $0.id.reference == reference }),
                      result.nextCursor == nil || (result.nextCursor != cursor && !result.fragments.isEmpty) else {
                    self.fail(.integrityFailure)
                    await report("failed", 0)
                    return
                }
                self.cursor = cursor; self.history = history; self.pageNumber = pageNumber
                self.page = result; self.isLoading = false; self.task = nil
                // Publication is already complete. Metrics do not add a
                // suspension between the final access check and admission.
                await report(result.fragments.isEmpty ? "no_results" : "success", result.fragments.count)
            } catch {
                guard let self, self.isCurrent(token) else { return }
                self.fail((error as? EvidenceUnavailableReason) ?? .integrityFailure)
                // Service failures already emit their outcome metric.
            }
        }
        task = owned
        await withTaskCancellationHandler {
            await owned.value
        } onCancel: {
            owned.cancel()
            Task { @MainActor [weak self] in self?.cancel(ifCurrent: token) }
        }
        // The cleanup callback can be queued behind completion on MainActor.
        // Finish the initiating request's cancellation before returning to its caller.
        if Task.isCancelled { cancel(ifCurrent: token) }
    }

    private func cancel(ifCurrent token: UInt64) {
        guard generation == token else { return }
        cancel()
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        token == generation && reference != nil && !Task.isCancelled
    }

    private func fail(_ reason: EvidenceUnavailableReason) {
        page = nil; error = reason; isLoading = false; task = nil
        history = []; cursor = nil; pageNumber = 1
    }
}
