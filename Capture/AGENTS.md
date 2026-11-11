# CAPTURE Agent Instructions

You are responsible for the **Capture** module of Retrace. Your job is to implement screen capture using **CGWindowListCapture**, frame deduplication, app metadata extraction, and local microphone/system audio capture.

**Status**: Legacy CGWindowListCapture remains the default. An independently selected ScreenCaptureKit candidate observes bounded persistent native display streams; installed privacy, sharpness, sleep/wake and performance acceptance remains pending. Audio capture is implemented for microphone and system audio, with user consent handling and meeting detection.

## Your Directory

```
Capture/
├── CaptureManager.swift           # Main CaptureProtocol implementation
├── ActivityMonitor.swift          # Independent bounded activity observation and durable coverage events
├── ScreenCapture/
│   ├── CGWindowListCapture.swift  # Legacy CGWindowList API wrapper
│   ├── LegacyCaptureAPI.swift    # Typed Swift boundary for runtime legacy comparison APIs
│   ├── ScreenCaptureKitCapture.swift # Opt-in persistent-stream observation cycles, current privacy checks and backend router
│   ├── ScreenCaptureStreamPool.swift # Inert bounded per-display SCStream ownership, native-time proofs and joined cleanup
│   ├── CapturePrivacyMask.swift  # Fail-closed full-window masks at native pixel scale
│   ├── CaptureCoverage.swift     # Content-free gap/recovery transition callback
│   ├── CaptureGroupDelivery.swift # Bounded awaited sampling/member journal transitions
│   ├── CaptureDisplayAttachmentTracker.swift # Mode/attachment notification lifetimes and reserved pixel attempts
│   ├── DisplayMonitor.swift       # Track available displays
│   ├── DisplaySwitchMonitor.swift # Detect display changes
│   ├── PrivateWindowMonitor.swift # Detect private browsing
│   └── PermissionChecker.swift    # Screen recording permission
├── LegacyBridge/
│   ├── LegacyCaptureBridge.c     # Resolves existing public CoreGraphics capture symbols for the baseline and live preview
│   └── include/CaptureLegacyBridge.h # Owned-image C ABI; missing APIs return unavailable
├── Deduplication/
│   ├── FrameDeduplicator.swift    # DeduplicationProtocol implementation
│   ├── DirectTextDeduplication.swift # Validated exact text/geometry change retention; pixel-only sensitivity unchanged
│   ├── ExactFrameReuse.swift       # Full-pixel equality plus metadata/direct-text consistency for grouped reuse
│   └── PerceptualHash.swift       # dHash helper (not used by FrameDeduplicator)
├── Metadata/
│   ├── AppInfoProvider.swift      # Get active app info via NSWorkspace
│   ├── CaptureAttribution.swift   # Capture-time sequencing and system context adapter boundary
│   ├── CaptureNotificationFence.swift # Capture-owned synchronous workspace/AX attribution fence
│   ├── CaptureTextPixelPlan.swift # Exact native pixel-plan composition and attempt receipts
│   ├── CaptureVisibleTextReader.swift # Bounded opt-in same-window AX bracket; secure/hidden/occluded content denied
│   └── BrowserURLExtractor.swift  # Extract URL from browsers (AX API)
├── Audio/
│   ├── AudioCaptureManager.swift  # Dual-source audio capture coordinator
│   ├── AudioFormatConverter.swift # Stateful AVAudioConverter resampling and PCM layout conversion
│   ├── ConsentDialogHelper.swift  # Audio recording consent dialog helpers
│   ├── MeetingDetector.swift      # Owned polling, bounded confidence states and joined evidence delivery
│   ├── MeetingAssessmentReducer.swift # Validated observations, freshness and independent audio privacy policy
│   ├── MeetingNativeEvidence.swift # Process lifetime/readonly Core Audio evidence and bounded app inventory
│   ├── MeetingCallControls.swift  # Opt-in visible native call-control observation with AX mutation fences
│   ├── MicrophoneAudioCapture.swift # Microphone capture
│   └── SystemAudioCapture.swift   # System audio capture
└── Tests/
    ├── AccessibilityInspectorTest.swift
    ├── AudioFormatConverterTests.swift
    ├── AudioStreamBufferingPolicyTests.swift
    ├── MeetingDetectorTests.swift # Retained observation sequences, audio privacy and real stream lifecycle
    ├── MeetingNativeEvidenceTests.swift # Own-process HAL reads and opt-in owned AppKit control fixtures
    ├── ActivityContextPrivacyTests.swift
    ├── ActivityApplicationIdentityTests.swift # Directly launched nonactivating native apps, process lifetimes and unknown-notification attribution
    ├── ActivityObservationBufferTests.swift # Bounded delivery, privacy and notification-revision admission
    ├── ActivityMonitorAttributionTests.swift # Real SQLite/native-window AX route, stable visits, navigation and stale enrichment
    ├── ActivityMonitorLatencyTests.swift # Real SQLite acknowledgement timing and failed-append metric suppression
    ├── InstalledActivityAdapterTests.swift # Opt-in native adapter/observer acceptance using actual visible applications; bounded temporary SQLite only
    ├── BrowserURLAppleScriptCoordinatorTests.swift
    ├── CaptureStreamLifecycleTests.swift # Real AsyncStream generation, cancellation and drain regressions
    ├── CaptureConfigurationAdmissionTests.swift # Real SQLite policy claims/receipts across serialized native-source configuration boundaries
    ├── CaptureMetadataRetentionTests.swift # CoreGraphics/stream regression for delayed metadata attribution
    ├── CaptureContextSequencingTests.swift # Pixel capture bracketed by identity, notification revision and lifecycle admission
    ├── CaptureVisibleTextTests.swift # Owned AppKit/AX/screenshot fixture, native mutations, visibility and joined cancellation
    ├── CaptureDirectTextDeduplicationTests.swift # Native CoreText/AsyncStream text-change retention and invalid/unavailable fallback
    ├── ScreenCaptureKitCandidateTests.swift # Real pixels/streams for all-display isolation, privacy masks, removal, cancellation and bounded delivery
    ├── ScreenCaptureStreamPoolTests.swift # Authored native CVPixelBuffer/CMSampleBuffer proofs, idle reuse, bounds and joined lifecycle
    ├── ExactFrameReuseTests.swift # Exact grouped reuse, changed pixels and context/text invalidation
    ├── CaptureSamplingGroupTests.swift # Durable begin/outcome ordering, native attachment identity and joined stream/journal failures
    ├── ObservedWindowGenerationTests.swift # Real WindowServer identity and process/session generation invalidation
    ├── DeduplicationTests.swift
    ├── SemanticPixelDeduplicationTests.swift # Reviewed JPEG/native text edits, SIMD/noise/stride regressions and opt-in resolution benchmarks
    ├── TestLogger.swift
    ├── WindowChangeCapturePolicyTests.swift
    └── _future/
        └── PrivateWindowDetectorTests.swift
```

## System Requirements

- **macOS 26.0+** required by the application target; imported archives retain their existing readers
- **Apple Silicon only** (M1/M2/M3) - Intel not supported
- **Permissions**: Screen Recording + Accessibility

## Protocols You Must Implement

### 1. `CaptureProtocol` (from `Shared/Protocols/CaptureProtocol.swift`)
- Permission checking
- Start/stop capture
- Frame streaming via `AsyncStream<CapturedFrame>`
- Display info

## Key Implementation Details

### Meeting evidence comparison and audio consent

- `AudioCaptureConfig.meetingEvidenceComparisonEnabled` defaults to false and missing saved fields decode false. Presence-only baseline monitoring can report possible or fresh complete absence; Teams/Zoom/Slack running, an active app or a profile photo never means a supported active call. The native comparison is unpromoted until reviewed app/OS fixtures and foreground/energy measurements pass.
- Active support requires visible enabled pressable leave/end and explicit microphone controls in one uniquely matched native window, plus public Core Audio process-input IO from the same kernel-checked PID lifetime. `kAudioProcessPropertyIsRunningInput` means active input IO, not necessarily a physical microphone or a meeting. Generic device usage and global speech never establish app ownership. Prejoin controls and input silence do not end a potentially hidden call; initial affirmative end evidence is exact process exit/replacement. Possible/support/end observation dates remain distinct.
- Only already-produced transcription or speech-like-energy decisions may be supplied. The actual decision-read interval and original batch wall-clock occurrence are separate; no original audio uptime is fabricated. Bounds reject malformed/future dates, occurrence duration over 60 seconds, age over 45 seconds, unproved app joins and more than four exact evidence references. Energy remains labelled energy. Delayed speech never activates a call on its own.
- Native app inventory is bounded to 32 configured bundles and 16 processes; properties run on a utility queue. One poll/read chain is owned and joined, including synchronous Core Audio work that offers no public timeout. AX is separately capped at 128 nodes, depth 10, 16-child pages, 256 UTF-16 label units and 200 ms combined active pre/post work, with per-handle 25 ms messaging limits and a 2-second bracket ceiling. Scheduling/native IPC are not hard-real-time guarantees. Budget/permission/provider/visibility failures remain explicit uncertainty.
- Controls require known safe ancestry, complete bounded clipping/sibling/window occlusion inventory, role/action/enabled proof and mandatory value/title/layout/move/destroy notification fencing. Hidden structural nodes are retained only for visibility revalidation. Secure/text-field/unknown subtrees never supply labels; ordinary window titles/profile text do not count as controls. Labels are ephemeral and never enter observations, logs or metrics. Existing exclusion/private-browser masking rules run before AX; capture-owned policy revision plus canonical hash brackets reads so A→B→A cannot restore permission.
- Meeting confidence and audio consent are independent. Unknown, possible, stopped, expired or legacy bool-only states keep system audio protected without consent. Audio is pre-muted before native source start, freshness is checked again before PCM forwarding, and callbacks are awaited instead of spawning one task per event. Only a fresh complete candidate-absence inventory releases protection without consent; presence-only baseline can supply that proof. Existing explicit consent remains authoritative; detector signals never enable a disabled microphone/system source.
- App owns content-free `MeetingDetectionOutcome` daily metrics and must finish its bounded delivery after audio/detector stop joins, before closing SQLite. Outcomes include categorical phase/reasons, bounded candidate/node counts and elapsed time only. `capture.meeting_evidence` latency is diagnostic; own-process native probes and source review do not establish accuracy, CPU, energy or p95 acceptance.
- `MeetingNativeEvidenceTests` reads HAL metadata only for its own process. Visible AX fixtures require explicit `RETRACE_MEETING_AX_FIXTURE=1` and already-granted AX/Screen Recording; they compile/launch only an authored private AppKit helper, never activate or inspect user applications, start audio or prompt. Failed startup stops/joins the helper and removes its private tree. Native unsupported capability skips are not positive acceptance.

### Capture attribution and activity observation

- Capture-time direct text is separately opt-in (`captureVisibleTextEnabled`, default false). It is never supplied by the later Processing whole-application AX helper. The native pixel include list/masks are prepared first, followed by bounded AX pre-read, one native pixel call and same-element/range/UTF-16/geometry postvalidation. Every retained observation binds the exact attempt UUID and actual native pixel interval; source/context/policy/notification fences still surround the entire operation. The statement is `sameWindowBracketed`, never atomic or pixel equality.
- The initial reader admits only supported AXTextArea/AXStaticText ranges in the proved focused window. Secure/text-field/unknown subtrees are never read for content. WindowServer identity must have exactly one public title/PID/geometry match and the actual pixel plan must include that ID. Full range bounds must fit known ancestor clipping/display bounds and avoid all known sibling/higher-window/mask rectangles. A point hit test is supplemental; incomplete security/clipping/occlusion inventory invalidates the observation. Unsupported window-title proxies remain outside the direct-text channel.
- Bounds are 256 nodes, depth 12, child pages 16, 128 runs, 8,192 UTF-16 units and 32 KiB canonical Shared validation. AX calls use each exact handle's timeout (at most 25 ms), with a 150 ms combined pre/post read budget. Deadlines are checked after calls too; OS scheduling is not a hard-real-time guarantee. Content-limit omissions can be partial, while truncated visibility inventory, observer loss, source/text mutation or cancellation retain no runs. No raw captured text enters metrics.
- One owned native run-loop thread receives value/layout/destroy notifications during each enabled attempt. Cleanup removes all registrations before the joined completion. SCK joins its cycle; enabled legacy owns and joins its text/pixel task on stop/configuration invalidation. Failed legacy array capture defers fallback until a new attempt/AX bracket. Disabled legacy retains its existing comparison behavior and carries no fabricated exact-pixel receipt.
- `CaptureVisibleTextTests` launches only its authored accessory helper and captures only its owned windows. Already-granted AX/Screen Recording permission is required; tests never prompt. Native A→B→A delivery, scrolling/occlusion, secure/hidden/offscreen elements, range encoding and teardown require scoped test receipts. Source compilation or a capability probe alone does not establish positive direct-text, installed accuracy, CPU or p95 acceptance.
- The owned text fixture acknowledges its exact PID/window ID before bounded WindowServer readiness checks. Graphical-session failure remains a failed native precondition with content-free diagnostics. A prelaunch termination handler and coalesced bounded cleanup replace blocking `Process.waitUntilExit`; forced termination or a missing receipt is a test failure. Concrete frame-source lifecycle/handler witnesses are explicitly `async`, matching the protocol so direct actor calls cannot select an empty async default.

- Native application snapshots share a MainActor registry of at most 256 observed process lifetimes, matched by `NSRunningApplication.isEqual` and the captured positive PID. LaunchServices launch dates are optional. Terminated handles and changed PIDs are refused; eviction replaces only the least recently used token. Keep this registry independent of ordinary window/focus/lifecycle resets. Diagnostics use fixed current/workspace/AX route and availability codes, with bounded counts for transitions suppressed during the 30-second emission interval. The production diagnostic writer runs on a dedicated utility serial queue; file locks and rotation must stay off MainActor and the cooperative executor.
- An unavailable focus notification remains a content-free `notified-app-unavailable` gap at its observation time. Explicit reconciliation can sample the current application and records a fresh sample; it must not relabel an unidentified historical notification as a later application.
- `CGWindowListCapture` brackets the actual pixel read with permitted process, observed window generation, document, and display samples. A bounded, opaque signature of the visible window inventory also guards background-window privacy changes. Unknown or changing context drops that capture; the next scheduled capture can retry. Redacted pixels retain the reason and display only.
- `CaptureManager` preserves the metadata attached to those pixels. Delayed forwarding must never replace historical metadata with the current frontmost app or window.
- `CaptureManager` serializes historical-evidence admission initialization, explicit/current-configuration startup, runtime settings, owner shutdown and display-source changes on the same lifecycle queue. Admitted configuration changes durably prepare an inactive epoch before assignment or native permission/source awaits and activate only the exact successfully applied transition. Failure or cancellation joins exact-token revocation; failed startup also joins source/stream cleanup. A cancelled queued caller owns no transition and cannot revoke another configuration. Recording pause preserves historical authority; application-owner shutdown ends it independently of whether capture is running. App installs a fresh owning session after opening SQLite. Standalone managers without the injected admission bridge grant no derived authority.
- `CaptureConfigurationAdmissionTests` exercises that handoff with a real in-memory SQLite database and authored CoreGraphics/AsyncStream input. The Capture-internal source and lifecycle environment replace only native permission/display/device boundaries, so these tests never start screen timers or inspect user applications. Policy decisions use the production database; held acknowledgements follow actual commits. Cases cover startup/runtime failure, permission denial, cancellation before admission and after activation commit, A→B→A, fresh writer incarnations, current-configuration queue ordering, hardware-free initialization and ordinary pause.
- At default/high deduplication sensitivity, a frame that the coarse pixel grid would discard also receives a bounded local high-contrast check. Native 16-byte SIMD operations create a changed-pixel bit mask for each 32px tile row; six adjacent pairs over three rows retain the frame. The exact RGB contrast cutoff remains 48, with alpha ignored. Both paths honor `bytesPerRow`, including unaligned rows and omitted final padding; low-contrast differences and isolated pixel noise remain suppressible. Lower sensitivity keeps the existing threshold behavior. This is pixel-change detection, not a guarantee that every semantic edit can be recognized.
- `ActivityMonitor` observes activity independently from screenshot admission. Notifications first preserve safe app-level identity; a later window or AX sample has its own sampling time and provenance. The bounded stream records loss, administrative changes, permission/observer failure, and recovery as explicit coverage events.
- Native activity AX callbacks retain the registration's immutable process snapshot and token. They do not query `NSWorkspace`, `NSRunningApplication`, or LaunchServices. Every notification synchronously advances the pixel-attribution revision, while consecutive pending callbacks coalesce without crossing workspace/lifecycle/enrichment events. Both enqueue and asynchronous consumption reject retired registrations; an AX event is not an application activation. One bounded refresh consumer owns native observer setup and joins it on stop, retaining the refcon through run-loop removal. Native helper-process/SQLite and AsyncStream regressions cover stale ownership, retirement, 10,000-notification bursts and refresh backpressure. The installed 2609.18.1 stack sample is diagnostic evidence only; candidate CPU/p95 acceptance remains pending.
- Title/move AX callbacks retain the observed window generation and its observer subscription. Focus, destruction, and lifecycle boundaries invalidate that generation; periodic reconciliation still restores observer coverage. Every relevant callback also advances a separate ephemeral notification revision across metadata/pixel sampling, including A → B → A transitions that return to identical context after the observation queue drains.
- Window samples and AX document enrichment retain their notification revision through enqueue and consumption. Stale reads cannot become current just because the app, title, generation, and related event still match. One document read may run at a time; later signals retain one pending resample so unchanged titles cannot suppress real document navigation. That retry samples the current application through reconciliation and retains `document-enrichment-retry` provenance; it never replays an older application snapshot as a new activation.
- `activity.notification_to_durable` measures monotonic elapsed time from observation through successful store acknowledgement. The stored `persistedAt` timestamp precedes transaction writes/commit and is not a durable-latency endpoint. `ActivityMonitorLatencyTests` holds a real SQLite writer's acknowledgement and checks failed-append suppression; installed latency percentiles remain a separate acceptance measurement.
- Exact frame links require the currently durable activity event and matching process, observed window generation, document, pane, display, and capture time. Pending observations, dropped events, pause, exclusion changes, and stale enrichment invalidate that link; nearest-time matching is prohibited.
- Native enrichment reads a stable, uniquely matched focused AX window's `AXDocument`. URLs and labels pass through `CapturedURLPolicy`; document navigation identifiers are opaque hashes. Generic support does not establish app-specific acceptance: Word, Excel, ChatGPT, Codex, Claude Chat/Cowork/Code, Cursor editor/Agents, Finder, browser, and meeting workflows still require installed-app fixtures and manual acceptance.
- `ActivityMonitorAttributionTests` uses real SQLite with controlled external observation/AX boundaries. Pixel sequencing and deduplication fixtures use CoreGraphics, CoreText, and ImageIO. These tests do not establish live notification latency, matched Timely behavior, or production capture overhead; those measurements remain separate acceptance checks.
- `ActivityApplicationIdentityTests` compiles authored temporary AppKit helpers and launches their executables directly with activation prohibited. Native handles establish missing-launch-date and missing-bundle cases, separate concurrent/restarted lifetimes, delayed repeated sampling, termination and bounded eviction. In-memory SQLite verifies unavailable-notification and fresh-reconciliation provenance. A held real-file writer verifies that native snapshots and MainActor remain responsive through the production diagnostic delivery helper. Helper termination observation is registered before launch; repeated cleanup joins one actual exit receipt and requires exit status zero.
- Its `ActivityAXNotificationRegressionTests` call the actual AX notification handler with genuine offscreen, nonactivating native window identities and temporary same-title RTF documents. They cover repeated title/move noise, same-title document and two-window navigation, queue-drained pixel round trips, stale enrichment before enqueue and during consumption, and held-read retries across later app changes or missing activation callbacks. A narrow internal async join snapshots only the current enrichment task so retry races are deterministic without timing sleeps. The generated windows never activate or control user applications.

### ScreenCaptureKit comparison candidate

- `captureGroupReceiptsEnabled` is an independent default-off candidate setting. Legacy frames remain ungrouped. `CaptureManager` requires an injected canonical `CaptureGroupJournalProtocol` for grouped sampling; the same native store owns policy and group admission. The source stays gated until the manager acknowledges active policy and establishes its processing boundary. Durable group begin creates all target attempts before any AX/pixel read; prepared policy never authorizes sampling.
- `CaptureDisplayAttachmentTracker` owns a public CoreGraphics reconfiguration callback, bounded to 64 display identities. Live inventory uses online/attached displays; sleeping displays stay explicit unread targets rather than disappearing as inactive. Callback work only invalidates locked state. Monitor UUID, bounds, pixels, refresh/mode and source session identify the observed attachment; removal, mode changes, notifications and restart rotate its ID. Native begin/end notifications fence in-progress and A→B→A reconfiguration. Callback registration failure denies grouped capture. Physical multi-display sleep/wake/removal acceptance remains separate.
- Each successful frame carries its reserved group/member/attachment identity plus its own actual pixel receipt. Group enumeration time is not a common screenshot timestamp. Unread, excluded, asleep or cancelled targets have no fabricated read interval. The native read callback retains the real interval even if later privacy/context validation rejects the pixels.
- `CaptureGroupDelivery` retains at most eight groups of 64 members and awaits every durable event. Candidate acknowledgement precedes forwarding; sampling-ended does not finalize downstream admission. Similarity requires the exact earlier cached member and pixel receipt in the same session/configuration/attachment, verified again by the journal. A deleted/unavailable anchor keeps fresh current pixels. Buffer drops and cancellation have explicit outcomes. Failed writes retain bounded exact envelopes for idempotent ACK-loss retry during joined stop; remaining uncertainty stays durable pending and propagates a stop error. Dead local entries are retired only after producers join, so a healthy restart cannot exhaust the old delivery cap. Journal failure stops native work through one owned shutdown task, finishes streams and reports `groupJournalUnavailable`; later starts and stops join that task. App owns truthful lifecycle shutdown outside the consumer it will join, durable media outcomes and content-free daily metrics.
- `CaptureSamplingGroupTests` uses actual CoreGraphics rasters, production AsyncStreams and a private fsynced JSONL journal for begin/activation ordering, exact suppression, deleted anchors, attachment change/removal, cancellation, missing native reads and bounded delivery. The policy-activation regression in `CaptureConfigurationAdmissionTests` holds acknowledgement after a real private SQLite commit. Native observer registration is checked without changing displays or reading desktop pixels. These are scoped source/fixture checks, not installed quality or performance acceptance.

- `CaptureConfig.backend` defaults to `.legacy`; absent new Codable fields preserve old saved configurations. Candidate `displayPolicy` defaults to `.allDisplays`. The active-display policy is available for matched comparison.
- `ScreenCaptureKitCapture` uses lazy persistent `SCStream` sessions behind the same independent candidate setting. Construction is inert; start/stop/configuration and grouped admission own the stream pool. Fresh permission, native allowed-window inventory, privacy masks and the context/AX bracket still run for every delivered observation. Notification-revision/filter/window-geometry changes replace the stream instead of reusing uncertain pixels. The pool bounds configured displays to eight and latest immutable BGRA payloads to 256 MiB; native buffers and short-lived reader copies are additional memory. Capacity failure is an explicit gap.
- Native streams use physical resolution, SDR sRGB BGRA, no audio, the documented minimum queue depth of three and a minimum frame interval clamped to 0.25–1 second so the next proof can arrive inside the existing two-second context bracket. Native surface memory is additional to the single retained app mailbox image. Delivery remains at configured observation intervals. This low-rate candidate still requires matched CPU/WindowServer energy acceptance; streaming alone is not a performance result.
- `ScreenCaptureStreamPool` accepts native complete frames and reuses its immutable image only on a fresh `SCFrameStatus.idle` event from the same stream key/session. Native mach-absolute display time must fall after the requested read boundary; callback arrival time alone does not prove freshness. Started events clear prior pixels and wait for a complete frame. Blank/suspended/stopped, malformed buffers, native errors and the 1.25-second proof timeout are unavailable. Missing callbacks never imply unchanged pixels. Dirty rectangles are not equality proof; grouped reuse separately verifies complete pixels and metadata.
- The native adapter copies pitched CVPixelBuffer rows into a packed immutable BGRA image and releases the native sample at callback return. The existing privacy-mask/BGRA conversion remains a separate downstream copy; this implementation does not claim a zero-copy pipeline. Cancellation joins uninterruptible native start completion, closes the bounded mailbox, stops the stream and drains its serial callback queue. Failed cleanup retains ownership for retry and prevents silent replacement. Physical display identity is rechecked after every read; removed/sleeping displays and obsolete filters are retired. Individual display receipts never fabricate simultaneous capture.
- `CaptureSnapshotSequencer` preserves its focused-window guard. Its explicit candidate-only display receipt permits safe unknown app/window metadata for a nonfocused display, with the same inventory, notification-revision, cancellation and monotonic bracket checks. Candidate pixel metadata must match the requested display. Unknown focus never inherits another display's app context.
- Every new live frame from both backends carries the canonical privacy-policy SHA-256 from the same configuration used around its pixels. Context reconstruction preserves the digest even for display-only frames. Shared evidence admission requires an exact current-policy match when present, so a later background-app exclusion cannot be bypassed through missing foreground metadata. Storage owns full-metadata WAL durability; old nil-digest archives retain legacy compatibility and do not establish complete window-composition proof.
- Candidate pixels reuse legacy exclusions and BGRA conversion, with fail-closed full-window bounds masks, outward-rounded native edges and no opaque-occlusion assumption. Unknown owners are masked. All browser windows are masked when private-window exclusion or URL rules are enabled; all windows are masked under nonempty title-redaction rules until per-window notification proof is available. A public-looking title cannot prove a background window stayed permitted during a screenshot. Mask failures discard pixels. Legacy masking failures also discard pixels instead of returning an unmasked image.
- The native include filter pins window ID, owner PID and bundle to the admitted inventory, rechecks native titles and disables child-window inclusion. Transient or reused windows cannot expand permission. With no proven windows the candidate reports a gap; desktop and unproven surfaces are omitted by this conservative comparison path.
- Capture installs its own synchronous workspace/display/AX notification fence before starting pixels, independent of `activityContextEnabled`. A bounded signal consumer owns observer refresh; old callbacks and observer installations cannot outlive their generation. Focused candidate metadata requires a current successful app-focus and focused-window title/move/destruction subscription; unsupported or changing observer coverage keeps app/window identity unknown. Native observer removal retains its refcon through run-loop removal.
- Capture observation start/stop also reset observed window generations, so a WindowServer identifier reused during an unobserved recording pause cannot inherit the earlier lifetime. The regression uses a real offscreen native window without an activity writer.
- Native source start/stop/configuration updates invalidate generations and join in-flight work. A transition prevents new capture admission while the old native read is joining. `CaptureSourceRouter` switches inside the manager's existing serialized policy bracket and does not silently fall back after a candidate failure.
- A failed backend/display-only settings comparison restores the prior source into the same output stream under a fresh policy transition. Failed restoration stops capture and exposes `CaptureConfigurationUpdateFailure.recordingRestored`; privacy changes and cancellation remain fail-closed. Real SQLite/stream regressions include restoration, failed restoration, privacy changes and cancellation during restoration.
- The macOS 26 SDK obsoletes direct calls to the former CoreGraphics APIs. `CaptureLegacyBridge` resolves only those two existing public symbols, preserves owned `CGImage` results and returns unavailable when either API is absent. Capture startup still requires its normal permission check, and the bridge grants no additional access. Successful compilation is not runtime legacy acceptance or a reason to promote the candidate.
- Manager raw/output buffers each retain at most two frames. Per-display deduplication is bounded to eight entries and 128 MiB; eviction preserves correctness by allowing another frame. Configuration transitions discard stale queued/held frames. `invalidateDeduplication(displayID:)` lets storage rejection retry unchanged pixels, and output drops clear that display's cache.
- `CaptureCoverageEvent` reports categorical gap/recovery transitions through `CaptureManager.setCoverageHandler`. App owns durable `daily_metrics` and visible status. Busy capture, unstable context, removed displays, native errors and backpressure are distinct from successfully observed unchanged pixels. Handlers must enqueue inexpensive work; no content/title/URL enters these events.
- Joined source replacement ends old-source gaps with `.ended`, never a fabricated recovery. The manager retains its forwarding configuration gap until fresh pixels enter the existing stream. A backend's obsolete busy or removed-display state cannot suppress the replacement's actual recovery; App preserves gap/end metric receipts.
- `ScreenCaptureKitCandidateTests` controls only external native reads and uses the production sequencer, real CoreGraphics images/masks and AsyncStream queues for display separation, removal/replacement, start-stop/configuration fences, privacy rules, queue pressure and storage-retry regressions. It does not start real user capture or establish installed acceptance.
- `ScreenCaptureStreamPoolTests` builds real native BGRA CVPixelBuffers and CMSampleBuffers with ScreenCaptureKit status/display-time attachments while substituting only stream start/output/stop. It covers exact immutable idle reuse, stale/future events, missing/malformed proofs, geometry, timeout/cancellation, held native start, cleanup failure/retry, attachment changes and capacity/concurrent-read bounds without permission prompts or desktop reads.
- `CaptureCleanupOwnershipTests` exercises the actual candidate/router/manager and AsyncStream teardown with native lifecycle acknowledgements injected. A failed native stop remains reachable through public stop after forwarding ends; partial startup cleanup, backend replacement and configuration changes cannot bypass it. The router releases its selection only after successful cleanup, and the manager preserves cleanup state independently of its recording flag.

### 1. CGWindowListCapture Setup (Legacy Implementation)

The polling backend remains the comparison baseline while the ScreenCaptureKit candidate awaits runtime acceptance. On macOS 26 it uses the runtime-checked `CaptureLegacyBridge`; missing legacy symbols report capture unavailable. Both paths retain permission checks and exclusion enforcement on every capture. Compilation alone does not establish backend availability, quality or acceptance.

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
- `SemanticPixelDeduplicationTests` uses reviewed JPEGs and independently rendered one-digit invoices at 1×/2×, with exact RGB contrast, tile/vector boundaries, short/unaligned rows, malformed buffers and concurrent comparisons. Its opt-in `RETRACE_DEDUP_PERFORMANCE=1` benchmark requires an optimized build and measures CPU/wall time at 1280×800, 2560×1600 and 3840×2160, including isolated high-contrast stress. Three cache-disturbed samples are a limited cold receipt, separate from the 20 warmed samples; failures of the 5 ms CPU target remain visible. See the root validation ledger for measured outcomes.
- Local-scan counters occupy three bytes per horizontal tile (360 bytes at 4K), plus bounded vector temporaries and the input frames. No image-sized mask or copied pixel buffer is allocated by the detector.
- Deduplication percentages depend on the workload; they are not guaranteed storage savings.
- When capture-time direct text is enabled, the manager validates observations against their exact frame/receipt/context and retains a newly available or changed semantic run multiset even when pixels would deduplicate. Exact UTF-16 content, physical run geometry, local ranges, roles/ancestry and stable source identity participate; read clocks, UUIDs, run IDs and traversal ordinals do not. Unavailable/invalid/disabled text follows the existing pixel policy, including deliberately lower slider sensitivity. Comparisons use the existing bounded per-display last-kept cache; no extra history or AX calls are made. `capture.dedup_direct_text` measures validation/comparison wall latency; capture statistics include the retained frames. Native CoreText/AsyncStream regressions are source validation, not installed text accuracy, CPU/p95 or bytes/day acceptance.

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

- `AudioCaptureManager.setMeetingEvidenceComparisonEnabled` updates only the detector and returns after its prior read/state/metric delivery joins; persist the acknowledged `getConfig()` value. It preserves both native PCM sources and the combined stream. `setMeetingOutcomeHandler` is async and awaited by the same owned chain; handlers must not synchronously await their own manager/detector stop. All recording/consent fields survive the comparison-only configuration copy.

### Capture-time AX native regression boundary

- `CaptureVisibleTextTests` owns its AppKit provider and reads only authored text. Window readiness requires the acknowledged PID/window, opaque normal-layer onscreen geometry stable over bounded polls; READY follows the native launch callback. Missing readiness remains a failure, never a permission/session skip.
- `CaptureVisibleTextReader` stops line enumeration at the already-proved visible endpoint, including clipped terminal lines; it does not reinterpret a native in-range error as end-of-text. Native fixtures cover terminal lines with/without a newline and deliberate native line-query failure.
- Optional reader diagnostics expose only fixed phase/operation/proof-mismatch categories, AX status and bounded counts. Test names label a single stderr receipt so stdout buffering cannot misattribute a failure. Global composition, unique window identity, exact UTF-16, observer coverage, clipping/occlusion and 150 ms/25 ms budgets remain unchanged. Source review or a diagnostic run alone does not establish installed capture accuracy/performance.

## Audio Conversion Lifecycle

- Microphone and system callbacks each own a separate `AudioFormatConverter` instance and call `convert(sampleBuffer:)` on their existing background sample queues.
- Copy PCM using `CMSampleBufferCopyPCMDataIntoAudioBufferList` with the actual `AVAudioFormat`; preserve planar/interleaved channel layout and real integer/float format.
- Retain `AVAudioConverter` state across callback buffers. Use `.noDataNow` between buffers, native high-quality resampling, and downmix to 16 kHz mono Int16. Do not recreate the converter or end its stream for each packet.
- Publish only actual output frames, calculating duration from emitted PCM bytes. Empty output while the resampler primes is normal.
- A failed conversion clears filter history and the pending timestamp; the next valid packet starts fresh. Failed microphone startup throws and closes its stream. Source teardown also closes preacquired streams when the device never started.
- Source shutdown drains the converter with `finish()` before finishing the source stream. The coordinator acquires source streams before scheduling forwarders and awaits both forwarders before finishing the combined stream. Restart and system-audio muting discard pending samples with `reset()` to prevent crossing privacy boundaries.
- Converter and delegate locks protect background callback/shutdown transitions. Never call this synchronous conversion work from UI rendering or the main thread.
- `AudioCaptureSampleClock` validates native CMSampleBuffer presentation times and sample counts. A continuous interval advances from emitted 16 kHz frames rather than callback receipt jitter. The first receipt date is an approximate wall-clock anchor, not a verified host-clock synchronization. Forward native PTS gaps retain elapsed time; backwards/reset clocks reanchor. Format changes, invalid input, mute/privacy and restart create a new `CapturedAudio.continuityID`. Physical gap/format changes and rejected pre-conversion metadata drain accepted resampler frames on the old interval. Privacy and a conversion that may have consumed invalid PCM discard filter history.
- `AudioFormatConverterTests` and `AudioCaptureSampleClockTests` exercise real AVFoundation/CoreMedia buffers for anti-alias filtering, irregular callback delivery, native gaps, channel layouts, format changes, privacy resets and finite drain behavior. `Processing/Tests/AudioChunkNativeCaptureTests` connects both production native delegates to the candidate chunker using authored CMSampleBuffers; ordinary callback jitter retains ten-second chunking while adjacent dates across a native format change retain separate identities. No test starts a microphone/system capture device or establishes installed timing acceptance.
- `AudioCaptureManager.stopCapture` also finishes and retires a preacquired combined stream when native capture never started. This lets the App join a late consumer after failed startup without waiting on a device-less open stream. `AudioStreamBufferingPolicyTests` covers repeated idle stream generations with real AsyncStreams and no device access.

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
- Candidate all-display capture requires installed comparison and energy/latency acceptance before promotion

## Getting Started

1. Read `CGWindowListCapture.swift` - main capture implementation
2. Read `FrameDeduplicator.swift` for active pixel comparison; `PerceptualHash.swift` is a separate unused dHash helper
3. Read `AppInfoProvider.swift` - metadata extraction
4. Read `CaptureManager.swift` - protocol conformance + pipeline

The implementation is complete. Focus on understanding the existing code rather than rewriting.
