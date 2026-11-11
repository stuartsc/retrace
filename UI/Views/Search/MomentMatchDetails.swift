import Shared
import SwiftUI

struct WorkspaceMatchExplanation: View {
    let explanation: SearchMatchExplanation
    var body: some View {
        HStack(spacing: 8) {
            ForEach(explanation.bases, id: \.rawValue) { basis in
                switch basis {
                case .textMatch:
                    Label("Text match", systemImage: "text.magnifyingglass")
                case .semanticSimilarity:
                    Label("Related meaning", systemImage: "sparkle.magnifyingglass")
                case .exactIdentifier:
                    Label("Exact ID: " + explanation.exactIdentifiers.joined(separator: ", "), systemImage: "number")
                }
            }
        }.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
    }
}

struct WorkspaceSearchCoverage: View {
    let coverage: MomentSearchCoverage
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Coverage when searched").fontWeight(.medium)
            if coverage.nativeSemanticUsed {
                Text("Meaning matches cover native screen text; imported history uses text matching.")
                if coverage.nativeIndexCaughtUp != true || coverage.pendingObservations > 0 {
                    Text("Still indexing: \(coverage.indexedObservations) screen observations ready, \(coverage.pendingObservations) pending.")
                }
                if coverage.skippedObservations > 0 {
                    Text("\(coverage.skippedObservations) screen observations could not be indexed.")
                }
            }
            if !coverage.lexicalScanComplete || coverage.semanticScanComplete == false {
                Text("This search reached its work limit. Narrow the question or time range to inspect more relevant history.")
            }
            if coverage.unavailableLexicalObservations > 0 {
                Text("Some matching text was unavailable when its evidence was checked.")
            }
        }.font(.caption2).foregroundStyle(.secondary)
            .accessibilityIdentifier("workspace.search.coverage")
    }
}
