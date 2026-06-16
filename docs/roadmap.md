# Retrace Product Roadmap

## Product Thesis

Retrace is the voice-first Mac memory layer: the active input and computer recording system that captures what happens on the Mac, turns speech into controlled action, and preserves raw evidence locally.

Retrace is not the full intelligence platform. The ingestion and intelligence layer is a separate software product, referred to for now as **FuseIntel**. FuseIntel is the intel loop layer: an NSA-high-grade intelligence platform for authorized personal and organizational data that fuses Retrace's raw screen/audio input with other ingested sources such as email, SMS, Teams, Otter, Notion, calendar data, documents, and future connectors.

The system boundary is intentional:

- **Retrace** records, compresses, indexes, displays, dictates, exports, and controls local Mac memory.
- **FuseIntel** ingests broad external context, correlates signals, builds intelligence, produces briefs, identifies open loops, and feeds context back to Retrace.

Together, they create a local-first capture layer plus a high-grade intelligence loop. Separately, each product has a clear job.

## Layer Model

### Retrace: Active Input And Computer Recording Layer

Retrace owns the user's immediate Mac surface.

Responsibilities:

- Voice-first dictation into any app.
- Continuous screen recording and screenshot history.
- Continuous microphone and system-audio capture where permitted.
- OCR, transcript storage, timeline replay, and source evidence.
- Compression, retention, export, deletion, and local privacy controls.
- Fast local recall over raw screen/audio memory.
- A UI surface where FuseIntel insights can appear in context.
- A permissioned bridge that lets FuseIntel request or reference local evidence.

Retrace should feel like the user's local black box, active microphone, command input layer, and evidence recorder.

### FuseIntel: Ingestion And Intelligence Loop Layer

FuseIntel owns cross-source intelligence.

Responsibilities:

- Ingest external sources such as email, SMS, Teams, Otter, Notion, calendars, documents, browser exports, and future connectors.
- Normalize and enrich raw inputs from many systems.
- Correlate people, organizations, projects, decisions, obligations, promises, meetings, documents, and timelines.
- Build entity graphs, event timelines, dossiers, briefs, open-loop lists, and situational assessments.
- Fuse Retrace screen/audio evidence with external data.
- Produce intelligence back to Retrace where it helps the user act in the moment.
- Maintain auditability around what data was used and why a conclusion was produced.

FuseIntel should be treated as a high-grade intelligence platform, not a feature inside Retrace.

## Positioning

Retrace is for Mac power users who need reliable memory and controlled input while they work across meetings, terminals, browsers, editors, chats, and AI tools.

Core Retrace promise:

- Remember what happened on your Mac.
- Dictate into any app with push-to-talk precision.
- Replay or search raw screen and audio evidence.
- Store months of local history without filling your drive.
- Export anything and avoid lock-in.
- Keep capture control close to the user.

Core FuseIntel promise:

- Turn raw inputs and external data into operational intelligence.
- Connect what was seen, said, sent, promised, assigned, and decided.
- Surface the right context back into Retrace at the moment of action.

## Differentiation

### 1. Voice-First Mac Memory

Retrace should make push-to-dictate a signature capability.

Key ideas:

- Continuously transcribe local audio.
- Insert only the speech captured between hotkey press and release.
- Preserve the target app/window context for every insertion.
- Support per-app writing styles for Slack, email, docs, terminal commands, code comments, and AI prompts.
- Add optional rewrite modes before insertion: concise, polished, casual, command, meeting note, TODO, and original transcript.
- Show a small floating capture pill while dictating with waveform, target app, elapsed time, and insertion status.

Why this makes Retrace distinct:

Most memory products are passive recall tools. Retrace becomes an active input layer.

### 2. Computer Recording As Raw Evidence

Retrace should be the authoritative local record of what happened on the Mac.

Key ideas:

- Timeline replay remains important, but it is framed as evidence, not the whole product.
- OCR and audio transcripts should always link back to exact screenshots, apps, windows, URLs, and timestamps.
- Search results should be source-backed by default.
- Every exported clip, transcript, or evidence package should preserve provenance.

Why this matters:

FuseIntel can reason across many sources, but Retrace provides grounded computer evidence.

### 3. FuseIntel-Powered Intelligence In Context

Retrace should display intelligence, but FuseIntel should produce it.

Example FuseIntel outputs shown inside Retrace:

- "This moment relates to the FuseScale billing migration thread."
- "This Teams call appears to create 3 open loops."
- "This email contradicts the meeting note from yesterday."
- "This Claude session connects to Jira issue FS-448 and the Notion rollout plan."
- "This person, project, and deadline have appeared across SMS, Teams, and Otter."

Retrace UI surfaces:

- Intel cards attached to timeline moments.
- Episode summaries powered by FuseIntel.
- Open-loop overlays.
- Context panels beside dictation, search, and replay.
- Evidence links that jump back into raw Retrace recordings.

Boundary:

- Retrace shows and anchors the intelligence.
- FuseIntel produces and maintains the intelligence.

### 4. Episodes As A Shared Interface

Episodes should become the bridge object between Retrace and FuseIntel.

Retrace episode inputs:

- Screen activity.
- Audio transcript windows.
- Apps, windows, browser URLs, and files.
- Dictation sessions.
- Search and replay references.

FuseIntel episode enrichments:

- Related emails, SMS, Teams messages, Otter transcripts, Notion pages, calendar events, and documents.
- People, organizations, projects, promises, decisions, and deadlines.
- Summaries, contradictions, open loops, and recommended follow-up.

Examples:

- "Debugging Ctrl+Space dictation hotkey"
- "Teams meeting about roadmap"
- "Reviewing customer emails before proposal"
- "Implementing dashboard tabs"
- "Reconciling Otter notes with Notion tasks"

Why this makes the system distinct:

Raw timelines are hard to navigate. Episodes turn recordings and external data into operational memory.

### 5. Memory Cockpit Dashboard

The Retrace dashboard should become a cockpit for local capture, dictation, and FuseIntel context.

Suggested Retrace dashboard sections:

- Now: recording, transcription, storage, model state, and current capture permissions.
- Dictation: recent inserts, failures, target apps, and rewrite modes.
- Recall: local searches, saved moments, and source-backed evidence.
- Episodes: work blocks with FuseIntel enrichment when available.
- Intel: FuseIntel cards, open loops, related entities, and briefings.
- App Usage: retained as supporting analytics, not the hero surface.

Why this makes Retrace yours:

The product stops feeling like a generic activity dashboard and starts feeling like the command surface for local memory and active input.

### 6. Advanced Compression And Easy Exporting

Compression should become a headline Retrace capability:

> Advanced compression technology - the entire screen history takes only 10-15 GB per month. Store months of data without filling your drive.

This should be treated as a product-level promise once the implementation supports it reliably.

Roadmap requirements:

- Hit a practical storage target of 10-15 GB per month for typical continuous use.
- Preserve readable OCR and usable replay quality while reducing storage.
- Show projected monthly storage in settings and dashboard.
- Let users tune quality, retention, and capture frequency with clear tradeoffs.
- Detect when storage is growing faster than expected and explain why.

Easy exporting should be equally prominent:

- Export any time range as video.
- Export any episode as a package with video, screenshots, transcript, metadata, and links.
- Export transcripts as Markdown, JSON, CSV, and plain text.
- Export search results with timestamps and source context.
- Export a portable archive for backup or migration.
- Add a "share evidence" flow for selected moments without exposing unrelated private history.

Why this matters:

Retrace owns the local evidence layer. Storage economics and exportability are core trust features.

### 7. Privacy And Chain Of Custody

Retrace and FuseIntel both need visible privacy controls, but their controls are different.

Retrace controls:

- What is being recorded now.
- Which apps, windows, displays, microphones, and audio sources are excluded.
- One-click "forget this app/window/range" actions.
- Local storage inventory and retention settings.
- Export audit data for selected evidence.

FuseIntel controls:

- Which external connectors are enabled.
- Which source records were used to generate an assessment.
- What entities, topics, and dossiers were built.
- Which intelligence outputs were sent back to Retrace.
- Audit logs for data access and inference generation.

Why this matters:

The system can be powerful without becoming opaque. The user must be able to inspect the capture layer and the intelligence layer separately.

## Roadmap

### Phase 1: Own The Retrace Voice Workflow

Goal: make Retrace unmistakably voice-first and action-oriented.

- Improve the dictation dashboard tab into a full command center.
- Add floating dictation capture pill.
- Add rewrite-before-insert modes.
- Add per-app dictation styles.
- Add failed insertion recovery with copy-to-clipboard fallback.
- Add clear settings for microphone, shortcut, target behavior, and formatting.

Success criteria:

- A user can replace a Wispr Flow-style workflow for daily text input.
- Dictation feels intentional, fast, and safer than generic continuous transcription.

### Phase 2: Harden The Computer Recording Layer

Goal: make Retrace the trusted raw evidence layer.

- Improve timeline replay, search, and transcript alignment.
- Ensure screen OCR and audio transcript results always link to source moments.
- Add evidence export for selected time ranges.
- Add deletion and retention controls that are obvious and fast.
- Add visible recording status for screen, microphone, and system audio.

Success criteria:

- A user can recover a seen or heard detail in under 10 seconds.
- Any result can be traced back to a timestamped screen/audio source.

### Phase 3: Define The Retrace-FuseIntel Bridge

Goal: make the product boundary explicit and technically clean.

- Define a local event/evidence API from Retrace to FuseIntel.
- Define a FuseIntel insight feed back into Retrace.
- Create stable IDs for moments, episodes, apps, windows, transcript spans, screenshots, and exports.
- Add permission gates for FuseIntel access to Retrace data.
- Add audit logs showing what FuseIntel requested from Retrace.

Success criteria:

- FuseIntel can enrich Retrace moments without owning Retrace's local recording store.
- Retrace can display FuseIntel intelligence without becoming the ingestion platform.

### Phase 4: Episodes And Intel Cards

Goal: use FuseIntel to add meaning around Retrace recordings.

- Detect Retrace-side candidate episodes from app/window/audio continuity.
- Send episode candidates to FuseIntel for enrichment.
- Display FuseIntel summaries, entities, related source records, open loops, and recommended follow-up inside Retrace.
- Link every intelligence card back to raw Retrace evidence and external FuseIntel sources.
- Allow users to export enriched episodes as evidence packages.

Success criteria:

- A user can browse their day as meaningful work blocks instead of frame streams.
- FuseIntel can explain why an episode matters using both Retrace and external source data.

### Phase 5: Storage, Compression, And Export

Goal: make months of local computer memory practical.

- Optimize HEVC settings and deduplication for the 10-15 GB/month target.
- Add storage projection and quality controls.
- Add export flows for time ranges, episodes, transcripts, screenshots, and evidence packages.
- Add archive and restore flows.
- Add retention policies that explain what will be deleted before it happens.

Success criteria:

- Typical users can store months of history without filling their drive.
- Users can leave, back up, or share selected memory without proprietary lock-in.

### Phase 6: FuseIntel As The Intel Loop Platform

Goal: establish FuseIntel as the separate high-grade intelligence platform.

- Build connectors for email, SMS, Teams, Otter, Notion, calendar, and documents.
- Normalize entities, dates, people, organizations, projects, and commitments.
- Build cross-source timelines and dossiers.
- Generate briefs, contradictions, open loops, recommended actions, and tasking queues.
- Feed relevant intelligence back into Retrace in context.

Success criteria:

- FuseIntel can explain a situation using multiple source systems, not just screen/audio memory.
- Retrace becomes the local action and evidence surface for FuseIntel output.

## Product Language

Use language that keeps the product boundary clear.

Retrace language:

- "Voice-first Mac memory."
- "The active input and computer recording layer for your Mac."
- "Dictate into any app with push-to-talk precision."
- "Replay what happened on your screen."
- "Search local screen and audio evidence."
- "Months of history without filling your drive."
- "Export anything. Keep everything portable."

FuseIntel language:

- "The intel loop for your work and communications."
- "High-grade intelligence across email, SMS, Teams, Otter, Notion, and your Mac activity."
- "Turn raw inputs into briefs, open loops, dossiers, and decisions."
- "Fuse what was seen, said, sent, promised, and decided."

Avoid language that blurs the boundary:

- Do not describe Retrace as the full ingestion platform.
- Do not make broad connector ingestion a core Retrace responsibility.
- Do not lead with "open-source Rewind alternative" as the product identity.
- Do not frame FuseIntel as a minor feature inside Retrace.

## Near-Term Product Identity

Recommended Retrace identity:

> Retrace is the voice-first Mac memory layer: an active input and computer recording system that captures what you see and hear, lets you dictate into any app with precision, compresses months of local history, and exports source-backed evidence whenever you need it.

Recommended FuseIntel identity:

> FuseIntel is the separate intel loop layer: a high-grade intelligence platform that ingests external sources, fuses them with Retrace's raw computer memory, and returns actionable context, open loops, briefs, and evidence-backed assessments.
