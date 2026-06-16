import SwiftUI
import AppKit
import Database
import Shared

/// SwiftUI view displaying audio transcriptions in the transcript window
struct TranscriptContentView: View {
    let transcriptions: [AudioTranscription]
    let timestamp: Date
    let storageRoot: URL?
    let onClose: () -> Void

    /// Strip whisper.cpp control tokens for display (handles legacy DB records)
    static func stripControlTokens(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: "\\[.*?\\]",
            with: "",
            options: .regularExpression
        )
        let collapsed = stripped.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let headerFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Audio Transcript")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(Self.headerFormatter.string(from: timestamp))
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .background(Color.white.opacity(0.1))

            // Content
            if transcriptions.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 32))
                        .foregroundColor(.white.opacity(0.3))
                    Text("No audio recordings for this time range")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.4))
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(sortedTranscriptions, id: \.id) { transcription in
                            TranscriptionRow(
                                transcription: transcription,
                                storageRoot: storageRoot
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sortedTranscriptions: [AudioTranscription] {
        transcriptions.sorted { $0.startTime < $1.startTime }
    }
}

// MARK: - Cursor Policy

enum TranscriptCursorPolicy {
    enum Action: Equatable {
        case pushPointingHand
        case pop
    }

    static func action(hovering: Bool, hasAudioFile: Bool, cursorIsPushed: Bool) -> Action? {
        if hovering && hasAudioFile {
            return cursorIsPushed ? nil : .pushPointingHand
        }

        return cursorIsPushed ? .pop : nil
    }
}

// MARK: - Transcription Row

private struct TranscriptionRow: View {
    let transcription: AudioTranscription
    let storageRoot: URL?
    @State private var isHovering = false
    @State private var didPushCursor = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var duration: TimeInterval {
        transcription.endTime.timeIntervalSince(transcription.startTime)
    }

    private var formattedDuration: String {
        let seconds = Int(duration)
        if seconds < 60 {
            return "\(seconds)s"
        }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private var hasAudioFile: Bool {
        guard let path = transcription.audioPath, let root = storageRoot else { return false }
        let fullPath = root.appendingPathComponent(path).path
        return FileManager.default.fileExists(atPath: fullPath)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Time
            Text(Self.timeFormatter.string(from: transcription.startTime))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 60, alignment: .leading)

            // Source badge
            sourceBadge
                .frame(width: 36)

            // Content: transcript text or raw audio indicator
            if transcription.text.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                    Text("Audio recorded (\(formattedDuration))")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.4))
                        .italic()
                }
            } else {
                Text(TranscriptContentView.stripControlTokens(transcription.text))
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            // Reveal in Finder button for entries with audio files
            if hasAudioFile {
                Button(action: revealInFinder) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13))
                        .foregroundColor(isHovering ? .blue : .white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Reveal audio file in Finder")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.white.opacity(0.05) : Color.clear)
        )
        .onTapGesture {
            if hasAudioFile {
                Log.info("[TranscriptRow] reveal requested id=\(transcription.id) source=\(transcription.source.rawValue) audioPath=\(transcription.audioPath ?? "nil")", category: .ui)
                revealInFinder()
            }
        }
        .onHover { hovering in
            isHovering = hovering
            applyCursorAction(hovering: hovering)
        }
        .onDisappear {
            releaseCursorIfNeeded()
        }
    }

    private func revealInFinder() {
        guard let path = transcription.audioPath, let root = storageRoot else {
            Log.warning("[TranscriptRow] reveal skipped id=\(transcription.id) missing audio path/root", category: .ui)
            return
        }
        let fileURL = root.appendingPathComponent(path)
        Log.info("[TranscriptRow] revealing audio id=\(transcription.id) path=\(path)", category: .ui)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func applyCursorAction(hovering: Bool) {
        guard let action = TranscriptCursorPolicy.action(
            hovering: hovering,
            hasAudioFile: hasAudioFile,
            cursorIsPushed: didPushCursor
        ) else {
            return
        }

        switch action {
        case .pushPointingHand:
            NSCursor.pointingHand.push()
            didPushCursor = true
        case .pop:
            NSCursor.pop()
            didPushCursor = false
        }
    }

    private func releaseCursorIfNeeded() {
        guard didPushCursor else { return }
        NSCursor.pop()
        didPushCursor = false
    }

    @ViewBuilder
    private var sourceBadge: some View {
        let (icon, label) = sourceInfo
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(label)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundColor(sourceColor.opacity(0.8))
    }

    private var sourceInfo: (String, String) {
        switch transcription.source {
        case .microphone:
            return ("mic.fill", "Mic")
        case .system:
            return ("speaker.wave.2.fill", "Sys")
        case .zoom:
            return ("video.fill", "Zm")
        default:
            return ("waveform", "?")
        }
    }

    private var sourceColor: Color {
        switch transcription.source {
        case .microphone: return .blue
        case .system: return .green
        case .zoom: return .orange
        default: return .gray
        }
    }
}
