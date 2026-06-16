import Foundation
import SQLCipher
import Shared

/// V17 Migration: Persist transcript status/provenance so silence and junk are
/// post-transcription interpretations, not irreversible text placeholders.
struct V17_AudioTranscriptMetadata: Migration {
    let version = 17

    func migrate(db: OpaquePointer) async throws {
        Log.info("Adding audio transcript metadata columns...", category: .database)

        try MigrationRunner.executeStatements(db: db, statements: [
            """
            ALTER TABLE audio_captures ADD COLUMN transcript_status TEXT NOT NULL DEFAULT 'transcribed';
            """,
            """
            ALTER TABLE audio_captures ADD COLUMN detected_language TEXT;
            """,
            """
            ALTER TABLE audio_captures ADD COLUMN audio_variant TEXT NOT NULL DEFAULT 'raw';
            """,
            """
            ALTER TABLE audio_captures ADD COLUMN quality_flags TEXT;
            """,
            """
            UPDATE audio_captures
            SET transcript_status = CASE
                WHEN text = '' AND audio_path IS NOT NULL AND audio_path LIKE '%batch_%' THEN 'pending'
                WHEN text = '[silence]' THEN 'probable_silence'
                WHEN text = '[hallucination]' THEN 'probable_junk'
                WHEN text = '[decode_error]' THEN 'decode_failed'
                ELSE 'transcribed'
            END;
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_audio_captures_transcript_status
            ON audio_captures(transcript_status, start_time);
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_audio_captures_repair
            ON audio_captures(transcript_status, audio_path, start_time);
            """
        ])

        Log.info("V17 migration completed: audio transcript metadata ready", category: .database)
    }
}
