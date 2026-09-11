# CAPTURE Agent Instructions

You are responsible for the **Capture** module of Retrace. Your job is to implement screen capture using **CGWindowListCapture**, frame deduplication, app metadata extraction, and local microphone/system audio capture.

**Status**: ✅ Screen capture fully implemented using CGWindowListCapture API (legacy, no privacy indicator). Audio capture is implemented for microphone and system audio, with user consent handling and meeting detection.

## Your Directory

```
Capture/
├── CaptureManager.swift           # Main CaptureProtocol implementation
├── ScreenCapture/
│   ├── CGWindowListCapture.swift  # Legacy CGWindowList API wrapper
│   ├── DisplayMonitor.swift       # Track available displays
│   ├── DisplaySwitchMonitor.swift # Detect display changes
│   ├── PrivateWindowMonitor.swift # Detect private browsing
│   └── PermissionChecker.swift    # Screen recording permission
├── Deduplication/
│   ├── FrameDeduplicator.swift    # DeduplicationProtocol implementation
│   └── PerceptualHash.swift       # dHash helper (not used by FrameDeduplicator)
├── Metadata/
│   ├── AppInfoProvider.swift      # Get active app info via NSWorkspace
│   └── BrowserURLExtractor.swift  # Extract URL from browsers (AX API)
├── Audio/
│   ├── AudioCaptureManager.swift  # Dual-source audio capture coordinator
│   ├── AudioFormatConverter.swift # Stateful AVAudioConverter resampling and PCM layout conversion
│   ├── ConsentDialogHelper.swift  # Audio recording consent dialog helpers
│   ├── MeetingDetector.swift      # Meeting-app detection
│   ├── MicrophoneAudioCapture.swift # Microphone capture
│   └── SystemAudioCapture.swift   # System audio capture
└── Tests/
    ├── AccessibilityInspectorTest.swift
    ├── AudioFormatConverterTests.swift
    ├── AudioStreamBufferingPolicyTests.swift
    ├── BrowserURLAppleScriptCoordinatorTests.swift
    ├── CaptureStreamLifecycleTests.swift # Real AsyncStream generation, cancellation and drain regressions
    ├── DeduplicationTests.swift
    ├── TestLogger.swift
    ├── WindowChangeCapturePolicyTests.swift
    └── _future/
        └── PrivateWindowDetectorTests.swift
```

## System Requirements

- **macOS 13.0+** required
- **Apple Silicon only** (M1/M2/M3) - Intel not supported
- **Permissions**: Screen Recording + Accessibility

## Protocols You Must Implement

### 1. `CaptureProtocol` (from `Shared/Protocols/CaptureProtocol.swift`)
- Permission checking
- Start/stop capture
- Frame streaming via `AsyncStream<CapturedFrame>`
- Display info

## Key Implementation Details

### 1. CGWindowListCapture Setup (Current Implementation)

**Why CGWindowListCapture instead of ScreenCaptureKit?**
- No purple privacy indicator
- Works via polling instead of streaming
- Legacy API but still functional on macOS 13+
- Filters excluded apps on EVERY capture

```swift
import Foundation
import CoreGraphics
import AppKit

public actor CGWindowListCapture {
    private var timer: Timer?
    private var isActive = false
    private var currentConfig: CaptureConfig?

    var onFrameCaptured: (@Sendable (CapturedFrame) -> Void)?

    func startCapture(
        config: CaptureConfig,
        frameContinuation: AsyncStream<CapturedFrame>.Continuation,
        displayID: CGDirectDisplayID? = nil
    ) async throws {
        guard !isActive else { return }

        self.currentConfig = config
        self.isActive = true

        self.onFrameCaptured = { frame in
            frameContinuation.yield(frame)
        }

        let targetDisplayID = displayID ?? CGMainDisplayID()

        // Start timer-based capture
        let timer = Timer.scheduledTimer(
            withTimeInterval: config.captureIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                try? await self?.captureFrame(displayID: targetDisplayID)
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func captureFrame(displayID: CGDirectDisplayID) async throws {
        // Get excluded windows
        let excludedWindows = getExcludedWindowIDs(config: currentConfig!)

        // Option 1: Try array-based capture (filters specific windows)
        var cgImage: CGImage?
        if !excludedWindows.isEmpty {
            cgImage = CGWindowListCreateImage(
                .null,
                .optionOnScreenOnly,
                kCGNullWindowID,
                .bestResolution
            )
        }

        // Option 2: Fallback to full capture with manual masking
        if cgImage == nil {
            cgImage = CGWindowListCreateImage(
                .null,
                .optionOnScreenOnly,
                kCGNullWindowID,
                .bestResolution
            )
        }

        guard let image = cgImage else {
            throw CaptureError.captureSessionFailed(underlying: "Failed to capture")
        }

        // Convert to frame data
        let frame = try convertToFrame(image: image, displayID: displayID)
        onFrameCaptured?(frame)
    }

    private func getExcludedWindowIDs(config: CaptureConfig) -> [CGWindowID] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] else {
            return []
        }

        var excluded: [CGWindowID] = []

        for window in windowList {
            // Check if window belongs to excluded app
            if let ownerName = window[kCGWindowOwnerName] as? String,
               config.excludedAppBundleIDs.contains(where: { ownerName.contains($0) }) {
                if let windowID = window[kCGWindowNumber] as? CGWindowID {
                    excluded.append(windowID)
                }
            }

            // Check for private browsing windows
            if let windowName = window[kCGWindowName] as? String {
                if windowName.contains("Private") || windowName.contains("Incognito") {
                    if let windowID = window[kCGWindowNumber] as? CGWindowID {
                        excluded.append(windowID)
                    }
                }
            }
        }

        return excluded
    }

    func stopCapture() async throws {
        timer?.invalidate()
        timer = nil
        isActive = false
    }
}
```

### 2. Permission Checking

```swift
public struct PermissionChecker {
    public static func hasScreenRecordingPermission() -> Bool {
        // Check by attempting to get window list
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        return windowList != nil
    }

    public static func requestPermission() {
        // Trigger permission dialog by attempting capture
        _ = CGWindowListCreateImage(
            CGRect.null,
            .optionOnScreenOnly,
            kCGNullWindowID,
            .bestResolution
        )
    }
}
```

### 3. Frame Deduplication

`FrameDeduplicator` implements `DeduplicationProtocol` with sampled RGB pixel comparison, not the separate `PerceptualHash` dHash helper. Its hash method is a sampled RGB checksum; it does not guarantee unique hashes for different images.

- Compare a uniform grid of pixels. A pixel matches only when each RGB channel differs by less than 13; similarity is the matching fraction.
- Always retain the first frame and frames with changed dimensions.
- Retain a same-size frame when `similarity <= threshold`. Higher thresholds preserve smaller changes; threshold 1 records every frame, matching the settings slider.
- `DeduplicationTests` renders deterministic BGRA fixtures through CoreGraphics and checks color tolerance, exact threshold boundaries, small edited regions, dimensions and full-HD performance.
- Deduplication percentages depend on the workload; they are not guaranteed storage savings.

### 4. App Info Provider

Extract metadata about the frontmost application:

```swift
import AppKit
import ApplicationServices

public struct AppInfoProvider {
    public func getFrontmostAppInfo() -> AppInfo? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let bundleID = frontApp.bundleIdentifier ?? ""
        let name = frontApp.localizedName ?? ""

        // Get window title via Accessibility API (requires permission)
        let windowTitle = getWindowTitle(for: frontApp.processIdentifier)

        // Get browser URL if applicable
        var browserURL: String?
        if ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.brave.Browser"].contains(bundleID) {
            browserURL = BrowserURLExtractor().getURL(bundleID: bundleID, pid: frontApp.processIdentifier)
        }

        return AppInfo(
            bundleID: bundleID,
            name: name,
            windowTitle: windowTitle,
            browserURL: browserURL
        )
    }

    private func getWindowTitle(for pid: pid_t) -> String? {
        let appRef = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let window = windowValue else {
            return nil
        }

        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
              let title = titleValue as? String else {
            return nil
        }

        return title
    }
}
```

### 5. Browser URL Extraction

Extract active URL from Safari, Chrome, Firefox, etc. using Accessibility API:

```swift
public struct BrowserURLExtractor {
    public func getURL(bundleID: String, pid: pid_t) -> String? {
        switch bundleID {
        case "com.apple.Safari":
            return getSafariURL(pid: pid)
        case "com.google.Chrome", "com.brave.Browser":
            return getChromeURL(pid: pid)
        case "org.mozilla.firefox":
            return getFirefoxURL(pid: pid)
        default:
            return nil
        }
    }

    private func getSafariURL(pid: pid_t) -> String? {
        // Navigate Accessibility hierarchy to find URL field
        // Safari: Window → Toolbar → URL text field
        // Implementation depends on Safari's AX structure
        return nil
    }

    private func getChromeURL(pid: pid_t) -> String? {
        // Chrome: Window → Address bar
        return nil
    }
}
```

### 6. Excluded Apps Configuration

Default apps to exclude from capture:

```swift
public static let defaultExcludedApps: Set<String> = [
    "com.agilebits.onepassword7",
    "com.bitwarden.desktop",
    "com.lastpass.LastPass",
    "app.getdash.dash",
    "com.apple.SecurityAgent",
    "com.apple.loginwindow"
]
```

### 7. Private Window Detection

Detect and exclude private browsing windows:

```swift
public actor PrivateWindowMonitor {
    public func isPrivateWindow(windowInfo: [CFString: Any]) -> Bool {
        guard let windowName = windowInfo[kCGWindowName] as? String else {
            return false
        }

        // Safari: "Private Browsing"
        // Chrome: "Incognito"
        // Firefox: "Private Browsing"
        return windowName.contains("Private") ||
               windowName.contains("Incognito") ||
               windowName.contains("InPrivate")
    }
}
```

## Audio Conversion Lifecycle

- Microphone and system callbacks each own a separate `AudioFormatConverter` instance and call `convert(sampleBuffer:)` on their existing background sample queues.
- Copy PCM using `CMSampleBufferCopyPCMDataIntoAudioBufferList` with the actual `AVAudioFormat`; preserve planar/interleaved channel layout and real integer/float format.
- Retain `AVAudioConverter` state across callback buffers. Use `.noDataNow` between buffers, native high-quality resampling, and downmix to 16 kHz mono Int16. Do not recreate the converter or end its stream for each packet.
- Publish only actual output frames, calculating duration from emitted PCM bytes. Empty output while the resampler primes is normal.
- A failed conversion clears filter history and the pending timestamp; the next valid packet starts fresh. Failed microphone startup throws and closes its stream. Source teardown also closes preacquired streams when the device never started.
- Source shutdown drains the converter with `finish()` before finishing the source stream. The coordinator acquires source streams before scheduling forwarders and awaits both forwarders before finishing the combined stream. Restart and system-audio muting discard pending samples with `reset()` to prevent crossing privacy boundaries.
- Converter and delegate locks protect background callback/shutdown transitions. Never call this synchronous conversion work from UI rendering or the main thread.
- `AudioFormatConverterTests` exercises real AVFoundation/CoreMedia buffers for anti-alias filtering, irregular chunk continuity, channel layouts, format changes, and finite drain behavior. Wall-clock timestamp semantics remain unchanged; source-clock mapping is a separate integration change.

## Capture Manager Pipeline

- `CaptureManager` owns each raw/output stream pair and its forwarding task through `CaptureFrameStreamSession`.
- Every worker yields to and finishes its own output continuation. Never read a mutable current-generation continuation after an async metadata lookup or when an older raw stream ends.
- Starting/stopping capture is serialized across actor suspension points. Stop cancels the frame worker, finishes its raw input, and awaits completion before lifecycle teardown returns, including source-stop errors.
- Check worker cancellation after metadata awaits before publishing pixels or changing capture statistics. Natural input completion drains accepted frames; capture cancellation discards unfinished work at the privacy boundary.
- Display switches reuse the existing raw/output session. Their source stop/start operations enter the same lifecycle queue and recheck the captured session after admission; a stopped or replaced session cannot restart capture through a stale display-switch callback.
- `CaptureStreamLifecycleTests` uses real AsyncStreams, CoreGraphics-rendered frames, and suspended metadata work to exercise old-worker completion during replacement, stop/join ordering, natural drain behavior, and serialized display-switch admission after a suspended lifecycle operation.

## Error Handling

Use errors from `Shared/Models/Errors.swift`:

```swift
throw CaptureError.permissionDenied
throw CaptureError.noDisplaysAvailable
throw CaptureError.captureSessionFailed(underlying: error.localizedDescription)
```

## Testing Strategy

1. ✅ Permission checking (has/request)
2. ✅ Frame capture with CGWindowListCreateImage
3. ✅ Deduplication with similar/different images
4. ✅ Hash computation consistency (same frame = same hash)
5. ✅ App info extraction (mock NSWorkspace)
6. ✅ Excluded apps filtering
7. ✅ Private window detection

## Dependencies

- **Output to**:
  - STORAGE module (CapturedFrame for HEVC encoding)
  - PROCESSING module (CapturedFrame for OCR extraction)
- **Uses types**: `CapturedFrame`, `FrameMetadata`, `CaptureConfig`, `CaptureStatistics`

## DO NOT

- ❌ Modify files outside `Capture/` directory
- ❌ Import from other module directories (only `Shared/`)
- ❌ Handle video encoding (that's STORAGE's job)
- ❌ Handle OCR or text extraction (that's PROCESSING's job)
- ❌ Store frames to disk (that's STORAGE's job)
- ❌ Transcribe audio (that's PROCESSING's job)

## Performance Targets

- **Capture latency**: <50ms from trigger to frame available
- **Deduplication**: <5ms per frame comparison
- **Memory**: Don't hold more than 2-3 frames in memory
- **CPU**: <10% during capture (mostly idle between 2-second intervals)
- **Deduplication rate**: ~95% of frames filtered as duplicates

## Current Limitations

- CGWindowListCapture has no streaming API (polling only)
- Limited private window detection (heuristic-based)
- No multi-display support optimizations

## Getting Started

1. Read `CGWindowListCapture.swift` - main capture implementation
2. Read `FrameDeduplicator.swift` for active pixel comparison; `PerceptualHash.swift` is a separate unused dHash helper
3. Read `AppInfoProvider.swift` - metadata extraction
4. Read `CaptureManager.swift` - protocol conformance + pipeline

The implementation is complete. Focus on understanding the existing code rather than rewriting.
