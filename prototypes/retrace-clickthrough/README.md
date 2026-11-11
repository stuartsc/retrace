# Retrace click-through and project record

Open **index.html** in a browser. No installation, server, internet connection or other project files are required. Copy this entire directory anywhere and open its index.html there.

## Contents

- [Directory](index.html) — links to all parts of the package.
- [App prototype](app.html) — all main screens, with authored sample content and in-memory interactions.
- [Full specification](docs/full-spec.html) — product, workflows, architecture, acceptance and status boundaries. [Editable Markdown](docs/full-spec.md).
- [Issues journal](docs/issues-journal.html) — a substantial searchable chronology, including audio capture and transcription failures. [Editable Markdown](docs/issues-journal.md).
- [Supporting records](docs/sources/index.html) — local text snapshots, provenance and unavailable-receipt notices.
- [Verification](docs/validation.html) — browser checks, portable-copy/offline test and limitations.
- [Build journal](docs/session-log.html) — implementation and troubleshooting record.
- [File manifest](bundle-manifest.json) — package hashes and source provenance reference.

## Try these paths

1. Live → select a transcript → Screenshot / Text → open the moment in Timeline.
2. Scroll Live down to load older recordings across four sample days. Return to live jumps to the newest. Optional search dates never limit ordinary browsing.
3. Search for “audio”, “Purple banana”, “storage” or “Ghostty”. Open a result and inspect its matching screen.
4. Mark now → edit the title and note → add/pin a context range → review the interval. Delete a marker and Undo.
5. Live → Voice markers → add a phrase (initially disabled), enable it, or try the Purple banana sample.
6. Timeline → Audio Recordings, filters, date selection, tags and comments.
7. Settings → Audio / Advanced → walk through the companion and MCP configuration. Use made-up values only.
8. System Monitor → Process now → Cancel. Settings → Storage → review the sample breakdown and retention confirmation.
9. Read the specification and search the issues journal for “silent”, “AAC”, “backlog” or “CPU”.

## Keyboard and behaviour

Tab and Shift+Tab move through controls; Enter activates a button or submits search. Escape closes dialogs. Cmd/Ctrl+K opens search; Cmd/Ctrl+[ returns to Dashboard. Arrow keys switch focused tabs; Timeline arrows select previous/next moments. Search-result arrow keys move through loaded results. The browser Back button returns through page routes.

All changes live only in this tab's memory. Reload or **Reset demo** restores the initial examples. Clipboard buttons copy only the text you explicitly request; a manual-copy fallback is shown if the browser blocks clipboard access from a local file. No localStorage, cookies, database, audio devices or filesystem APIs are used.

## Boundaries

This is a click-through, not the native application. Recording, playback, measurements, models, companion connections, MCP tokens and destructive confirmations are illustrative. It contains no real recorded media, Whisper models or client credentials. It does not prove native capture accuracy, latency, performance, installed acceptance or historical coverage.

The documents distinguish the installed local trial, source candidates, plans, superseded work and unverified acceptance. References were assembled from surviving project records on 11 November 2026. Some old temporary build logs and physical acceptance receipts no longer exist and are labelled unavailable. Historical authorisation assertions for part of the 9 November network cleanup are disputed and must not be treated as a fresh deletion approval.

## Editing

The application uses ordinary HTML, CSS and classic JavaScript in `assets/`. Documentation uses HTML, Markdown and local assets in `docs/`. No build step is needed after editing. Keep links relative and inside the directory; update the manifest and validation record when changing the package. Do not add symlinks, CDN fonts, hosted images or runtime fetches.
