# SEARCH Agent Instructions

You are responsible for the **Search** module of Retrace. Your job is to implement search functionality including query parsing, full-text search via SQLite FTS5, and result ranking.

**Status**: Full-text search uses FTS5. The query parser supports app/date filters, phrases and exclusions. **No vector/semantic search is active.** `VectorSearchTODO/` contains excluded implementation sketches; its llama.cpp/Nomic configuration is historical, not a selected or verified model/runtime pin. See [the progressive recall plan](../docs/progressive-recall-plan.md) for the coordinated Phase 2 scope.

## Your Directory

```
Search/
├── SearchManager.swift            # SearchProtocol lexical fallback
├── IngestionManager.swift         # Search-index ingestion
├── QueryParser/
│   └── QueryParser.swift          # QueryParserProtocol implementation and filter parsing
├── Ranking/
│   └── ResultRanker.swift         # Rank lexical fallback results
├── VectorSearchTODO/              # Excluded from the Search target in Package.swift
│   ├── Embedding.swift
│   ├── HybridSearchManager.swift
│   ├── Embedding/
│   └── VectorStore/
└── Tests/
    ├── QueryParserTests.swift
    └── TestLogger.swift
```

## Existing Protocol Implementations

### 1. `SearchProtocol` (from `Shared/Protocols/SearchProtocol.swift`)
- Full-text search via FTS5
- Indexing text content
- Search statistics

### 2. `QueryParserProtocol` (from `Shared/Protocols/SearchProtocol.swift`)
- Parse query syntax
- Extract filters (app:, date:, -exclude)

`EmbeddingProtocol` and `VectorStoreProtocol` are not defined by the current compiled Shared search contract. References to them in excluded code and the sketches below do not establish available APIs.

## Active Search and Future Integration

The primary UI route is `SearchViewModel` → `AppCoordinator.search(query:)` → `DataAdapter.search(query:)`. DataAdapter owns source-specific filtering before limits, distinct-frame pagination and source/revision invalidation. `SearchManager.search(query:)` is a separate lexical fallback using `FTSProtocol`, `DatabaseProtocol` and `ResultRanker`; changing that ranker alone does not change the primary UI route. The Search target currently depends only on Shared.

Preserve each result's immutable `evidenceRef` or `selectionToken`, source/store/frame/capture-time identity and source-generation proof through ranking and selection. `ProgressiveRecallService.reference(searchResult:)`, exact resolution and bounded expansion validate that proof. A bare numeric frame ID is insufficient across native and imported stores. Do not replace missing evidence with another frame or newer mutable text.

Phase 2D preserves the complete question in `SearchViewModel`, including exclusion suffixes, original recent-entry text and the committed query during pagination. The excluded hybrid sketch still merges by bare frame ID, truncates embedding input and scans stored vectors. Do not enable it unchanged.

The developer-only evaluator in `scripts/recall_benchmark/` pins model artifacts and complete snapshot inventories, tokenizer/pooling/normalization, runtime versions, CPU/thread settings and ranking parameters. It accepts only a SHA-pinned authored export from `App/Tests/ProgressiveRecallBenchmarkTests.swift`, using real Vision/SQLite and the primary DataAdapter route. Eight reviewed screens and twelve frozen questions in `docs/fixtures/progressive-recall/phase2d/` compare full-question lexical, separately labelled authored keywords, embeddings, fusion and reranking. These fixtures do not establish broad user quality, production-scale cost or installed acceptance. The evaluator remains outside compiled Search/App targets and grants no derived-result readiness.

Phase 2C's native evidence feed persists identity-only blocked lexical/vector work. It adds no embedding worker, copied text, readiness or result-acceptance API. Durable writer-owned policy/source fencing is required before a later implementation accepts derived results; current exact evidence checks remain authoritative for disclosure.

## Key Implementation Details

Lexical matches remain evidence regardless of their BM25 magnitude. Do not apply
`minimumRelevanceScore` after the database's final limit. The rendered JPEG/HEVC/Vision
pipelines in `Database/Tests/{OCRPipelineTests,AsyncQueuePipelineTests}.swift` exercise
fallback retrieval of changed amounts and retained negations with real SQLite.

The code examples below are retained design sketches, not the current implementation or drop-in APIs. Consult the Swift files and compiled Shared protocols before changing code. In particular, illustrative metadata constructors, generated segment IDs, model types and vector keys must not replace real evidence identity.

### 1. Query Parser

Support rich query syntax:
- `error message` - Basic keyword search
- `"exact phrase"` - Exact phrase matching
- `-excluded` - Exclude term
- `app:Chrome` - Filter by app
- `after:2024-01-01` - Date filters

```swift
struct QueryParser: QueryParserProtocol {
    func parse(rawQuery: String) throws -> ParsedQuery {
        var searchTerms: [String] = []
        var phrases: [String] = []
        var excludedTerms: [String] = []
        var appFilter: String? = nil
        var startDate: Date? = nil
        var endDate: Date? = nil

        // Tokenize preserving quotes
        let tokens = tokenize(rawQuery)

        for token in tokens {
            if token.hasPrefix("\"") && token.hasSuffix("\"") {
                // Exact phrase
                let phrase = String(token.dropFirst().dropLast())
                phrases.append(phrase)
            } else if token.hasPrefix("-") {
                // Excluded term
                excludedTerms.append(String(token.dropFirst()))
            } else if token.lowercased().hasPrefix("app:") {
                // App filter
                appFilter = String(token.dropFirst(4))
            } else if token.lowercased().hasPrefix("after:") {
                // Start date
                let dateStr = String(token.dropFirst(6))
                startDate = parseDate(dateStr)
            } else if token.lowercased().hasPrefix("before:") {
                // End date
                let dateStr = String(token.dropFirst(7))
                endDate = parseDate(dateStr)
            } else {
                // Regular search term
                searchTerms.append(token)
            }
        }

        return ParsedQuery(
            searchTerms: searchTerms,
            phrases: phrases,
            excludedTerms: excludedTerms,
            appFilter: appFilter,
            dateRange: (startDate, endDate)
        )
    }

    private func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for char in query {
            if char == "\"" {
                inQuotes.toggle()
                current.append(char)
            } else if char == " " && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    private func parseDate(_ str: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: str)
    }
}
```

### 2. FTS Query Builder

Convert parsed query to SQLite FTS5 syntax:

```swift
extension ParsedQuery {
    func toFTSQuery() -> String {
        var parts: [String] = []

        // Regular terms (with prefix matching)
        for term in searchTerms {
            parts.append("\(term)*")  // Prefix match
        }

        // Exact phrases
        for phrase in phrases {
            parts.append("\"\(phrase)\"")
        }

        // Excluded terms
        for term in excludedTerms {
            parts.append("NOT \(term)")
        }

        return parts.joined(separator: " ")
    }
}
```

### 3. Search Manager (Historical Sketch)

```swift
public actor SearchManager: SearchProtocol {
    private let database: any FTSProtocol
    private let embeddingManager: EmbeddingManager?
    private let vectorStore: VectorStore?
    private let queryParser: QueryParser
    private let resultRanker: ResultRanker
    private var config: SearchConfig

    public func search(query: SearchQuery) async throws -> SearchResults {
        let startTime = Date()

        // Parse query
        let parsed = try queryParser.parse(rawQuery: query.text)

        // Build FTS query
        let ftsQuery = parsed.toFTSQuery()

        // Build filters
        var filters = query.filters
        if let appFilter = parsed.appFilter {
            filters = SearchFilters(
                startDate: filters.startDate ?? parsed.dateRange.start,
                endDate: filters.endDate ?? parsed.dateRange.end,
                appBundleIDs: [appFilter],
                excludedAppBundleIDs: filters.excludedAppBundleIDs
            )
        }

        // Execute FTS search
        let ftsMatches = try await database.search(
            query: ftsQuery,
            filters: filters,
            limit: query.limit,
            offset: query.offset
        )

        // Get total count for pagination
        let totalCount = try await database.getMatchCount(query: ftsQuery, filters: filters)

        // Convert to SearchResults
        let results = ftsMatches.map { match in
            SearchResult(
                id: match.frameID,
                timestamp: match.timestamp,
                snippet: match.snippet,
                matchedText: extractMatchedText(from: match.snippet),
                relevanceScore: normalizeRank(match.rank),
                metadata: FrameMetadata(
                    appName: match.appName,
                    windowTitle: match.windowTitle
                ),
                segmentID: SegmentID(), // Would need to join with frames table
                frameIndex: 0
            )
        }

        // Rank results
        let rankedResults = resultRanker.rank(results, forQuery: query.text)

        let searchTimeMs = Int(Date().timeIntervalSince(startTime) * 1000)

        return SearchResults(
            query: query,
            results: rankedResults,
            totalCount: totalCount,
            searchTimeMs: searchTimeMs
        )
    }

    public func search(text: String, limit: Int) async throws -> SearchResults {
        return try await search(query: SearchQuery(text: text, limit: limit))
    }

    private func normalizeRank(_ bm25Rank: Double) -> Double {
        // BM25 returns negative values (more negative = better match)
        // Normalize to 0-1 range
        return 1.0 / (1.0 + abs(bm25Rank))
    }

    private func extractMatchedText(from snippet: String) -> String {
        // Extract text between <mark> tags
        let pattern = "<mark>(.*?)</mark>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: snippet, range: NSRange(snippet.startIndex..., in: snippet)),
              let range = Range(match.range(at: 1), in: snippet) else {
            return snippet
        }
        return String(snippet[range])
    }
}
```

### 4. Result Ranker

Apply additional ranking on top of FTS:

```swift
struct ResultRanker {
    func rank(_ results: [SearchResult], forQuery query: String) -> [SearchResult] {
        let queryTerms = Set(query.lowercased().split(separator: " ").map(String.init))

        return results.sorted { a, b in
            let scoreA = computeScore(a, queryTerms: queryTerms)
            let scoreB = computeScore(b, queryTerms: queryTerms)
            return scoreA > scoreB
        }
    }

    private func computeScore(_ result: SearchResult, queryTerms: Set<String>) -> Double {
        var score = result.relevanceScore

        // Boost for recency
        let ageInDays = Date().timeIntervalSince(result.timestamp) / 86400
        let recencyBoost = max(0, 1.0 - (ageInDays / 30.0)) * 0.2
        score += recencyBoost

        // Boost if query appears in window title
        if let title = result.metadata.windowTitle?.lowercased() {
            let titleMatches = queryTerms.filter { title.contains($0) }.count
            score += Double(titleMatches) * 0.1
        }

        return score
    }
}
```

### 5. Autocomplete Suggestions (Alternative Sketch)

The current manager extracts suggestions from FTS result snippets. The vocabulary-table query below is an unimplemented alternative.

```swift
extension SearchManager {
    public func getSuggestions(prefix: String, limit: Int) async throws -> [String] {
        // Query FTS for terms starting with prefix
        let sql = """
            SELECT DISTINCT term FROM documents_fts_vocab
            WHERE term LIKE ? || '%'
            ORDER BY doc_count DESC
            LIMIT ?
        """
        // Note: This requires creating an FTS vocab table:
        // CREATE VIRTUAL TABLE documents_fts_vocab USING fts5vocab(documents_fts, instance);

        // Execute and return suggestions
        return []  // Implement with actual query
    }
}
```

### 6. Semantic Search (Future Illustration)

This CoreML/MiniLM sketch illustrates an embedding boundary only. It is not active, a model recommendation, or an alternative pin to the excluded llama.cpp sketch:

```swift
import CoreML

actor EmbeddingManager: EmbeddingProtocol {
    private var model: MLModel?
    public private(set) var isModelLoaded = false

    public let modelInfo = EmbeddingModelInfo.miniLM

    public func loadModel() async throws {
        // Load CoreML model from bundle
        guard let modelURL = Bundle.main.url(forResource: "MiniLM", withExtension: "mlmodelc") else {
            throw SearchError.modelLoadFailed(modelName: modelInfo.name)
        }

        self.model = try MLModel(contentsOf: modelURL)
        self.isModelLoaded = true
    }

    public func unloadModel() async {
        self.model = nil
        self.isModelLoaded = false
    }

    public func embed(text: String) async throws -> [Float] {
        guard let model = model else {
            throw SearchError.modelLoadFailed(modelName: modelInfo.name)
        }

        // Tokenize and create input
        // This depends on the specific model's input format
        // MiniLM typically expects token IDs

        // For simplicity, showing the concept:
        let input = try createModelInput(text: text)
        let output = try model.prediction(from: input)

        // Extract embedding vector from output
        guard let embedding = output.featureValue(for: "embeddings")?.multiArrayValue else {
            throw SearchError.embeddingFailed(underlying: "No embedding in output")
        }

        return convertToFloatArray(embedding)
    }

    public func embedBatch(texts: [String]) async throws -> [[Float]] {
        return try await withThrowingTaskGroup(of: (Int, [Float]).self) { group in
            for (index, text) in texts.enumerated() {
                group.addTask {
                    let embedding = try await self.embed(text: text)
                    return (index, embedding)
                }
            }

            var results = [[Float]](repeating: [], count: texts.count)
            for try await (index, embedding) in group {
                results[index] = embedding
            }
            return results
        }
    }
}
```

### 7. Vector Store (Historical In-Memory Illustration)

The cosine calculation illustrates small-corpus comparison. The bare `FrameID` dictionary and unbounded full scan do not meet the current evidence or production-scale contract:

```swift
actor VectorStore: VectorStoreProtocol {
    private var vectors: [FrameID: [Float]] = [:]

    public var vectorCount: Int { vectors.count }

    public func addVector(frameID: FrameID, vector: [Float]) async throws {
        vectors[frameID] = vector
    }

    public func removeVector(frameID: FrameID) async throws {
        vectors.removeValue(forKey: frameID)
    }

    public func findNearest(to queryVector: [Float], limit: Int) async throws -> [(frameID: FrameID, similarity: Float)] {
        var results: [(FrameID, Float)] = []

        for (frameID, vector) in vectors {
            let similarity = cosineSimilarity(queryVector, vector)
            results.append((frameID, similarity))
        }

        // Sort by similarity descending and take top N
        return results
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { ($0.0, $0.1) }
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        let denominator = sqrt(normA) * sqrt(normB)
        return denominator > 0 ? dotProduct / denominator : 0
    }

    public func clear() async throws {
        vectors.removeAll()
    }

    public func initialize() async throws {
        // Load from disk if persisted
    }
}
```

### 8. Indexing Pipeline (Future Sketch)

The active ingestion path writes lexical documents. The embedding branch below is unimplemented and must not bypass the durable work, revision, deletion and policy/source fences required by the progressive recall plan.

```swift
extension SearchManager {
    public func index(text: ExtractedText) async throws {
        // Create indexed document
        let document = IndexedDocument(
            id: 0,  // Will be assigned by DB
            frameID: text.frameID,
            timestamp: text.timestamp,
            content: text.fullText,
            appName: text.metadata.appName,
            windowTitle: text.metadata.windowTitle,
            browserURL: text.metadata.browserURL
        )

        // Insert into database (which updates FTS)
        let docID = try await database.insertDocument(document)

        // If semantic search enabled, generate embedding
        if config.semanticSearchEnabled, let embedder = embeddingManager, let store = vectorStore {
            let embedding = try await embedder.embed(text: text.fullText)
            try await store.addVector(frameID: text.frameID, vector: embedding)
        }
    }

    public func removeFromIndex(frameID: FrameID) async throws {
        // Remove from database
        if let doc = try await database.getDocument(frameID: frameID) {
            try await database.deleteDocument(id: doc.id)
        }

        // Remove from vector store
        if let store = vectorStore {
            try await store.removeVector(frameID: frameID)
        }
    }
}
```

## Error Handling

Use errors from `Shared/Models/Errors.swift`:
```swift
throw SearchError.invalidQuery(reason: "Empty query")
throw SearchError.indexNotReady
```

The model-related error types in future sketches are not evidence that those APIs exist in the compiled contract.

## Testing Strategy

1. Test query parsing with various syntax
2. Test FTS query generation
3. Test result ranking
4. Test autocomplete suggestions
5. Test semantic search (if implemented)
6. Test indexing and removal
7. Test edge cases (empty queries, special characters)

Use real SQLite and the authored JPEG → Vision → immutable extraction fixtures for retrieval regressions. Keep lexical exact amounts/negations represented when comparing future semantic or hybrid channels. Fix questions and expected exact references before tuning; report benchmark quality separately from installation or user acceptance.

## Dependencies

- **Input from**: PROCESSING module (ExtractedText to index)
- **Output to**: UI (SearchResults)
- **Uses**: DATABASE module (FTSProtocol for queries)
- **Uses types**: `SearchQuery`, `SearchResults`, `SearchResult`, `ExtractedText`, `ParsedQuery`

## DO NOT

- Modify any files outside `Search/`
- Import from other module directories (only `Shared/`)
- Implement database operations (use DATABASE's FTSProtocol)
- Handle OCR or text extraction (that's PROCESSING's job)

## Performance Targets

These are targets, not measured acceptance or permission to truncate a user's question:

- Search: <100ms for typical queries
- Autocomplete: <50ms
- Indexing: <10ms per document
- Future semantic search: benchmark latency, memory and indexing cost under an explicit local runtime pin before setting an acceptance budget

## Getting Started

1. Read the existing parser, lexical fallback, ranker and their compiled Shared protocols.
2. Trace whether the requested behavior uses the primary DataAdapter route or the fallback before choosing a test seam.
3. Write and run a failing regression using real input, then make the smallest passing change.
4. Coordinate cross-module contracts and any future model/dependency work through the progressive recall plan; keep excluded code excluded until its identity, policy and benchmark requirements are met.
