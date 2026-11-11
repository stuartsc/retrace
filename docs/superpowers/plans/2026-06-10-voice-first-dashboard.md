# Voice-First Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the dashboard so Dictation is the default voice-first workspace with a separate live audio transcript rail, App Usage as the second tab, compact stats at the bottom, and old footer utilities moved into Settings.

**Architecture:** Keep the change mostly in the `Retrace` SwiftUI target. Extract small testable dashboard policy types from `DashboardView.swift`, use existing `AudioTranscriptionQueries` through `AppCoordinator.getAudioTranscriptionQueries()` for read-only live transcript data, and add only metric enum cases in `Database` for new dashboard/settings events.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, SQLCipher-backed existing query actors, existing `DailyMetricsQueries` instrumentation.

---

## File Structure

- Create `UI/Views/Dashboard/DashboardVoiceLayout.swift`
  - Owns dashboard tab ordering, default tab, responsive split-vs-stacked policy, and live transcript row formatting.
- Create `UI/Tests/DashboardVoiceLayoutTests.swift`
  - Tests default tab, tab ordering, responsive mode, and live transcript preview formatting.
- Modify `UI/Views/Dashboard/DashboardView.swift`
  - Uses extracted tab type.
  - Defaults to Dictation.
  - Removes old left stats rail and dashboard footer.
  - Adds Dictation split layout, live audio rail, and bottom stats strip.
  - Loads recent live transcript data only while Dictation view is visible.
- Modify `UI/Views/Settings/SettingsView.swift`
  - Adds General `About & Support` card.
  - Adds Advanced `Debug Tools` card under `#if DEBUG`.
  - Wires footer actions into Settings.
- Modify `UI/ViewModels/DashboardViewModel.swift`
  - Adds static metric helpers for dashboard open/load failures and settings utility actions.
- Modify `Database/Queries/DailyMetricsQueries.swift`
  - Adds metric type cases for dashboard default open, dashboard load failure, and settings utility action.
- Modify `Database/Tests/DatabaseManagerTests.swift`
  - Adds a real daily metrics write/read test for the new metric types.
- Modify `UI/AGENTS.md`
  - Documents the new dashboard layout helper and test file.

---

### Task 1: Extract Dashboard Voice Layout Policy

**Files:**
- Create: `UI/Views/Dashboard/DashboardVoiceLayout.swift`
- Create: `UI/Tests/DashboardVoiceLayoutTests.swift`
- Modify: `UI/Views/Dashboard/DashboardView.swift`
- Modify: `UI/AGENTS.md`

- [ ] **Step 1: Write failing tests for tab order, default tab, layout mode, and transcript preview**

Create `UI/Tests/DashboardVoiceLayoutTests.swift`:

```swift
import XCTest
@testable import Retrace

final class DashboardVoiceLayoutTests: XCTestCase {
    func testDictationIsDefaultDashboardTab() {
        XCTAssertEqual(DashboardContentTab.defaultTab, .dictation)
    }

    func testDashboardTabsAreVoiceFirst() {
        XCTAssertEqual(DashboardContentTab.allCases, [.dictation, .appUsage])
        XCTAssertEqual(DashboardContentTab.allCases.map(\.title), ["Dictation", "App Usage"])
    }

    func testVoiceDeskUsesSplitLayoutAtNormalWidths() {
        XCTAssertEqual(DashboardVoiceLayoutPolicy.contentMode(forWidth: 1_000), .split)
    }

    func testVoiceDeskStacksLiveAudioAtCompactWidths() {
        XCTAssertEqual(DashboardVoiceLayoutPolicy.contentMode(forWidth: 760), .stacked)
    }

    func testLiveAudioPreviewTrimsWhitespaceAndCollapsesLines() {
        XCTAssertEqual(
            DashboardLiveAudioRow.previewText(from: "  hello\\n\\nworld  "),
            "hello world"
        )
    }

    func testLiveAudioPreviewFallsBackForBlankText() {
        XCTAssertEqual(
            DashboardLiveAudioRow.previewText(from: "  \\n "),
            "No transcript text"
        )
    }
}
```

- [ ] **Step 2: Run test and verify it fails because the new types do not exist**

Run:

```bash
swift test --filter DashboardVoiceLayoutTests
```

Expected: FAIL with errors for missing `DashboardContentTab`, `DashboardVoiceLayoutPolicy`, or `DashboardLiveAudioRow`.

- [ ] **Step 3: Add the extracted layout policy file**

Create `UI/Views/Dashboard/DashboardVoiceLayout.swift`:

```swift
import Foundation
import CoreGraphics
import Shared

enum DashboardContentTab: String, CaseIterable, Identifiable {
    case dictation
    case appUsage = "app_usage"

    static let defaultTab: DashboardContentTab = .dictation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: return "Dictation"
        case .appUsage: return "App Usage"
        }
    }

    var icon: String {
        switch self {
        case .dictation: return "mic.fill"
        case .appUsage: return "chart.bar.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .dictation:
            return "Inserted dictation plus live audio transcript"
        case .appUsage:
            return "App usage and activity"
        }
    }
}

enum DashboardVoiceContentMode: Equatable {
    case split
    case stacked
}

enum DashboardVoiceLayoutPolicy {
    static let splitThreshold: CGFloat = 920

    static func contentMode(forWidth width: CGFloat) -> DashboardVoiceContentMode {
        width >= splitThreshold ? .split : .stacked
    }
}

struct DashboardLiveAudioRow: Identifiable, Equatable {
    let id: Int64
    let text: String
    let startedAt: Date
    let endedAt: Date
    let source: AudioSource
    let confidence: Double?

    static func previewText(from text: String) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "No transcript text" : collapsed
    }
}
```

- [ ] **Step 4: Remove the private `DashboardContentTab` enum from `DashboardView.swift` and set default tab**

In `UI/Views/Dashboard/DashboardView.swift`, change:

```swift
@State private var selectedDashboardTab: DashboardContentTab = .overview
```

to:

```swift
@State private var selectedDashboardTab: DashboardContentTab = .defaultTab
```

Delete the private nested `DashboardContentTab` enum from `DashboardView.swift`.

- [ ] **Step 5: Update App Usage switch cases**

In `dashboardContentSection`, change:

```swift
case .overview:
    appUsageDashboardCard(layoutSize: layoutSize)
case .dictation:
    dictationDashboardCard
```

to:

```swift
case .dictation:
    dictationDashboardCard(layoutSize: layoutSize)
case .appUsage:
    appUsageDashboardCard(layoutSize: layoutSize)
```

Change the dictation card declaration from:

```swift
private var dictationDashboardCard: some View
```

to:

```swift
private func dictationDashboardCard(layoutSize: LayoutSize) -> some View
```

- [ ] **Step 6: Update `UI/AGENTS.md` file listing**

Add `DashboardVoiceLayout.swift` and `DashboardVoiceLayoutTests.swift` to the dashboard/test file listings.

- [ ] **Step 7: Run the test**

Run:

```bash
swift test --filter DashboardVoiceLayoutTests
```

Expected: PASS.

---

### Task 2: Add Metrics for Dashboard/Settings Actions

**Files:**
- Modify: `Database/Queries/DailyMetricsQueries.swift`
- Modify: `Database/Tests/DatabaseManagerTests.swift`
- Modify: `UI/ViewModels/DashboardViewModel.swift`

- [ ] **Step 1: Write failing database metric test**

Append to `Database/Tests/DatabaseManagerTests.swift`:

```swift
func testVoiceDashboardMetricsRecordRealDailyMetricEvents() async throws {
    let timestamp = Date(timeIntervalSince1970: 1_700_100_000)
    let metricTypes: [DailyMetricsQueries.MetricType] = [
        .dashboardDefaultOpened,
        .dashboardLoadFailed,
        .settingsUtilityAction
    ]

    for metricType in metricTypes {
        try await database.recordMetricEvent(
            metricType: metricType,
            timestamp: timestamp,
            metadata: "test"
        )
    }

    for metricType in metricTypes {
        let total = try await database.getDailyMetricCount(
            metricType: metricType,
            from: timestamp,
            to: timestamp
        )
        XCTAssertEqual(total, 1, "Expected one event for \\(metricType.rawValue)")
    }
}
```

- [ ] **Step 2: Run test and verify it fails because metric cases do not exist**

Run:

```bash
swift test --filter DatabaseManagerTests/testVoiceDashboardMetricsRecordRealDailyMetricEvents
```

Expected: FAIL at compile time for missing metric cases.

- [ ] **Step 3: Add metric cases**

In `Database/Queries/DailyMetricsQueries.swift`, near `dashboardTabSelected`, add:

```swift
case dashboardDefaultOpened = "dashboard_default_opened"  // metadata: default tab identifier
case dashboardLoadFailed = "dashboard_load_failed"  // metadata: JSON {surface, error}
case settingsUtilityAction = "settings_utility_action"  // metadata: action identifier
```

- [ ] **Step 4: Add DashboardViewModel metric helpers**

In `UI/ViewModels/DashboardViewModel.swift`, near `recordDashboardTabSelected`, add:

```swift
public static func recordDashboardDefaultOpened(coordinator: AppCoordinator, tab: String) {
    recordMetric(coordinator: coordinator, type: .dashboardDefaultOpened, metadata: tab)
}

public static func recordDashboardLoadFailed(
    coordinator: AppCoordinator,
    surface: String,
    error: Error
) {
    let metadata = jsonMetadata([
        "surface": surface,
        "error": error.localizedDescription
    ])
    recordMetric(coordinator: coordinator, type: .dashboardLoadFailed, metadata: metadata)
}

public static func recordSettingsUtilityAction(coordinator: AppCoordinator, action: String) {
    recordMetric(coordinator: coordinator, type: .settingsUtilityAction, metadata: action)
}
```

- [ ] **Step 5: Run metrics test**

Run:

```bash
swift test --filter DatabaseManagerTests/testVoiceDashboardMetricsRecordRealDailyMetricEvents
```

Expected: PASS.

---

### Task 3: Reshape Dashboard Content Layout

**Files:**
- Modify: `UI/Views/Dashboard/DashboardView.swift`
- Test: `UI/Tests/DashboardVoiceLayoutTests.swift`

- [ ] **Step 1: Remove old two-column body layout and footer from dashboard body**

Replace the main content `HStack` that renders the left stats rail and right content with:

```swift
VStack(spacing: 14) {
    dashboardContentSection(layoutSize: layoutSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

    dashboardStatsStrip(layoutSize: layoutSize)
}
.frame(maxWidth: dashboardMaxWidth)
.frame(maxWidth: .infinity)
.frame(maxHeight: .infinity, alignment: .top)
```

Remove the `footer` call from the dashboard body.

- [ ] **Step 2: Add compact stat strip**

Add to `DashboardView.swift`:

```swift
private func dashboardStatsStrip(layoutSize: LayoutSize) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
            ForEach(statsCards) { card in
                compactStatTile(card)
                    .frame(width: 166)
            }
        }
        .padding(.horizontal, 2)
    }
    .frame(maxWidth: .infinity, minHeight: 74, maxHeight: 82)
}

private func compactStatTile(_ card: StatCardData) -> some View {
    HStack(spacing: 10) {
        ZStack {
            Circle()
                .fill(Color.retraceSecondary.opacity(0.10))
                .frame(width: 34, height: 34)

            Image(systemName: card.icon)
                .font(.retraceCaptionMedium)
                .foregroundColor(.retraceSecondary)
        }

        VStack(alignment: .leading, spacing: 2) {
            Text(card.title)
                .font(.retraceCaption2Medium)
                .foregroundColor(.retraceSecondary)
                .lineLimit(1)

            Text(card.value)
                .font(.retraceCalloutMedium)
                .foregroundColor(.retracePrimary)
                .lineLimit(1)

            Text(card.subtitle)
                .font(.retraceCaption2)
                .foregroundColor(.retraceSecondary.opacity(0.72))
                .lineLimit(1)
        }

        Spacer(minLength: 0)
    }
    .padding(12)
    .background(Color.white.opacity(0.03))
    .cornerRadius(14)
    .overlay(
        RoundedRectangle(cornerRadius: 14)
            .stroke(themeBorderColor.opacity(0.8), lineWidth: 1)
    )
}
```

- [ ] **Step 3: Record default dashboard open once after initial load**

In the initial `.task` block, after `await viewModel.loadStatistics()`, add:

```swift
DashboardViewModel.recordDashboardDefaultOpened(
    coordinator: coordinatorWrapper.coordinator,
    tab: selectedDashboardTab.rawValue
)
```

- [ ] **Step 4: Run dashboard layout policy tests**

Run:

```bash
swift test --filter DashboardVoiceLayoutTests
```

Expected: PASS.

---

### Task 4: Add Live Audio Rail

**Files:**
- Modify: `UI/Views/Dashboard/DashboardView.swift`

- [ ] **Step 1: Add state**

Add near existing dictation state:

```swift
@State private var liveAudioRows: [DashboardLiveAudioRow] = []
@State private var liveAudioError: String?
@State private var isLoadingLiveAudio = false
```

- [ ] **Step 2: Replace dictation card body with split/stacked content**

Inside `dictationDashboardCard(layoutSize:)`, keep the current header, then render:

```swift
GeometryReader { geometry in
    let mode = DashboardVoiceLayoutPolicy.contentMode(forWidth: geometry.size.width)

    Group {
        switch mode {
        case .split:
            HStack(alignment: .top, spacing: 14) {
                recentInsertionsPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                liveAudioPanel
                    .frame(width: min(max(geometry.size.width * 0.32, 260), 340), maxHeight: .infinity)
            }
        case .stacked:
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    recentInsertionsPanel
                    liveAudioPanel
                }
            }
        }
    }
}
```

- [ ] **Step 3: Extract `recentInsertionsPanel`**

Move the existing error/empty/scroll session list into:

```swift
private var recentInsertionsPanel: some View {
    VStack(alignment: .leading, spacing: 10) {
        Text("Recent Insertions")
            .font(.retraceCalloutMedium)
            .foregroundColor(.retracePrimary)

        Text("Only speech captured during the dictation hold appears here.")
            .font(.retraceCaption2)
            .foregroundColor(.retraceSecondary)

        if let dictationDashboardError {
            Text(dictationDashboardError)
                .font(.retraceCaptionMedium)
                .foregroundColor(.retraceWarning)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if recentDictationSessions.isEmpty {
            Text("No dictation sessions yet. Hold \(dictationConfig.shortcut.displayString), speak, then release to paste.")
                .font(.retraceCaptionMedium)
                .foregroundColor(.retraceSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(recentDictationSessions) { session in
                        dictationSessionRow(session)
                        if session.id != recentDictationSessions.last?.id {
                            Divider().background(Color.white.opacity(0.06))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
    .padding(14)
    .background(Color.white.opacity(0.025))
    .cornerRadius(14)
}
```

- [ ] **Step 4: Add `liveAudioPanel`**

Add:

```swift
private var liveAudioPanel: some View {
    VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.isRecording ? Color.retraceDanger : Color.retraceSecondary)
                .frame(width: 7, height: 7)
            Text("Live Audio")
                .font(.retraceCalloutMedium)
                .foregroundColor(.retracePrimary)
            Spacer()
            if isLoadingLiveAudio {
                ProgressView()
                    .scaleEffect(0.55)
            }
        }

        Text("Everything Retrace has recently heard, whether or not it was inserted.")
            .font(.retraceCaption2)
            .foregroundColor(.retraceSecondary)

        if let liveAudioError {
            Text(liveAudioError)
                .font(.retraceCaption2Medium)
                .foregroundColor(.retraceWarning)
        } else if liveAudioRows.isEmpty {
            Text("No continuous transcript yet.")
                .font(.retraceCaptionMedium)
                .foregroundColor(.retraceSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(liveAudioRows) { row in
                        liveAudioRow(row)
                    }
                }
            }
        }
    }
    .padding(14)
    .background(Color.white.opacity(0.025))
    .cornerRadius(14)
}
```

- [ ] **Step 5: Add live row rendering**

Add:

```swift
private func liveAudioRow(_ row: DashboardLiveAudioRow) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
            Text(row.startedAt, style: .time)
                .font(.retraceCaption2Medium)
                .foregroundColor(.retraceSecondary)

            Text(row.source.rawValue.capitalized)
                .font(.retraceCaption2Medium)
                .foregroundColor(.retraceAccent)

            Spacer(minLength: 0)
        }

        Text(row.text)
            .font(.retraceCaptionMedium)
            .foregroundColor(.retracePrimary)
            .lineLimit(4)
    }
    .padding(10)
    .background(Color.white.opacity(0.035))
    .cornerRadius(10)
}
```

- [ ] **Step 6: Add async loader and low-frequency visible refresh**

Add:

```swift
private func loadLiveAudioDashboardData() async {
    isLoadingLiveAudio = liveAudioRows.isEmpty
    defer { isLoadingLiveAudio = false }

    do {
        guard let queries = await coordinatorWrapper.coordinator.getAudioTranscriptionQueries() else {
            liveAudioRows = []
            liveAudioError = "Transcript store is not available"
            return
        }

        let endDate = Date()
        let startDate = endDate.addingTimeInterval(-6 * 60 * 60)
        let transcriptions = try await queries.getTranscriptions(
            from: startDate,
            to: endDate,
            source: nil,
            limit: 20
        )

        liveAudioRows = transcriptions.map {
            DashboardLiveAudioRow(
                id: $0.id,
                text: DashboardLiveAudioRow.previewText(from: $0.text),
                startedAt: $0.startTime,
                endedAt: $0.endTime,
                source: $0.source,
                confidence: $0.confidence
            )
        }
        liveAudioError = nil
    } catch {
        liveAudioError = "Unable to load live transcript"
        DashboardViewModel.recordDashboardLoadFailed(
            coordinator: coordinatorWrapper.coordinator,
            surface: "live_audio",
            error: error
        )
        Log.error("[Dashboard] Failed to load live audio transcript", category: .ui, error: error)
    }
}
```

Add a task modifier on the dashboard root:

```swift
.task(id: selectedDashboardTab) {
    guard selectedDashboardTab == .dictation else { return }
    await loadDictationDashboardData()
    await loadLiveAudioDashboardData()
    while !Task.isCancelled && selectedDashboardTab == .dictation {
        try? await Task.sleep(for: .seconds(8))
        guard !Task.isCancelled else { return }
        await loadLiveAudioDashboardData()
    }
}
```

- [ ] **Step 7: Record dictation session load failure**

In `loadDictationDashboardData()` catch block, add:

```swift
DashboardViewModel.recordDashboardLoadFailed(
    coordinator: coordinatorWrapper.coordinator,
    surface: "dictation_sessions",
    error: error
)
```

- [ ] **Step 8: Run focused tests**

Run:

```bash
swift test --filter DashboardVoiceLayoutTests
```

Expected: PASS.

---

### Task 5: Move Footer Utilities Into Settings

**Files:**
- Modify: `UI/Views/Settings/SettingsView.swift`
- Modify: `UI/Views/Dashboard/DashboardView.swift`

- [ ] **Step 1: Add settings search entries**

In `SettingsView.searchIndex`, add:

```swift
SettingsSearchEntry(id: "general.aboutSupport", tab: .general, cardTitle: "About & Support", cardIcon: "heart",
    searchableText: ["about", "support", "help", "creator", "haseab", "feedback"]),
SettingsSearchEntry(id: "advanced.debugTools", tab: .advanced, cardTitle: "Debug Tools", cardIcon: "ant",
    searchableText: ["debug", "diagnostics", "theme override", "launch on login banner"]),
```

- [ ] **Step 2: Add About & Support card**

In `generalSettings`, append `aboutSupportCard`.

Add:

```swift
@ViewBuilder
private var aboutSupportCard: some View {
    ModernSettingsCard(title: "About & Support", icon: "heart") {
        VStack(alignment: .leading, spacing: 14) {
            Text("Retrace is the voice-first memory layer for your Mac.")
                .font(.retraceCalloutMedium)
                .foregroundColor(.retracePrimary)

            HStack(spacing: 12) {
                ModernButton(title: "@haseab", icon: "person.crop.circle", style: .secondary) {
                    recordSettingsUtilityAction("creator_link")
                    openExternalURL("https://dub.sh/haseab-twitter")
                }

                ModernButton(title: "Support Me", icon: "cup.and.saucer.fill", style: .secondary) {
                    recordSettingsUtilityAction("support_link")
                    openExternalURL("https://dub.sh/support-haseab")
                }

                ModernButton(title: "Help", icon: "questionmark.circle", style: .secondary) {
                    recordSettingsUtilityAction("help")
                    NotificationCenter.default.post(name: .openFeedback, object: nil)
                }
            }
        }
    }
}
```

- [ ] **Step 3: Add Debug Tools card**

In `advancedSettings`, add `debugToolsCard` before `dangerZoneCard`.

Add:

```swift
@ViewBuilder
private var debugToolsCard: some View {
    #if DEBUG
    ModernSettingsCard(title: "Debug Tools", icon: "ant") {
        VStack(alignment: .leading, spacing: 12) {
            ModernButton(title: "Show Launch on Login Banner", icon: "sparkles", style: .secondary) {
                recordSettingsUtilityAction("debug_show_launch_login_banner")
                launchOnLoginReminderManager.shouldShowReminder = true
            }

            HStack(spacing: 10) {
                ModernButton(title: "Blue Theme", icon: "circle.fill", style: .secondary) {
                    recordSettingsUtilityAction("debug_theme_blue")
                    MilestoneCelebrationManager.setDebugThemeOverride(.blue)
                }
                ModernButton(title: "Gold Theme", icon: "circle.fill", style: .secondary) {
                    recordSettingsUtilityAction("debug_theme_gold")
                    MilestoneCelebrationManager.setDebugThemeOverride(.gold)
                }
                ModernButton(title: "Purple Theme", icon: "circle.fill", style: .secondary) {
                    recordSettingsUtilityAction("debug_theme_purple")
                    MilestoneCelebrationManager.setDebugThemeOverride(.purple)
                }
                ModernButton(title: "Reset Theme", icon: "arrow.counterclockwise", style: .secondary) {
                    recordSettingsUtilityAction("debug_theme_reset")
                    MilestoneCelebrationManager.setDebugThemeOverride(nil)
                }
            }
        }
    }
    #endif
}
```

- [ ] **Step 4: Add helper functions**

Add in `SettingsView`:

```swift
private func openExternalURL(_ urlString: String) {
    guard let url = URL(string: urlString) else { return }
    NSWorkspace.shared.open(url)
}

private func recordSettingsUtilityAction(_ action: String) {
    DashboardViewModel.recordSettingsUtilityAction(
        coordinator: coordinatorWrapper.coordinator,
        action: action
    )
}
```

- [ ] **Step 5: Wire search card resolver**

In `cardView(for:)`, add:

```swift
case "general.aboutSupport": aboutSupportCard
case "advanced.debugTools": debugToolsCard
```

- [ ] **Step 6: Remove Dashboard footer implementation and unused hover states**

Delete `footer`, its call site, and these dashboard-only hover states if no longer used:

```swift
@State private var isHoveringHaseab = false
@State private var isHoveringSupportMe = false
@State private var isHoveringFeedback = false
```

- [ ] **Step 7: Run focused build**

Run:

```bash
swift build
```

Expected: PASS.

---

### Task 6: Final Verification

**Files:**
- No new files unless fixes are required.

- [ ] **Step 1: Run targeted tests**

Run:

```bash
swift test --filter DashboardVoiceLayoutTests
swift test --filter DatabaseManagerTests/testVoiceDashboardMetricsRecordRealDailyMetricEvents
swift test --filter HotkeyHoldReleasePolicyTests
swift test --filter ProcessCPUMonitorPolicyTests
```

Expected: all PASS.

- [ ] **Step 2: Run sleep API guard**

Run:

```bash
scripts/check_no_nanoseconds_sleep.sh
```

Expected: PASS or no newly introduced `Task.sleep(nanoseconds:)` usages.

- [ ] **Step 3: Run full build**

Run:

```bash
swift build
```

Expected: PASS.

- [ ] **Step 4: Manual smoke test**

Run:

```bash
swift run Retrace
```

Expected:

- Dashboard opens with `Dictation` selected.
- `App Usage` is the second tab.
- Recent Insertions and Live Audio are visually separate.
- Compact stats appear at bottom.
- Old footer links are absent from Dashboard.
- Settings > General shows About & Support.
- Settings > Advanced shows Debug Tools in debug builds.
- Ctrl+Space dictation still works without dashboard open.

---

## Self-Review

- Spec coverage: The plan covers default Dictation, `App Usage` label, main inserted dictation panel, live transcript rail, bottom stats strip, footer relocation, metrics, async loading, and performance constraints.
- Placeholder scan: No `TBD`, `TODO`, or "implement later" placeholders are used as plan instructions.
- Type consistency: `DashboardContentTab`, `DashboardVoiceLayoutPolicy`, `DashboardVoiceContentMode`, and `DashboardLiveAudioRow` are introduced before later tasks reference them.
