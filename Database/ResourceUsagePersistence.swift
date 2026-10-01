import Foundation
import Shared
import SQLCipher

extension DatabaseManager {
    /// Bounded, independent performance history; deleting expired telemetry
    /// never touches recordings, search text or existing engagement metrics.
    public func recordResourceUsageMinute(_ minute: ResourceUsageMinute) throws {
        try persistResourceUsageMinute(minute, beforeCommit: nil)
    }

    #if DEBUG
    func recordResourceUsageMinuteForTesting(_ minute: ResourceUsageMinute,
        beforeCommit: @escaping @Sendable () throws -> Void) throws {
        try persistResourceUsageMinute(minute, beforeCommit: beforeCommit)
    }
    #endif

    private func persistResourceUsageMinute(_ minute: ResourceUsageMinute,
        beforeCommit: (() throws -> Void)?) throws {
        let db = try requireRecallConnection()
        let seconds = minute.timestamp.timeIntervalSince1970
        let window = minute.cpu
        guard seconds.isFinite, abs(seconds) < 9e12,
              window.elapsedSeconds.isFinite, (0...60).contains(window.elapsedSeconds),
              window.sampledSeconds.isFinite, (0...window.elapsedSeconds).contains(window.sampledSeconds),
              window.cpuPercent.map({ $0.isFinite && $0 >= 0 }) ?? true,
              window.peakCPUPercent.map({ $0.isFinite && $0 >= 0 }) ?? true,
              minute.systemCPUPercent.map({ $0.isFinite && (0...100).contains($0) }) ?? true,
              minute.droppedMinutes >= 0 else { throw PipelineSQL.failure("Invalid resource aggregate") }
        let data = try JSONEncoder().encode(minute)
        guard let metadata = String(data: data, encoding: .utf8), data.count <= 4096 else {
            throw DatabaseError.queryFailed(query: "resourceUsage", underlying: "Invalid aggregate")
        }
        // Audio query actors also borrow this FULLMUTEX connection. Its per-call
        // lock alone does not own the complete BEGIN/COMMIT/ROLLBACK interval.
        guard let mutex = sqlite3_db_mutex(db) else {
            throw PipelineSQL.failure("Resource persistence requires a serialized connection")
        }
        sqlite3_mutex_enter(mutex)
        defer { sqlite3_mutex_leave(mutex) }
        try PipelineSQL.transaction(db) {
            try DailyMetricsQueries.recordEvent(db: db, metricType: .resourceUsage,
                                               timestamp: minute.timestamp, metadata: metadata)
            // Clock changes cannot grow telemetry indefinitely: retain at most
            // thirty days of minute rows, independently of their wall timestamp.
            try PipelineSQL.execute(db, """
                DELETE FROM daily_metrics WHERE id IN (
                    SELECT id FROM daily_metrics
                    WHERE metricType='resource_usage' AND timestamp < ?
                    ORDER BY timestamp,id LIMIT 256
                )
                """, [.integer(Int64(minute.timestamp.addingTimeInterval(-30 * 86400).timeIntervalSince1970 * 1000))])
            try PipelineSQL.execute(db, """
                DELETE FROM daily_metrics WHERE id IN (
                    SELECT id FROM daily_metrics WHERE metricType='resource_usage'
                    ORDER BY timestamp DESC,id DESC LIMIT 256 OFFSET 43200
                )
                """)
            try beforeCommit?()
        }
    }
}
