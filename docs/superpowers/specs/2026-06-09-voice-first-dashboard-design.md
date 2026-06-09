# Voice-First Dashboard Design

Date: 2026-06-09
Status: approved concept, pending implementation plan

## Goal

Make the dashboard reflect Retrace's new voice-first direction. The default dashboard should prioritize push-to-dictate history and continuous audio transcription instead of treating dictation as an add-on above the legacy app usage view.

The selected layout is Concept A, "Voice Desk Split":

- Dictation is the default and first dashboard tab.
- App usage remains available as the second tab, labeled `App Usage`.
- Recent inserted dictations occupy the main content area.
- Continuous audio transcription is visible in a persistent right rail.
- Activity/stat widgets move out of the left rail into a compact bottom strip.
- The current footer utilities move into Settings.

## Non-Goals

- Do not redesign the full app visual identity in this change.
- Do not change the push-to-dictate hotkey behavior.
- Do not change audio capture, transcription, or insertion pipeline behavior except to expose existing data in the dashboard.
- Do not build FuseIntel ingestion or intelligence features in this dashboard change.

## Dashboard Layout

### Top-Level Structure

The dashboard content area should become a voice-first workspace:

1. Header remains at the top with recording controls and existing dashboard actions.
2. Content tabs sit under the header.
3. `Dictation` is first and selected by default.
4. `App Usage` is second and opens the existing app usage list/hard-drive view.
5. The previous left stats rail is removed.
6. The old footer row is removed from the dashboard.
7. A compact stats strip sits at the bottom of the content area, using the space freed by the old footer.

### Dictation Tab

The Dictation tab has two primary surfaces:

1. Main panel: `Recent Insertions`
2. Right rail: `Live Audio`

`Recent Insertions` shows the existing push-to-dictate sessions. It should keep the current session status language and visual treatment, including inserted, failed, cancelled, and pending states. This panel answers: "What text did Retrace insert, where, and when?"

`Live Audio` shows continuous transcription from the audio pipeline. This panel answers: "What is Retrace currently hearing, regardless of whether it was inserted?" It must be visually distinct from inserted dictation so the user does not confuse passive transcript capture with text that was actively pasted into another app.

The Dictation tab subtitle should explain the distinction:

`Inserted dictation plus live audio transcript`

### App Usage Tab

The App Usage tab keeps the existing app usage analytics as the main content:

- Existing list and hard-drive view modes stay intact.
- Existing weekly duration summary remains in the App Usage card.
- App Usage should use the expanded horizontal space that was previously split with the stats rail.

## Stats Strip

The old left-column widgets become compact dashboard stats in a bottom strip. The first implementation should be simple and glanceable rather than a carousel:

- Days Recorded
- Screen Time
- Storage Used
- Timeline Opens
- Searches
- Text Copies

Each stat should be a compact tile with the current value and short subtitle. Mini charts can be omitted in the first implementation if they create layout risk. If charts are retained, they must be small enough not to push the main content vertically.

The strip must not block access to the main content on shorter dashboard windows. If height is constrained, it can horizontally scroll or collapse to the top four stats, but the dictation/app usage content remains primary.

## Settings Relocation

The dashboard footer currently contains credits, support, help, and debug controls. These move to Settings:

- Add an `About & Support` settings card under General.
- Move `Made with love by @haseab`, `Support Me`, and `Help` into that card.
- Move debug theme controls into the existing Advanced area, preferably a `Diagnostics` or `Debug Tools` card.
- Remove the footer from DashboardView after equivalent Settings actions exist.

This keeps the dashboard focused on active use instead of project/meta actions.

## Data Flow

### Existing Sources

Recent dictation sessions already come from the dictation session storage path used by the dashboard.

App usage statistics already come from `DashboardViewModel`.

Stats strip data should reuse the existing `statsCards` data computed in `DashboardView`.

### Live Audio Rail

The live rail should use existing audio transcript data where available. The implementation should prefer a read-only, UI-safe query path:

1. Load the latest transcript segments asynchronously.
2. Refresh only while the dashboard is visible.
3. Avoid high-frequency polling that blocks or churns SwiftUI layout.
4. Show an empty state if no live transcript data is available.
5. Show an error state if transcript loading fails, without affecting dictation insertion history.

The rail can start as "recent continuous transcript" rather than true character-by-character streaming if the current transcription pipeline only commits segment-level text. It should still be presented as the place where passive audio transcript appears.

## Responsive Behavior

For normal dashboard widths:

- Recent Insertions uses roughly 65-70 percent of content width.
- Live Audio uses roughly 30-35 percent of content width.
- Stats strip spans the bottom.

For narrow widths:

- Dictation remains first.
- Live Audio moves below Recent Insertions.
- Stats strip becomes horizontally scrollable or wraps to two rows.

For short windows:

- Main content remains scrollable.
- Stats strip must not hide the App Usage list or Dictation rows.
- Footer removal should prevent the previous off-screen content problem.

## Metrics

The implementation must preserve existing daily metrics and add/adjust instrumentation for new user-visible actions:

- Keep dashboard tab selection metrics.
- Record when the default dashboard opens on Dictation.
- Record failures to load dictation sessions.
- Record failures to load live transcript data.
- Record Settings actions for Help, Support, and Debug controls if no suitable metric exists yet.

Metric metadata should include enough context to distinguish `dictation`, `app_usage`, `live_audio`, and `settings_footer_relocation` events.

## Error Handling

Dictation history and live audio transcript failures are independent:

- If dictation sessions fail to load, show the existing dictation history error.
- If live audio fails to load, show an error only in the right rail.
- App Usage must remain usable even if audio transcript loading fails.
- Missing microphone/system audio permissions should surface existing permission warnings rather than adding duplicate dashboard nags.

## Performance Constraints

The dashboard must stay UI-only on the main thread:

- No synchronous SQLite, file, icon, or transcript work in SwiftUI body builders.
- Load live transcript and dictation history asynchronously.
- Coalesce repeated dashboard refreshes.
- Avoid geometry preference feedback loops.
- Avoid adding continuous polling while the dashboard is hidden.

## Testing

Implementation should include targeted tests or smoke checks for:

- Dashboard default tab is Dictation.
- Dashboard tabs appear in order: Dictation, App Usage.
- Selecting App Usage records the correct tab metric.
- Selecting Dictation loads dictation dashboard data.
- Stats are no longer rendered as the left rail.
- Footer utilities are no longer rendered on the dashboard.
- Settings exposes support/help/debug actions.
- Live Audio rail handles empty, loaded, and error states.
- Narrow and short window smoke checks do not hide App Usage behind fixed footer content.

## Open Decisions Resolved

- The second tab label is `App Usage`.
- Concept A is the chosen layout direction.
- Continuous transcription is separate from inserted dictation and should be visually distinct.
