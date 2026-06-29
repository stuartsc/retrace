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
                        ForEach(presentationRows) { row in
                            TranscriptionRow(
                                row: row,
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

    private var presentationRows: [TranscriptPresentationRow] {
        TranscriptPresentationPolicy.presentationRows(from: transcriptions)
    }
}

// MARK: - Presentation Policy

struct TranscriptPresentationRow: Identifiable {
    let transcription: AudioTranscription
    let repeatedCount: Int
    let captionLabel: String?
    let captionSignature: String?
    let endedAt: Date

    var id: Int64 { transcription.id }

    var displayText: String {
        if repeatedCount > 1, let captionLabel {
            return "Ambient audio: \(captionLabel) (\(repeatedCount) entries)"
        }
        return TranscriptContentView.stripControlTokens(transcription.text)
    }

    var isCollapsedAmbientCaption: Bool {
        repeatedCount > 1 && captionLabel != nil
    }

    func merged(with next: AudioTranscription, captionLabel: String) -> TranscriptPresentationRow {
        TranscriptPresentationRow(
            transcription: transcription,
            repeatedCount: repeatedCount + 1,
            captionLabel: captionLabel,
            captionSignature: captionSignature,
            endedAt: max(endedAt, next.endTime)
        )
    }
}

enum TranscriptPresentationPolicy {
    private static let captionTerms: Set<String> = [
        "alarm",
        "applause",
        "background",
        "beep",
        "bell",
        "breathing",
        "camera",
        "chime",
        "click",
        "clicking",
        "clapping",
        "cough",
        "crackle",
        "crackling",
        "door",
        "doorbell",
        "fire",
        "footstep",
        "footsteps",
        "inaudible",
        "keyboard",
        "knock",
        "laugh",
        "laughter",
        "mouse",
        "music",
        "noise",
        "notification",
        "ring",
        "ringing",
        "silence",
        "sigh",
        "sound",
        "sounds",
        "static",
        "typing",
        "waves",
        "wind"
    ]

    static func presentationRows(from transcriptions: [AudioTranscription]) -> [TranscriptPresentationRow] {
        let sorted = transcriptions.sorted { $0.startTime < $1.startTime }
        var rows: [TranscriptPresentationRow] = []

        for transcription in sorted {
            if let caption = ambientCaption(for: transcription),
               let last = rows.last,
               last.captionSignature == caption.signature {
                rows[rows.count - 1] = last.merged(
                    with: transcription,
                    captionLabel: caption.label
                )
                continue
            }

            let caption = ambientCaption(for: transcription)
            rows.append(TranscriptPresentationRow(
                transcription: transcription,
                repeatedCount: 1,
                captionLabel: caption?.label,
                captionSignature: caption?.signature,
                endedAt: transcription.endTime
            ))
        }

        return rows
    }

    private static func ambientCaption(for transcription: AudioTranscription) -> (signature: String, label: String)? {
        ambientCaptionSignature(for: transcription.text, transcriptStatus: transcription.transcriptStatus)
    }

    static func ambientCaptionSignature(for text: String, transcriptStatus: String) -> (signature: String, label: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        let hasCaptionMarker = lower.contains("*")
            || (lower.hasPrefix("(") && lower.hasSuffix(")"))
            || (lower.hasPrefix("[") && lower.hasSuffix("]"))
        let isStatusRow = transcriptStatus.lowercased() != "transcribed"
        guard hasCaptionMarker || isStatusRow else { return nil }

        let tokens = normalizedTokens(from: lower)
        guard !tokens.isEmpty else { return nil }

        let canonicalTokens = repeatedPhraseCollapsed(tokens)
        guard canonicalTokens.contains(where: captionTerms.contains) else { return nil }

        let label = canonicalTokens.joined(separator: " ")
        return ("ambient:\(label)", label)
    }

    private static func normalizedTokens(from text: String) -> [String] {
        let separators = CharacterSet.alphanumerics.inverted
        return text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func repeatedPhraseCollapsed(_ tokens: [String]) -> [String] {
        guard tokens.count > 1 else { return tokens }

        for phraseLength in 1...max(1, tokens.count / 2) {
            guard tokens.count % phraseLength == 0 else { continue }

            let phrase = Array(tokens[0..<phraseLength])
            var isRepeatedPhrase = true
            var index = phraseLength
            while index < tokens.count {
                let nextPhrase = Array(tokens[index..<(index + phraseLength)])
                if nextPhrase != phrase {
                    isRepeatedPhrase = false
                    break
                }
                index += phraseLength
            }

            if isRepeatedPhrase {
                return phrase
            }
        }

        return tokens
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
    let row: TranscriptPresentationRow
    let storageRoot: URL?
    @State private var isHovering = false
    @State private var didPushCursor = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var transcription: AudioTranscription {
        row.transcription
    }

    private var duration: TimeInterval {
        row.endedAt.timeIntervalSince(transcription.startTime)
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
            if row.displayText.isEmpty {
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
                Text(row.displayText)
                    .font(.system(size: 13))
                    .foregroundColor(row.isCollapsedAmbientCaption ? .white.opacity(0.58) : .white.opacity(0.85))
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
