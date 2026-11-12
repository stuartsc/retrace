import App

/// One total budget covers every source in the preview and subsequent copy.
/// The caller places explicit selections before bulk loaded history.
struct LiveContextCopyBudget {
    let references: [LiveContextReference]
    let omittedCount: Int
    let notice: String?

    init(references candidates: [LiveContextReference]) {
        references = Array(candidates.prefix(LiveContextSearchService.maximumCopyReferences))
        let omitted = candidates.dropFirst(references.count)
        omittedCount = omitted.count
        guard !omitted.isEmpty else { notice = nil; return }
        let counts = Dictionary(grouping: omitted, by: Self.kind).mapValues(\.count)
        let details = counts.keys.sorted().map { "\(counts[$0]!) \($0) references omitted" }.joined(separator: "; ")
        notice = "Copy includes \(references.count) of \(candidates.count) loaded evidence references. \(details) by the \(LiveContextSearchService.maximumCopyReferences)-reference limit. Narrow the interval or select individual evidence to include omitted material."
    }

    static func text(_ sourceText: String, notice: String?) -> String {
        notice.map { $0 + "\n\n" + sourceText } ?? sourceText
    }

    private static func kind(_ reference: LiveContextReference) -> String {
        switch reference {
        case .transcript: return "transcript"
        case .screen: return "screen"
        case .speaker, .speakerTurn: return "speaker"
        case .metadata: return "app/window"
        case .note: return "note"
        case .marker: return "marker"
        case .range: return "context range"
        }
    }
}
