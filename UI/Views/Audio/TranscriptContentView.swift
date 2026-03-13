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

// MARK: - Transcription Row

private struct TranscriptionRow: View {
    let transcription: AudioTranscription
    let storageRoot: URL?
    @State private var isHovering = false

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
                Text(transcription.text)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            // Reveal in Finder button for entries with audio files
            if hasAudioFile {
                Button(action: revealInFinder) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(isHovering ? 0.8 : 0.3))
                }
                .buttonStyle(.plain)
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
                revealInFinder()
            }
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering && hasAudioFile {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private func revealInFinder() {
        guard let path = transcription.audioPath, let root = storageRoot else { return }
        let fileURL = root.appendingPathComponent(path)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
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
