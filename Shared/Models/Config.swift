import Foundation
import AppKit

// MARK: - Keyboard Shortcuts Configuration

/// Modifier flags for keyboard shortcuts (mirrors NSEvent.ModifierFlags for storage)
public struct ShortcutModifiers: OptionSet, Codable, Sendable, Equatable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let shift = ShortcutModifiers(rawValue: 1 << 1)
    public static let option = ShortcutModifiers(rawValue: 1 << 2)
    public static let control = ShortcutModifiers(rawValue: 1 << 3)

    /// Convert to NSEvent.ModifierFlags
    public var nsModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }

    /// Create from NSEvent.ModifierFlags
    public init(from nsFlags: NSEvent.ModifierFlags) {
        var value: UInt = 0
        if nsFlags.contains(.command) { value |= ShortcutModifiers.command.rawValue }
        if nsFlags.contains(.shift) { value |= ShortcutModifiers.shift.rawValue }
        if nsFlags.contains(.option) { value |= ShortcutModifiers.option.rawValue }
        if nsFlags.contains(.control) { value |= ShortcutModifiers.control.rawValue }
        self.rawValue = value
    }

    /// Display string with symbols
    public var displaySymbols: [String] {
        var symbols: [String] = []
        if contains(.control) { symbols.append("⌃") }
        if contains(.option) { symbols.append("⌥") }
        if contains(.shift) { symbols.append("⇧") }
        if contains(.command) { symbols.append("⌘") }
        return symbols
    }
}

/// Configuration for a keyboard shortcut (key + modifiers)
public struct ShortcutConfig: Codable, Sendable, Equatable {
    public let key: String
    public let modifiers: ShortcutModifiers

    public init(key: String, modifiers: ShortcutModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Display string like "⌘ ⇧ Space"
    public var displayString: String {
        (modifiers.displaySymbols + [key]).joined(separator: " ")
    }

    /// Menu bar key equivalent (lowercase single char or space)
    public var menuKeyEquivalent: String {
        key.lowercased() == "space" ? " " : key.lowercased()
    }

    // MARK: - Defaults

    /// Default timeline shortcut: Cmd+Shift+Space
    public static let defaultTimeline = ShortcutConfig(
        key: "Space",
        modifiers: [.command, .shift]
    )

    /// Default dashboard shortcut: Cmd+Shift+D
    public static let defaultDashboard = ShortcutConfig(
        key: "D",
        modifiers: [.command, .shift]
    )

    /// Default recording shortcut: Cmd+Shift+R
    public static let defaultRecording = ShortcutConfig(
        key: "R",
        modifiers: [.command, .shift]
    )

    /// Default system monitor shortcut: Cmd+Shift+M
    public static let defaultSystemMonitor = ShortcutConfig(
        key: "M",
        modifiers: [.command, .shift]
    )

    /// Default feedback shortcut: Cmd+Shift+H
    public static let defaultFeedback = ShortcutConfig(
        key: "H",
        modifiers: [.command, .shift]
    )

    /// Default push-to-dictate shortcut: Ctrl+Space
    public static let defaultDictation = ShortcutConfig(
        key: "Space",
        modifiers: [.control]
    )
}

// MARK: - Significant Job Observation

/// Independent opt-in for explicit application-owned command lifecycle facts.
/// This setting never enables command discovery, an external ingress, or audio.
public struct JobObservationConfig: Codable, Equatable, Sendable {
    public let enabled: Bool
    public init(enabled: Bool = false) { self.enabled = enabled }
    public static let `default` = JobObservationConfig()
    private enum CodingKeys: String, CodingKey { case enabled }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false)
    }
}

// MARK: - Capture Configuration

/// Configuration for screen capture behavior
/// The new native backend remains an explicit comparison candidate until the
/// installed multi-display/privacy/performance acceptance gates pass.
public enum CaptureBackend: String, Codable, Sendable {
    case legacy
    case screenCaptureKitCandidate
}

public enum CaptureDisplayPolicy: String, Codable, Sendable {
    case allDisplays
    case activeDisplay
}

public struct CaptureConfig: Codable, Sendable {
    /// Independently opt-in, bounded visible Accessibility text captured with pixels.
    public let captureVisibleTextEnabled: Bool
    /// SCK-only durable sampling receipts; independent candidate switch.
    public let captureGroupReceiptsEnabled: Bool
    public let backend: CaptureBackend
    /// Applies to the ScreenCaptureKit candidate. Legacy follows active display.
    public let displayPolicy: CaptureDisplayPolicy
    /// Interval between captures in seconds
    public let captureIntervalSeconds: Double

    /// Whether to enable adaptive capture (skip similar frames)
    public let adaptiveCaptureEnabled: Bool

    /// Similarity threshold for frame deduplication (0-1)
    /// - Frames with similarity > threshold are discarded as duplicates
    /// - Examples:
    ///   - 0.9985 (recommended): discard if more than 99.85% of sampled pixels match
    ///   - 0.997: discard if more than 99.7% of sampled pixels match
    ///   - 0.995 (less sensitive): discard if more than 99.5% of sampled pixels match
    /// - Higher thresholds retain smaller changes; 1.0 disables duplicate filtering
    /// - Default 0.9985 only discards nearly identical frames
    public let deduplicationThreshold: Double

    /// Maximum resolution to capture (will downscale if screen is larger)
    public let maxResolution: Resolution

    /// App bundle IDs to exclude from capture
    public let excludedAppBundleIDs: Set<String>

    /// Whether to exclude private/incognito browser windows
    public let excludePrivateWindows: Bool

    /// Custom patterns to detect private windows (in addition to defaults)
    public let customPrivateWindowPatterns: [String]

    /// Whether to show the mouse cursor in captures (default: true)
    public let showCursor: Bool

    /// Case-insensitive substring patterns for window titles that should be redacted.
    /// Matching frames are kept but replaced with black placeholder pixels.
    public let redactWindowTitlePatterns: [String]

    /// Case-insensitive substring patterns for browser URLs that should be redacted.
    /// Matching frames are kept but replaced with black placeholder pixels.
    public let redactBrowserURLPatterns: [String]

    /// Idle threshold in seconds - if no frames are captured for this duration,
    /// the current segment is closed and a new one is created on the next frame.
    /// This handles cases like screen sleep, lock screen, or extended AFK periods.
    /// Default is 2 minutes (120 seconds). Set to 0 to disable idle detection.
    public let idleThresholdSeconds: Double

    /// Whether to capture immediately when the active window changes (app switch or window focus change).
    /// When enabled, a frame is captured instantly on window change and the regular capture timer resets.
    /// Default is true.
    public let captureOnWindowChange: Bool

    public init(
        captureIntervalSeconds: Double = 2.0,
        adaptiveCaptureEnabled: Bool = true,
        deduplicationThreshold: Double = CaptureConfig.defaultDeduplicationThreshold,
        maxResolution: Resolution = .uhd4K,
        excludedAppBundleIDs: Set<String> = [],
        excludePrivateWindows: Bool = true,
        customPrivateWindowPatterns: [String] = [],
        showCursor: Bool = true,
        redactWindowTitlePatterns: [String] = [],
        redactBrowserURLPatterns: [String] = [],
        idleThresholdSeconds: Double = 120.0,
        captureOnWindowChange: Bool = true,
        backend: CaptureBackend = .legacy,
        displayPolicy: CaptureDisplayPolicy = .allDisplays,
        captureVisibleTextEnabled: Bool = false,
        captureGroupReceiptsEnabled: Bool = false
    ) {
        self.captureIntervalSeconds = captureIntervalSeconds
        self.adaptiveCaptureEnabled = adaptiveCaptureEnabled
        self.deduplicationThreshold = deduplicationThreshold
        self.maxResolution = maxResolution
        self.excludedAppBundleIDs = excludedAppBundleIDs
        self.excludePrivateWindows = excludePrivateWindows
        self.customPrivateWindowPatterns = customPrivateWindowPatterns
        self.showCursor = showCursor
        self.redactWindowTitlePatterns = redactWindowTitlePatterns
        self.redactBrowserURLPatterns = redactBrowserURLPatterns
        self.idleThresholdSeconds = idleThresholdSeconds
        self.captureOnWindowChange = captureOnWindowChange
        self.backend = backend
        self.displayPolicy = displayPolicy
        self.captureVisibleTextEnabled = captureVisibleTextEnabled
        self.captureGroupReceiptsEnabled = captureGroupReceiptsEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case captureIntervalSeconds, adaptiveCaptureEnabled, deduplicationThreshold, maxResolution
        case excludedAppBundleIDs, excludePrivateWindows, customPrivateWindowPatterns, showCursor
        case redactWindowTitlePatterns, redactBrowserURLPatterns, idleThresholdSeconds, captureOnWindowChange
        case backend, displayPolicy, captureVisibleTextEnabled, captureGroupReceiptsEnabled
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            captureIntervalSeconds: try values.decode(Double.self, forKey: .captureIntervalSeconds),
            adaptiveCaptureEnabled: try values.decode(Bool.self, forKey: .adaptiveCaptureEnabled),
            deduplicationThreshold: try values.decode(Double.self, forKey: .deduplicationThreshold),
            maxResolution: try values.decode(Resolution.self, forKey: .maxResolution),
            excludedAppBundleIDs: try values.decode(Set<String>.self, forKey: .excludedAppBundleIDs),
            excludePrivateWindows: try values.decode(Bool.self, forKey: .excludePrivateWindows),
            customPrivateWindowPatterns: try values.decode([String].self, forKey: .customPrivateWindowPatterns),
            showCursor: try values.decode(Bool.self, forKey: .showCursor),
            redactWindowTitlePatterns: try values.decode([String].self, forKey: .redactWindowTitlePatterns),
            redactBrowserURLPatterns: try values.decode([String].self, forKey: .redactBrowserURLPatterns),
            idleThresholdSeconds: try values.decode(Double.self, forKey: .idleThresholdSeconds),
            captureOnWindowChange: try values.decode(Bool.self, forKey: .captureOnWindowChange),
            backend: try values.decodeIfPresent(CaptureBackend.self, forKey: .backend) ?? .legacy,
            displayPolicy: try values.decodeIfPresent(CaptureDisplayPolicy.self, forKey: .displayPolicy) ?? .allDisplays,
            captureVisibleTextEnabled: try values.decodeIfPresent(Bool.self, forKey: .captureVisibleTextEnabled) ?? false,
            captureGroupReceiptsEnabled: try values.decodeIfPresent(Bool.self, forKey: .captureGroupReceiptsEnabled) ?? false
        )
    }

    /// Default deduplication threshold (99.85% similarity)
    /// Frames with similarity >= this threshold are discarded as duplicates
    public static let defaultDeduplicationThreshold: Double = 0.9985

    /// Default patterns for detecting private/incognito windows
    /// NOTE: These are now only used for custom patterns added by users.
    /// The actual detection uses stricter suffix patterns in PrivateWindowDetector
    /// to avoid false positives (e.g., pages with "private" in the title).
    public static let defaultPrivateWindowPatterns: [String] = []

    /// All patterns to check for private windows (default + custom)
    public var allPrivateWindowPatterns: [String] {
        Self.defaultPrivateWindowPatterns + customPrivateWindowPatterns
    }

    public static let `default` = CaptureConfig()
}

public struct Resolution: Codable, Sendable, Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let hd1080 = Resolution(width: 1920, height: 1080)
    public static let qhd1440 = Resolution(width: 2560, height: 1440)
    public static let uhd4K = Resolution(width: 3840, height: 2160)
}

// MARK: - Storage Configuration

/// Independently switchable, lossless original-pixel candidates. Archive HEVC is separate.
public enum OriginalPixelCompression: String, CaseIterable, Codable, Sendable {
    case disabled, lzfse, lz4
}

/// Configuration for data storage
public struct StorageConfig: Codable, Sendable {
    /// Root directory for all stored data
    public let storageRootPath: String

    /// How long to retain data in days (nil = forever)
    public let retentionDays: Int?

    /// Maximum storage size in GB (nil = unlimited)
    public let maxStorageGB: Double?

    /// Duration of each video segment in seconds
    public let segmentDurationSeconds: Int

    /// Default remains V2/raw until representative installed quality/latency acceptance.
    public let originalPixelCompression: OriginalPixelCompression

    public init(
        storageRootPath: String = AppPaths.defaultStorageRoot,
        retentionDays: Int? = 90,
        maxStorageGB: Double? = 50.0,
        segmentDurationSeconds: Int = 300,  // 5 minutes
        originalPixelCompression: OriginalPixelCompression = .disabled
    ) {
        self.storageRootPath = storageRootPath
        self.retentionDays = retentionDays
        self.maxStorageGB = maxStorageGB
        self.segmentDurationSeconds = segmentDurationSeconds
        self.originalPixelCompression = originalPixelCompression
    }

    public static let `default` = StorageConfig()

    private enum CodingKeys: String, CodingKey {
        case storageRootPath, retentionDays, maxStorageGB, segmentDurationSeconds, originalPixelCompression
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            storageRootPath: try values.decode(String.self, forKey: .storageRootPath),
            retentionDays: try values.decodeIfPresent(Int.self, forKey: .retentionDays),
            maxStorageGB: try values.decodeIfPresent(Double.self, forKey: .maxStorageGB),
            segmentDurationSeconds: try values.decode(Int.self, forKey: .segmentDurationSeconds),
            originalPixelCompression: try values.decodeIfPresent(OriginalPixelCompression.self,
                                                                 forKey: .originalPixelCompression) ?? .disabled
        )
    }

    public var expandedStorageRootPath: String {
        NSString(string: storageRootPath).expandingTildeInPath
    }
}

// MARK: - Processing Configuration

/// Configuration for OCR and text processing
public struct ProcessingConfig: Codable, Sendable {
    /// Whether to use Accessibility API for text extraction
    public let accessibilityEnabled: Bool

    /// OCR recognition level (fast vs accurate)
    public let ocrAccuracyLevel: OCRAccuracyLevel

    /// Languages to recognize (ISO codes)
    public let recognitionLanguages: [String]

    /// Minimum confidence threshold for OCR results (0-1)
    public let minimumConfidence: Float

    /// Hint to Vision to prefer background processing (lower resource usage)
    public let preferBackgroundProcessing: Bool

    public init(
        accessibilityEnabled: Bool = true,
        ocrAccuracyLevel: OCRAccuracyLevel = .accurate,
        recognitionLanguages: [String] = ["en-US"],
        minimumConfidence: Float = 0.5,
        preferBackgroundProcessing: Bool = false
    ) {
        self.accessibilityEnabled = accessibilityEnabled
        self.ocrAccuracyLevel = ocrAccuracyLevel
        self.recognitionLanguages = recognitionLanguages
        self.minimumConfidence = minimumConfidence
        self.preferBackgroundProcessing = preferBackgroundProcessing
    }

    public static let `default` = ProcessingConfig()
}

public enum OCRAccuracyLevel: String, Codable, Sendable {
    case fast
    case accurate
}

// MARK: - Audio Capture Configuration

/// Configuration for audio capture behavior
public struct AudioCaptureConfig: Codable, Sendable {
    /// Enable microphone capture (Pipeline A)
    public let microphoneEnabled: Bool

    /// Enable system audio capture (Pipeline B)
    public let systemAudioEnabled: Bool

    /// Enable Voice Processing (Voice Isolation) for microphone
    /// This is non-negotiable as per privacy policy - must always be true
    public let voiceProcessingEnabled: Bool

    /// User has explicitly consented to recording system audio during meetings
    /// When false, system audio is auto-muted when meetings are detected
    public let hasConsentedToMeetingRecording: Bool

    /// Buffer duration for audio chunks in seconds
    public let bufferDurationSeconds: Double

    /// Target sample rate (should be 16000 for AI transcription)
    public let targetSampleRate: Int

    /// Target channels (should be 1 for mono)
    public let targetChannels: Int

    /// Meeting detection bundle IDs to monitor
    public let meetingAppBundleIDs: Set<String>

    /// Independent native evidence comparison. Does not change recording consent.
    public let meetingEvidenceComparisonEnabled: Bool

    public init(
        microphoneEnabled: Bool = true,
        systemAudioEnabled: Bool = false,
        voiceProcessingEnabled: Bool = false,  // No longer used — AVCaptureSession replaces AVAudioEngine
        hasConsentedToMeetingRecording: Bool = false,
        bufferDurationSeconds: Double = 10.0,
        targetSampleRate: Int = 16000,
        targetChannels: Int = 1,
        meetingAppBundleIDs: Set<String> = AudioCaptureConfig.defaultMeetingApps,
        meetingEvidenceComparisonEnabled: Bool = false
    ) {
        self.microphoneEnabled = microphoneEnabled
        self.systemAudioEnabled = systemAudioEnabled
        self.voiceProcessingEnabled = voiceProcessingEnabled
        self.hasConsentedToMeetingRecording = hasConsentedToMeetingRecording
        self.bufferDurationSeconds = bufferDurationSeconds
        self.targetSampleRate = targetSampleRate
        self.targetChannels = targetChannels
        self.meetingAppBundleIDs = meetingAppBundleIDs
        self.meetingEvidenceComparisonEnabled = meetingEvidenceComparisonEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case microphoneEnabled, systemAudioEnabled, voiceProcessingEnabled, hasConsentedToMeetingRecording
        case bufferDurationSeconds, targetSampleRate, targetChannels, meetingAppBundleIDs, meetingEvidenceComparisonEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            microphoneEnabled: try container.decode(Bool.self, forKey: .microphoneEnabled),
            systemAudioEnabled: try container.decode(Bool.self, forKey: .systemAudioEnabled),
            voiceProcessingEnabled: try container.decode(Bool.self, forKey: .voiceProcessingEnabled),
            hasConsentedToMeetingRecording: try container.decode(Bool.self, forKey: .hasConsentedToMeetingRecording),
            bufferDurationSeconds: try container.decode(Double.self, forKey: .bufferDurationSeconds),
            targetSampleRate: try container.decode(Int.self, forKey: .targetSampleRate),
            targetChannels: try container.decode(Int.self, forKey: .targetChannels),
            meetingAppBundleIDs: try container.decode(Set<String>.self, forKey: .meetingAppBundleIDs),
            meetingEvidenceComparisonEnabled: try container.decodeIfPresent(Bool.self, forKey: .meetingEvidenceComparisonEnabled) ?? false
        )
    }

    /// A comparison-only copy; recording and explicit consent are unchanged.
    public func withMeetingEvidenceComparisonEnabled(_ enabled: Bool) -> Self {
        Self(microphoneEnabled: microphoneEnabled, systemAudioEnabled: systemAudioEnabled,
             voiceProcessingEnabled: voiceProcessingEnabled,
             hasConsentedToMeetingRecording: hasConsentedToMeetingRecording,
             bufferDurationSeconds: bufferDurationSeconds, targetSampleRate: targetSampleRate,
             targetChannels: targetChannels, meetingAppBundleIDs: meetingAppBundleIDs,
             meetingEvidenceComparisonEnabled: enabled)
    }

    public static let `default` = AudioCaptureConfig()

    /// Default meeting app bundle IDs to monitor
    public static let defaultMeetingApps: Set<String> = [
        "us.zoom.xos",                    // Zoom
        "com.microsoft.teams2",           // Microsoft Teams
        "com.microsoft.teams",            // Microsoft Teams (legacy)
        "com.google.Meet",                // Google Meet
        "com.webex.meetingmanager",       // Webex
        "com.skype.skype",                // Skype
        "com.discord",                    // Discord
        "com.tinyspeck.slackmacgap",      // Slack
        "us.zoom.ringcentral",            // RingCentral
        "com.cisco.webexteams",           // Webex Teams
    ]
}

// MARK: - Search Configuration

/// Configuration for search behavior
public struct SearchConfig: Codable, Sendable {
    /// Whether semantic search is enabled
    public let semanticSearchEnabled: Bool

    /// Default number of results to return
    public let defaultResultLimit: Int

    /// Minimum relevance score to include in results (0-1)
    public let minimumRelevanceScore: Double

    public init(
        semanticSearchEnabled: Bool = false,
        defaultResultLimit: Int = 50,
        minimumRelevanceScore: Double = 0.1
    ) {
        self.semanticSearchEnabled = semanticSearchEnabled
        self.defaultResultLimit = defaultResultLimit
        self.minimumRelevanceScore = minimumRelevanceScore
    }

    public static let `default` = SearchConfig()
}

// MARK: - App Configuration

/// Complete application configuration
public struct AppConfig: Codable, Sendable {
    public let capture: CaptureConfig
    public let audioCapture: AudioCaptureConfig
    public let storage: StorageConfig
    public let processing: ProcessingConfig
    public let search: SearchConfig

    public init(
        capture: CaptureConfig = .default,
        audioCapture: AudioCaptureConfig = .default,
        storage: StorageConfig = .default,
        processing: ProcessingConfig = .default,
        search: SearchConfig = .default
    ) {
        self.capture = capture
        self.audioCapture = audioCapture
        self.storage = storage
        self.processing = processing
        self.search = search
    }

    public static let `default` = AppConfig()
}
