import Database
import Foundation
import Shared

/// One reader lifetime owns its pagination identity and its read-only connection.
/// The service container joins active reads before releasing the recording store.
public actor LiveAudioContextReader {
    private let openConnection: @Sendable () async throws -> SQLiteConnection
    private var connection: SQLiteConnection?
    private var queries: AudioTranscriptionQueries?
    private var opening: (id: UUID, task: Task<SQLiteConnection, Error>)?
    private var closed = false
    private var activeReads = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    #if DEBUG
    private var closeRequestForTesting: (@Sendable () -> Void)?
    func setCloseRequestForTesting(_ request: @escaping @Sendable () -> Void) {
        closeRequestForTesting = request
    }
    #endif

    init(database: DatabaseManager) {
        openConnection = { try await database.makeRecallReadConnection() }
    }

    init(openConnection: @escaping @Sendable () async throws -> SQLiteConnection) {
        self.openConnection = openConnection
    }

    public func getContextPage(
        from start: Date, to end: Date, source: AudioSource? = nil,
        limit: Int = 100, before cursor: AudioContextCursor? = nil, query: String? = nil
    ) async throws -> AudioContextPage {
        try beginRead()
        defer { endRead() }
        let reader = try await acquireReader()
        return try await reader.getContextPage(from: start, to: end, source: source,
            limit: limit, before: cursor, query: query)
    }

    public func getContextEntry(id: Int64) async throws -> AudioTranscription? {
        try beginRead()
        defer { endRead() }
        let reader = try await acquireReader()
        return try await reader.getContextEntry(id: id)
    }

    private func acquireReader() async throws -> AudioTranscriptionQueries {
        if let queries { return queries }
        let request: (id: UUID, task: Task<SQLiteConnection, Error>)
        if let opening { request = opening }
        else {
            request = (UUID(), Task { [openConnection] in try await openConnection() })
            opening = request
        }
        let opened: SQLiteConnection
        do { opened = try await request.task.value }
        catch {
            if opening?.id == request.id { opening = nil }
            throw error
        }
        if opening?.id == request.id { opening = nil }
        try Task.checkCancellation()
        guard !closed else { throw AudioContextReadError.closed }
        // An overlapping request can finish opening first. All successful reads
        // must share that first published actor, including its cursor identity.
        if let queries { return queries }
        guard let pointer = opened.getConnection() else { throw AudioContextReadError.closed }
        let reader = AudioTranscriptionQueries(db: pointer)
        connection = opened
        queries = reader
        return reader
    }

    private func beginRead() throws {
        try Task.checkCancellation()
        guard !closed else { throw AudioContextReadError.closed }
        activeReads += 1
    }

    private func endRead() {
        activeReads -= 1
        if activeReads == 0 {
            let waiters = closeWaiters
            closeWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    public func close() async {
        closed = true
        #if DEBUG
        closeRequestForTesting?()
        closeRequestForTesting = nil
        #endif
        opening?.task.cancel()
        if activeReads > 0 {
            await withCheckedContinuation { closeWaiters.append($0) }
        }
        queries = nil
        connection = nil
    }
}
