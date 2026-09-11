import SQLCipher

/// Speeds idempotent enqueue, duplicate cleanup and per-frame queue completion.
/// Existing rows are preserved; duplicate rows are consolidated on enqueue/claim.
struct V19_ProcessingQueueFrameIndex: Migration {
    let version = 19

    func migrate(db: OpaquePointer) async throws {
        try MigrationRunner.executeStatements(db: db, statements: [
            "CREATE INDEX IF NOT EXISTS idx_processing_queue_frame_id ON processing_queue(frameId);",
            "CREATE INDEX IF NOT EXISTS idx_doc_segment_docid ON doc_segment(docid);",
            "CREATE INDEX IF NOT EXISTS idx_video_path ON video(path);",
            "CREATE INDEX IF NOT EXISTS idx_audio_segment_id ON audio(segmentId);",
            "CREATE INDEX IF NOT EXISTS idx_event_segment_id ON event(segmentID);"
        ])
    }
}
