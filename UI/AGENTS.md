# UI Module - Agent Instructions

You are the **UI** agent responsible for building the SwiftUI interface for Retrace.

**Status**: ✅ Fully implemented with modern SwiftUI design. Timeline, dashboard, search, settings, onboarding, feedback, audio transcripts, and push-to-dictate views all working. Global hotkeys use the user's saved Settings → General configuration; use the menu labels when documenting a smoke sequence instead of assuming default keys. Menu bar integration complete. **Apple Silicon required**.

## Your Directory

```
UI/
├── Assets.xcassets/
│   ├── AppIcon.appiconset/             # App icon assets
│   └── CreatorProfile.imageset/        # Creator profile image shown in onboarding/milestones
├── Views/
│   ├── Timeline/
│   │   ├── ActivityTimelineController.swift # Activity/evidence window lifecycle and source-qualified search routing
│   │   ├── ActivityTimelineView.swift       # Episodes, intervals, corrections, metadata search, context control and health
│   │   ├── ExactEvidenceView.swift          # Exact retained revision, verified image/regions and unavailable-media text
│   ├── FullscreenTimeline/
│   │   ├── SpotlightSearchOverlay.swift # Primary search overlay UI
│   │   └── SearchFilterBar.swift        # Search filters and controls
│   ├── Dashboard/
│   │   ├── DashboardView.swift          # Voice-first dashboard, visual memory, and live intelligence UI
│   │   ├── DashboardVoiceLayout.swift   # Dashboard layout, transcript, and screenshot policies
│   │   ├── ChangelogView.swift          # Appcast-powered release notes view
│   │   ├── AnalyticsCard.swift          # Stats widgets
│   │   ├── MigrationPanel.swift         # Import UI
│   │   └── SupportLink.swift            # Twitter/support
│   ├── Audio/
│   │   ├── TranscriptContentView.swift  # Continuous transcript display
│   │   └── TranscriptWindowController.swift # Transcript window lifecycle
│   └── Settings/
│       ├── SettingsView.swift           # Settings root
│       ├── CaptureSettings.swift        # Capture config
│       ├── StorageSettings.swift        # Storage/retention
│       ├── PrivacySettings.swift        # Exclusions/permissions
│       └── AdvancedSettings.swift       # Power user options
├── Components/
│   ├── AppResourceBundle.swift          # Packaged app resource bundle and SwiftPM/Xcode fallbacks
│   ├── ApplicationTerminationWorkflow.swift # Coalesced startup cancellation and async metrics/service shutdown before Quit
│   ├── TimelineSessionMetrics.swift     # Shared duration/scrub write ownership and acknowledgement across hide/Quit/retry
│   ├── BoundingBoxOverlay.swift         # Text region highlighting
│   ├── SearchEvidenceThumbnailLoader.swift # Bounded exact-source search previews and cancellable row presentation
│   ├── SessionTimeline.swift            # App session visualization
│   ├── DeeplinkHandler.swift            # URL scheme routing
│   ├── ProcessCPUMonitor.swift          # Shared process CPU+memory sampler + 24h aggregation service
│   ├── ProcessCPUSummaryCard.swift      # System Monitor CPU table/card UI
│   └── ProcessMemorySummaryCard.swift   # System Monitor memory table/card UI
├── ViewModels/
│   ├── ActivityTimelineViewModel.swift     # Cancellable metadata paging, corrections, links and exact evidence resolution
│   ├── TimelineViewModel.swift
│   ├── SearchViewModel.swift
│   ├── DashboardViewModel.swift
│   ├── FuseIntelViewModel.swift          # Read-only local FuseIntel BFF client and presentation policy
│   └── SettingsViewModel.swift
└── Tests/
    ├── ApplicationTerminationWorkflowTests.swift # Async Quit/startup ordering, retry and real SQLite commit-before-close regressions
    ├── TimelineSessionMetricsTests.swift # Real SQLite retry, partial failure, hide/reopen, reconfiguration and timeout acknowledgements
    ├── ActivityTimelineViewModelTests.swift # Real SQLite paging/correction/control and delayed evidence regressions
    ├── SearchEvidenceThumbnailTests.swift # Real SQLite source/privacy/deletion checks before thumbnail exposure
    ├── AppResourceBundleTests.swift      # Real app/resource bundle layout and lazy fallback checks
    ├── TestLogger.swift                  # UI behavior + deeplink parsing tests
    ├── HotkeyHoldReleasePolicyTests.swift # Hold-hotkey modifier release regression tests
    ├── DashboardVoiceLayoutTests.swift   # Voice-first dashboard layout policy tests
    ├── DashboardSelectedFrameRefreshTests.swift # Real SQLite selected-frame OCR refresh and cancellation regressions
    ├── FuseIntelViewModelTests.swift      # FuseIntel wire-contract and context-ranking tests
    ├── ProcessCPUMonitorPolicyTests.swift # System monitor launch-sampling policy tests
    ├── TimelineBackgroundRefreshPolicyTests.swift # Hidden timeline background-work opt-in policy tests
    └── TranscriptCursorPolicyTests.swift # Audio transcript cursor stack regression tests
```

## Feature Requirements

### Application termination

`ApplicationTerminationWorkflow` owns one launch task and one confirmed-Quit drain. Repeated Quit stays `terminateLater` while coordinator shutdown preparation, metrics, cancelled initialization and coordinator shutdown are awaited in that order. Preparation permanently fences recording entry points and cancels owned startup before the join. Startup cancellation checkpoints must prevent a late autostart or window reveal; normal startup runs once. The coordinator's shutdown route preserves recording intent for the next launch. A service shutdown failure replies false, reports that services may be partially stopped and permits a fresh Quit attempt without restarting initialization. Ask, Run in Background and Cancel retain their existing behavior.

`TimelineSessionMetrics` owns duration/scrub increments across hide, reopen and Quit. It bounds pending state to two numeric totals and serializes writes; each acknowledgement consumes only the written increment. A retry therefore retains unacknowledged values without replaying committed ones or clearing a newer session. The timeout remains cooperative: even on expiry the owned writer is cancelled and joined before database closure. A failed flush is logged, and no durable metric success is inferred from it.

Shortcut reloads call `TimelineWindowController.configure(coordinator:)` again with the same app coordinator. They must retain the existing metric owner and pending drain. A different coordinator requires a separate controller lifetime; replacement is rejected before changing controller state so pending metrics cannot move to another database.

### Progressive recall

The **Activity & Evidence** menu/dashboard entry opens three levels: episodes, observed intervals and exact recorded evidence. Metadata search works before OCR and advances the returned cursor even when current privacy filters leave a page empty. Brief visits stay visible by default; optional hiding reports its count and can be reversed. Grouping is a rebuildable local projection and must preserve every interval and unknown gap.

`ActivityTimelineViewModel` performs I/O through async closures backed by `ProgressiveRecallService`; generation checks prevent an old or cancelled selection from overwriting a newer one. Activity-linked screens must validate the association both before and after resolving the exact source/store/observation/revision. A deleted association does not imply the screen was deleted. Image failure may show separately permitted retained text, with an explicit unavailable-image state. Only verified immutable block geometry may overlay an image. Opening the current URL remains a separate action.

Corrections require a concrete selected scope and explicit confirmation; drafts, pending application, applied, conflicts and append-only undo remain distinct. Hiding presentation, excluding future capture and deleting activity are separate controls. The activity context opt-in applies only while master recording permits capture. Stage health distinguishes activity observed/persisted, image admitted/retained, text queue/processing/failures and audio processing without inferring stopped stages from missing timestamps.

Search rows and thumbnail keys must include `SearchResult.sourceQualifiedID`; numeric frame IDs can collide between libraries. Search evidence clicks route through `ActivityTimelineController`, never the old nearest-timestamp fallback. `retrace://evidence` retains the exact reference. A concurrent search revision change presents an explicit refresh action rather than silently ending pagination. New actions emit safe `progressive_recall_action` metrics; critical activity/evidence opens record latency.

`SpotlightSearchOverlay` previews resolve the original `SearchResult` proof through the exact evidence service on every row appearance. They do not expose the old memory/disk thumbnail cache or look up media and OCR nodes by bare IDs. A shared actor limits decoding to two concurrent requests and 32 queued requests; Core Graphics resizing runs off main. Per-row pixels are cleared on disappearance, and cancellation plus request identity prevent late publication. Previews show the full verified image without cropping to mutable OCR nodes; exact evidence owns immutable block highlighting. This trades repeated decode work for current source, privacy and deletion checks; `search.thumbnail.exact` records latency.

### 1. Timeline View (Primary Interface)

**Activation**: **Open Timeline** in the menu bar, or the user's configured global shortcut in Settings → General.

**Layout**:
```
┌─────────────────────────────────────────────────────┐
│  [Search Bar]                      [Settings] [•••] │
├─────────────────────────────────────────────────────┤
│                                                     │
│              [Large Frame Preview]                  │
│                  (current frame)                    │
│                                                     │
├─────────────────────────────────────────────────────┤
│  ◄──────────────────────────────────────────────►  │
│  [════════════════════════════════════════════]     │
│  ^                     ^                      ^     │
│  9:00 AM            12:00 PM               3:00 PM  │
│                                                     │
│  [Chrome] [VS Code] [Slack] [Chrome] [Terminal]    │
│   ━━━━━━  ━━━━━━━━  ━━━━━  ━━━━━━━━  ━━━━━━━━━     │
└─────────────────────────────────────────────────────┘
```

**Features**:
- **Horizontal scrolling**: Click and drag, or use arrow keys
- **Zoom levels**: Hour / Day / Week views
- **Frame thumbnails**: Show every Nth frame based on zoom level
- **Session markers**: Color-coded bars showing app usage periods
- **Hover preview**: Show frame thumbnail on hover
- **Click to jump**: Click any point to jump to that timestamp
- **Smooth scrolling**: 60fps animations
- **Keyboard navigation**:
  - `←/→`: Previous/next frame
  - `Shift+←/→`: Jump 1 minute
  - `Cmd+←/→`: Jump 1 hour
  - `Space`: Play/pause auto-scroll
  - `Cmd+K`: Open global recorded-text search
  - `Cmd+F`: Toggle search within the current frame
  - `/`: Focus search bar

**Session Indicators**:
- Each app session is a horizontal bar with:
  - App icon
  - App name
  - Duration
  - Color based on app bundle ID (consistent hashing)
- Click session to filter timeline to that app
- Hover to see metadata (window title, URL if browser)

**Performance**:
- Virtualized scrolling (only render visible thumbnails)
- Lazy load frames as needed
- Cache thumbnails in memory (LRU eviction)
- Background thumbnail generation

### 2. Search View

**Activation**:
- Keyboard shortcut in the timeline: `Cmd+K` (global recorded-text search)
- Click search bar in timeline

`Cmd+F` toggles **Search this frame**; it does not open global search.

**Layout**:
```
┌─────────────────────────────────────────────────────┐
│  Search: [error message in chrome         ] [⌘K]   │
│  Filters: [App ▼] [Date ▼] [OCR/Audio ▼]           │
├─────────────────────────────────────────────────────┤
│  Results (142 matches)                              │
│  ┌──────────────────────────────────────────────┐  │
│  │ [Thumbnail] Chrome • 2:34 PM                 │  │
│  │             Error message in console.log     │  │
│  │             ...cannot read property of null  │  │
│  └──────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────┐  │
│  │ [Thumbnail] VS Code • 2:31 PM                │  │
│  │             // TODO: fix error handling      │  │
│  │             throw new Error('message')       │  │
│  └──────────────────────────────────────────────┘  │
│  ...                                                │
└─────────────────────────────────────────────────────┘
```

**Features**:
- **Real-time search**: Results update as you type (debounced 300ms)
- **Filters**:
  - App filter (multiselect dropdown)
  - Date range picker
  - Content type (OCR text / Audio transcription)
- **Result row shows**:
  - Frame thumbnail
  - Timestamp (formatted: "Today 2:34 PM", "Yesterday", "Jan 15")
  - App icon + name
  - Text snippet with **highlighted match**
  - Relevance score (FTS ranking)
- **Click result**: Opens frame viewer with highlights
- **Keyboard navigation**:
  - `↑/↓`: Navigate results
  - `Enter`: Open selected result
  - `Esc`: Close search
  - `Cmd+↑/↓`: Jump to first/last result

**Deeplinks**:

Format (canonical): `retrace://search?q={query}&t={unix_ms}&app={bundle_id}`
Legacy compatibility: `timestamp={unix_ms}` is also accepted.

Examples:
```
retrace://search?q=error&t=1704067200000
retrace://search?q=password&app=com.google.Chrome
retrace://search?timestamp=1704067200000
```

Implementation:
```swift
// In DeeplinkHandler.swift
func handleURL(_ url: URL) {
    guard url.scheme == "retrace" else { return }

    let params = url.queryParameters
    let timestampMs = params["t"] ?? params["timestamp"]   // support both keys
    let timestamp = timestampMs.flatMap(Int64.init).map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }

    switch url.host {
    case "search":
        let query = params["q"]
        let app = params["app"]

        openSearch(query: query, timestamp: timestamp, app: app)
    case "timeline":
        openTimeline(at: timestamp)
    default:
        break
    }
}
```

**Share functionality**:
- Right-click result → Copy Link
- Generates deeplink to share with others (or paste into notes)

### 3. Frame Viewer with Bounding Box Highlighting

**When**: Opened by clicking a search result

**Layout**:
```
┌─────────────────────────────────────────────────────┐
│  ← Back to Results        Chrome • 2:34 PM    [×]   │
├─────────────────────────────────────────────────────┤
│                                                     │
│          ┌─────────────────────────┐               │
│          │  [Screenshot]           │               │
│          │                         │               │
│          │  ┏━━━━━━━━━━━┓         │  <-- Highlighted │
│          │  ┃error message┃         │      bounding   │
│          │  ┗━━━━━━━━━━━┛         │      boxes      │
│          │                         │               │
│          └─────────────────────────┘               │
│                                                     │
│  OCR Text Detected:                                │
│  • "error message" (confidence: 0.98) [MATCH]      │
│  • "console.log"   (confidence: 0.95)              │
│  • "cannot read"   (confidence: 0.92) [MATCH]      │
│                                                     │
│  [< Previous Match]        [Next Match >]          │
└─────────────────────────────────────────────────────┘
```

**Features**:
- **Bounding boxes**: Red rectangles around search matches
- **Hover box**: Show confidence score and full text
- **Multiple matches**: Navigate between matches on same frame
- **Zoom/pan**: Pinch to zoom, drag to pan
- **Copy text**: Right-click box → Copy text
- **OCR list**: Show all detected text regions below frame
- **Keyboard shortcuts**:
  - `Tab`: Next match on frame
  - `Shift+Tab`: Previous match
  - `Cmd++/-`: Zoom in/out
  - `Esc`: Close viewer

**Implementation**:
```swift
struct BoundingBoxOverlay: View {
    let regions: [TextRegion]
    let searchQuery: String
    @State private var hoveredRegion: TextRegion?

    var body: some View {
        GeometryReader { geometry in
            ForEach(regions) { region in
                Rectangle()
                    .stroke(region.matchesQuery ? Color.red : Color.blue, lineWidth: 2)
                    .frame(width: region.width, height: region.height)
                    .position(x: region.x, y: region.y)
                    .onHover { isHovered in
                        hoveredRegion = isHovered ? region : nil
                    }
                    .popover(isPresented: .constant(hoveredRegion == region)) {
                        VStack {
                            Text(region.text)
                            Text("Confidence: \(region.confidence ?? 0, format: .percent)")
                        }
                    }
            }
        }
    }
}
```

### 4. Dashboard View

**Activation**: Default landing screen

**Layout**:
```
┌─────────────────────────────────────────────────────┐
│  Retrace Dashboard                    [Settings ⚙]  │
├─────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌───────────┐ │
│  │ 2.3M Frames  │  │ 147 GB Total │  │ 127 Days  │ │
│  │ Captured     │  │ Storage Used │  │ Recording │ │
│  └──────────────┘  └──────────────┘  └───────────┘ │
│                                                     │
│  Recent Activity                                    │
│  ┌─────────────────────────────────────────────┐  │
│  │ [Chart: Frames captured per hour]           │  │
│  │                                              │  │
│  └─────────────────────────────────────────────┘  │
│                                                     │
│  Top Apps                                          │
│  1. Chrome         14.2 hours (23%)               │
│  2. VS Code        11.7 hours (19%)               │
│  3. Slack           8.3 hours (14%)               │
│                                                     │
│  ┌─────────────────────────────────────────────┐  │
│  │ Import from Rewind AI                        │  │
│  │ [Scan for Data] or [Select Folder...]       │  │
│  │                                              │  │
│  │ Status: Ready to import                      │  │
│  └─────────────────────────────────────────────┘  │
│                                                     │
│  Made with ♥ by @haseab • x.com/haseab_            │
└─────────────────────────────────────────────────────┘
```

**Analytics Cards**:

1. **Capture Stats**:
   - Total frames captured
   - Frames today / this week
   - Average FPS achieved
   - Deduplication rate

2. **Storage Stats**:
   - Total storage used (GB)
   - Video files vs metadata
   - Frames per GB ratio
   - Estimated time until disk full

3. **Time Tracked**:
   - Days of recording
   - Active vs idle time
   - Longest continuous session
   - Recording uptime %

4. **Search Stats**:
   - Total searchable documents
   - Text regions indexed
   - Average search latency
   - Most searched terms

5. **Activity Chart** (SwiftUI Charts):
   - Line chart: Frames captured per hour (last 7 days)
   - Bar chart: App usage by day
   - Heatmap: Activity by hour of day

6. **Top Apps** (Ranked list):
   - App icon
   - Name
   - Total time in focus
   - Percentage of total
   - Click to filter timeline

7. **Voice Dictation**:
   - Shows configured hold shortcut
   - Lists recent dictation sessions and inserted transcripts
   - Shows target app context and insertion status/errors

**Migration UI**:

```
┌─────────────────────────────────────────────────────┐
│  Import from Third-Party Apps                       │
│                                                     │
│  Available Sources:                                 │
│  ☑ Rewind AI   (43 GB found)   [Import]           │
│  ☐ ScreenMemory (Not installed)                    │
│  ☐ TimeScroll   (Not installed)                    │
│                                                     │
│  Importing from Rewind...                           │
│  ┌─────────────────────────────────────────────┐  │
│  │ ████████████░░░░░░░░░░░░░░░░░░░ 45%         │  │
│  └─────────────────────────────────────────────┘  │
│  2,847 videos processed • 1.2M frames imported     │
│  Estimated time remaining: 3 hours 12 minutes      │
│                                                     │
│  [Pause Import]  [Cancel]                          │
└─────────────────────────────────────────────────────┘
```

**Migration Features**:
- Auto-detect installed apps
- Show data size before import
- Real-time progress bar
- Pausable/resumable
- Shows frames imported, deduplicated
- Error handling (show failed videos)
- "Import Complete" notification

**Support Link**:
- Small footer: "Made with ♥ by @haseab"
- Links to: `https://x.com/haseab_`
- Opens in default browser

### 5. Settings View

**Activation**: `Cmd+,` or click gear icon

**Layout**: Sidebar with categories

```
┌──────────────┬──────────────────────────────────────┐
│ General      │ General Settings                      │
│ Capture      │                                       │
│ Storage      │ Launch at Login:  [✓]                │
│ Privacy      │ Show Menu Bar Icon: [✓]               │
│ Search       │ Theme: [Auto ▼] Light / Dark / Auto  │
│ Advanced     │                                       │
│              │ Keyboard Shortcuts:                   │
│              │ Timeline:  [⌘⇧T]  [Edit]             │
│              │ Search:    [⌘K]   [Edit]             │
│              │                                       │
└──────────────┴──────────────────────────────────────┘
```

#### 5.1 General Settings

- **Launch at login**: Checkbox
- **Show menu bar icon**: Checkbox (status item in macOS menu bar)
- **Theme**: Auto / Light / Dark
- **Keyboard shortcuts**: Customize all shortcuts
- **Voice dictation shortcut**: Hold shortcut used to capture and insert only the speech during key-down/key-up
- **Notification preferences**: When to show notifications

#### 5.2 Capture Settings

- **Capture rate**: 0.5 FPS (default) / 1 FPS / 2 FPS
- **Resolution**: Original / 1080p / 720p / Custom
- **Active display only**: Checkbox (vs all displays)
- **Exclude cursor**: Checkbox
- **Pause when**:
  - Screen locked
  - On battery (< X%)
  - Idle for X minutes

#### 5.3 Storage Settings

- **Storage location**: Folder picker
- **Retention policy**:
  - Keep forever (default)
  - Keep last N days
  - Keep until disk < X GB free
- **Max storage**: Slider (10 GB - 1 TB)
- **Compression quality**: Low / Medium / High / Lossless
- **Auto-cleanup**:
  - Delete frames with no text
  - Delete duplicate frames
  - Delete frames older than X

#### 5.4 Privacy Settings

- **Excluded apps**: Multiselect list
  - Pre-populate: 1Password, Bitwarden, banking apps
  - Add/remove apps
  - Import from file
- **Excluded windows**:
  - Private browsing (default: ON)
  - Incognito mode (default: ON)
  - Custom window titles (regex)
- **Pause recording**: Global hotkey to temporarily stop
- **Delete recent**:
  - Delete last 5 min / 1 hour / 1 day
  - Secure deletion (overwrite)
- **Permissions status**:
  - Screen Recording: [Granted ✓]
  - Accessibility: [Granted ✓]
  - Buttons to open System Settings if denied

#### 5.5 Search Settings

- **Search suggestions**: Show as you type
- **Result limit**: Default 100, max 1000
- **Snippet length**: How many characters around match
- **Include audio**: Search audio transcriptions (when implemented)
- **Ranking**: Relevance vs Recency slider

#### 5.6 Advanced Settings

- **Database optimization**:
  - Vacuum database
  - Rebuild FTS index
  - Repair corrupted segments
- **Encoding**:
  - Hardware acceleration (VideoToolbox)
  - Encoder preset: Fast / Balanced / Quality
  - Async encoding queue size
- **Logging**:
  - Log level: Error / Warning / Info / Debug
  - Log file location
  - [Open Logs Folder]
- **Developer**:
  - Show frame IDs in UI
  - Export database schema
  - Export sample data (anonymized)
- **Danger zone**:
  - Reset all settings
  - Delete all data
  - Uninstall Retrace

### 6. Keyboard Shortcuts Reference

| Shortcut | Action |
|----------|--------|
| `Cmd+Shift+T` | Open Timeline |
| `Cmd+Shift+D` | Open Dashboard |
| `Cmd+Shift+R` | Toggle Recording |
| `Cmd+Shift+M` | Open System Monitor |
| `Ctrl+Space` | Hold Voice Dictation |
| `Cmd+K` | Open global recorded-text search in the timeline |
| `Cmd+F` | Toggle Search this frame |
| `Cmd+,` | Open Settings |
| `/` | Focus search bar |
| `←/→` | Previous/Next frame |
| `Shift+←/→` | Jump 1 minute |
| `Cmd+←/→` | Jump 1 hour |
| `Space` | Play/Pause timeline |
| `Tab` | Next search match |
| `Shift+Tab` | Previous search match |
| `Cmd++/-` | Zoom in/out |
| `Esc` | Close current view |
| `Cmd+Q` | Quit Retrace |

## Design System

### Colors

```swift
extension Color {
    static let retraceAccent = Color.blue
    static let retraceDanger = Color.red
    static let retraceSuccess = Color.green
    static let retraceWarning = Color.orange

    // Session colors (hashed from bundle ID)
    static func sessionColor(for bundleID: String) -> Color {
        let hash = bundleID.hashValue
        let hue = Double(abs(hash) % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }
}
```

### Typography

```swift
extension Font {
    static let retraceTitle = Font.system(size: 28, weight: .bold)
    static let retraceHeadline = Font.system(size: 17, weight: .semibold)
    static let retraceBody = Font.system(size: 15, weight: .regular)
    static let retraceCaption = Font.system(size: 13, weight: .regular)
    static let retraceMono = Font.system(size: 13, weight: .regular, design: .monospaced)
}
```

### Spacing

```swift
extension CGFloat {
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 16
    static let spacingL: CGFloat = 24
    static let spacingXL: CGFloat = 32
}
```

## Performance Requirements

- **Timeline rendering**: 60 FPS scrolling
- **Search results**: <300ms to display (for 100K documents)
- **Frame viewer load**: <100ms
- **Thumbnail generation**: Background queue, low priority
- **Memory usage**: <500 MB for UI (excluding frame cache)
- **Launch time**: <2 seconds cold start

## Dependencies

You depend on:
- `DatabaseProtocol` - Query frames, documents, sessions
- `SearchProtocol` - Full-text search
- `StorageProtocol` - Load frame images
- `MigrationProtocol` - Import progress updates

## Testing Requirements

- SwiftUI Preview for all views
- UI tests for keyboard shortcuts
- UI tests for search flow
- UI tests for timeline navigation
- Accessibility tests (VoiceOver support)

## Resource Packaging

`AppResourceBundle.bundle` caches UI resource resolution. Packaged SwiftPM apps keep `Retrace_Retrace.bundle` under `Contents/Resources`; the generated `Bundle.module` accessor is only a lazy fallback for direct SwiftPM runs. Xcode builds continue to use `Bundle.main`. Do not place resource bundles beside `Contents` in the app root or modify SwiftPM's generated accessor.

## Selected Screenshot Refresh

The screenshot dashboard's latest-page poll does not cover every retained historical selection. `DashboardSelectedFrameRefresher` in `DashboardVoiceLayout.swift` independently reads the selected native frame by ID, coalesces concurrent lookups, and fetches completed OCR nodes only when its text cache is stale. Apply results only to the matching selected ID/source still retained in the list, preserving order and selection. Cancel/invalidate on tab change or window hide, and restart polling when the dashboard reopens. Older OCR requests must not overwrite a newer processing status, and read failures must not be cached as completed empty text. This refresh never promotes queue priority or writes recorded data. Its actual read is measured by `dashboard.selected_frame_refresh` latency.

## Accessibility

- All interactive elements have labels
- Support VoiceOver navigation
- Support Dynamic Type (text scaling)
- Keyboard-only navigation possible
- High contrast mode support

## Files You Own

- `UI/` - All files in this directory
- Do NOT modify files in other modules

## Getting Started

1. Create SwiftUI views starting with `TimelineView`
2. Implement `DeeplinkHandler` for URL routing
3. Build `SpotlightSearchOverlay` with FTS integration
4. Add `BoundingBoxOverlay` component
5. Create `SettingsView` with all preferences
6. Build `DashboardView` with analytics
7. Add keyboard shortcut handling
8. Write UI tests

Focus on getting the timeline + search working first before polishing dashboard/settings.
