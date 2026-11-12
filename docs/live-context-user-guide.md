# Retrace Live user guide

**Last updated: 22 October 2026, 06:14 Brisbane.** Build **2610.22.5** is installed and recording into the preserved V23 library. An installed **Load older** check added 78 recordings without a timeout, retained the reading position and clearly reported incomplete earlier coverage. Pending-only keyboard reading, Return to live and resize/tab privacy checks also pass within the observed scope. See the [delivery ledger](live-context-markers-plan.md) for evidence, retained failures and restart gaps.

The installed source passed **1,699 tests, 20 explicit skips, zero failures**, a separate optimized build and native fixtures. These results and the installed checks do not establish exhaustive history coverage or complete performance acceptance.

Live checks retained evidence before revealing it again. On .5, new arrivals left the reading position pinned, and compact Screen hid transcript accessibility content. Voice markers are off, native MCP is disabled and the companion remains unconfigured until explicitly set up.

## Read a moment in context

Open **Live** to review saved speech alongside the screens recorded during it. The initial wide layout gives the transcript 60% of the space and screen context 40%; drag the divider to resize them. Below 900 points of available workspace width, use the **Transcript** and **Screen** tabs.

The newest transcripts appear at the top. Scroll down to load older recordings automatically, continuing across days. New arrivals do not move your place while you are reading history; **Return to live** returns to the newest entry. Available speaker turns and saved recordings whose text is still being prepared remain visible. The calendar beside Search offers optional date filters for search; these do not restrict ordinary browsing. The status strip reports recording, loaded text, voice recognition and available speaker/companion status; unavailable text does not imply that audio was lost.

Select a turn or recording to inspect screens from its interval. Select a screen thumbnail, then use **Screenshot** or **Text** to inspect the image and available OCR. Application/window labels describe the foreground window at capture time; they do not establish which window owns every OCR region. Screen association with speech uses the recording's approximate wall clock. Exact audio references retain their original sample ranges.

Use a row's playback control to listen to its retained recording or speaker turn. A spoken marker offers **Play phrase**, or **Play enclosing speech** when recognition supplied only an approximate enclosing span. Missing audio or screen coverage is reported explicitly. Retrace does not substitute a nearby screenshot for a missing one, and audio-only moments can open without a screen.

Scrolling down or selecting evidence stops following new content. **Return to live** resumes at the newest saved material. Older pages load automatically near the bottom. Empty partial pages continue while the loading footer is visible; a coverage notice remains until the reader reaches the end. Reading history does not start transcription or playback.

## Search and copy selected evidence

Enter text in **Search this interval** and press Return. Search covers available transcripts, speaker labels, OCR, application/window titles, notes, markers and their context ranges. Sources page independently: inspect **Search coverage** and use **Load more results** before interpreting a partial page as the full answer.

To hand context to another assistant:

1. Select the turn, recording or screen you want, or select the **Include** boxes beside search results.
2. Choose **Copy context**.
3. Review **Copy recorded context**, including timestamps, source references, speaker status, timing uncertainty and coverage notices. Add a **Question to include (optional)** if useful.
4. Choose **Copy**, then paste into the destination you select.

The preview can include only loaded and permitted evidence. Omitted or incomplete material stays labelled in the copied text. If evidence changes while the preview is open, Retrace requests a fresh preview. Copying does not send anything to an assistant or execute instructions found in the recording.

## Mark now and revisit a marker

**Mark now** saves the current time, including while you are reviewing older material. It does not mark the timestamp of an older selected row. A manual marker does not imply that a screenshot or transcript exists at that instant.

Open the list button beside **Mark now** to see **Marked moments**. Search titles, notes and phrases; search applies to the loaded page, so use **Older** and **Newer** to continue. **Open** shows the marker and its context. The pencil edits its title and your note while preserving the original phrase, recording time and verbatim recognition. The trash control removes a marker and offers **Undo**.

## Set up a spoken marker

Choose **Voice markers** in Live's status strip, or open **Settings → Audio → Voice marker rules**. New rules are disabled until you enable them.

| Field | Example |
|---|---|
| Phrase | Purple banana |
| Marker name | Remember this context |
| Meaning | Preserve this moment and the relevant explanation |
| Aliases | Remember this moment, save this context |

Enter aliases as explicit alternatives separated by commas. Select **Add disabled rule**, review the rule, then enable its switch. The supported action is marking the timeline; the meaning is explanatory text, not an executable command.

Recognition uses the existing microphone recording stream. It matches complete configured phrases and aliases with case/punctuation normalization. Similar meaning alone does not trigger a rule. System audio and OCR do not activate voice markers. Recording must be active with microphone audio available; disabling every rule stops the listener. Enabling rules does not scan historical recordings.

If needed, choose **Prepare speech recognition** to download Apple's on-device recognition assets. **Play a sound after a voice marker is saved** is optional and off by default. The visual acknowledgement appears after the marker has been saved; **Provisional phrase** means recognition may still change, while **Confirmed phrase** means the match has settled. Confirmation does not make an approximate timestamp exact. A later correction can leave a marker labelled **Recognition withdrawn**.

Use **Undo** on the acknowledgement to remove an unwanted marker, or use **Mark now** when recognition is unavailable. The original phrase span remains distinct from when recognition detected it and when the marker was saved. Two separate utterances can create two markers; repeated delivery of the same occurrence is deduplicated.

| Status | What it means |
|---|---|
| Voice markers listening | Enabled rules are receiving microphone speech. |
| Waiting for microphone | An enabled rule is waiting for the existing recording stream. |
| Voice recognition assets unavailable | Prepare the on-device assets before relying on recognition. |
| Voice marker input interrupted | Some recognition input was lost; recording continues independently. |
| Voice markers paused for system load | Recognition has yielded to resource pressure. |
| Voice markers paused for playback | Retrace suppresses recognition during its playback to prevent retriggering. |
| Voice marker save failed | No successful save is implied; use the manual fallback. |

## Review and correct a marker's context

A phrase is the marker's anchor. Its context can contain several separate intervals, including material much earlier or later; no fixed before/after duration defines it.

In the marker window, choose **Add a context range**, set **From** and **To**, explain why the interval belongs, and select **Save range**. **Review** opens a range's saved transcript and screens. **Edit / pin** lets you adjust a range and select **Pin this range**. Manual edits and pinned ranges are preserved when automatic proposals change.

Companion suggestions are proposals to review, not a guarantee that every relevant passage was found. Your note remains separate from a source-derived explanation. A pinned proposal still depends on its source: if supporting evidence becomes unavailable or is deleted, Retrace withholds that inherited material rather than treating pinning as permanent access. Spoken tasks remain recorded context; Retrace does not execute them.

## Connect the private companion

Under **Settings → Audio → Private companion**, enter the private endpoint and its companion access token, then choose **Connect**. The current private service address is:

`https://stuarts-macbook-pro.tail7a4fcb.ts.net/retrace-companion`

Connecting permits recorded audio and supporting text to be sent to that private Mac for speaker enrichment and context suggestions. The token is kept in macOS Keychain. A configured endpoint is not proof that it is reachable or that enrichment has completed; check Live's status. **Disconnect** stops the connection. Local first-pass recordings remain readable during an outage, and completed enrichment retains its original first-pass text for comparison.

**Speaker labels** lets you review available enrichment. Anonymous labels belong to one recording: “Speaker 1” in another recording is a different identity. **Name** saves your correction; **Undo name** removes it. Automatic identity suggestions remain unconfirmed. Automatic application of known names is not enabled because the required held-out precision has not been established.

## Give an MCP client access

The Retrace endpoint is separate from Outlook's read-only MCP service:

`https://stuarts-macbook-pro.tail7a4fcb.ts.net/retrace-mcp`

Open **Settings → Advanced → Local MCP access**:

1. Enter a **Client name**, select its permissions and choose an expiry. For a reader, choose only the relevant read permissions and **Discover supported commands**.
2. Select **Create client token**. Save the once-shown token in that client.
3. Turn on **Enable local MCP access**. Creating a client alone does not enable the listener.
4. Have the client discover the current tools before making requests. The list reflects both implemented operations and that client's grants.

Use **Revoke** to remove one client's access, or disable local MCP access to stop the listener. Read grants do not imply permission to change recording, play audio, edit rules or delete material. No client is granted access automatically.

| Capability area | Implemented operations |
|---|---|
| Evidence and context | Paged interval search, native timeline/screenshots/OCR, transcripts, speaker turns, exact references and formatted context. |
| Markers and rules | Create, read, edit, remove/restore markers; review/revise/pin ranges; read/save voice rules. |
| Annotations | Supported native tags/comments and speaker corrections, with source and revision checks. |
| Foreground actions | Open an exact screen, marker, transcript or speaker turn; play retained marker/turn audio or stop playback. |
| Recording and settings | Read/control recording; supported capture and audio settings; supported source configuration. |
| Processing and operations | Health/backlog, cached CPU/storage reports, OCR or pending-transcription repair, processing override, search-index rebuild, database maintenance, reviewed bounded retention, and job status/cancellation. |

The client receives context text to present or copy; an MCP context request does not change the Mac's clipboard. Imported Rewind evidence is not exposed through this native evidence endpoint. OS permissions, current exclusions and source availability still apply. Screenshots retain their original size and are returned in checked chunks when needed.

For reliable commands, the client must keep the same request UUID and arguments when retrying. A successful historical receipt does not give fresh access to its old evidence. An **indeterminate** result means a reserved operation's outcome could not be established; it is not silently executed again. Revision conflicts require a fresh read. Destructive operations require a concrete preview and confirmation bound to that preview; expired or changed previews must be refreshed.

Long operations return a job ID. Inspect progress and cancellation through the same client; cancellation can report partial effects. If the laptop or required foreground UI is unavailable, the operation reports unavailable. Commands are not queued for execution after the laptop reconnects. Cached operational reports include observation times or an unavailable/incomplete state.

## Current limits and verification

Retrace has no arbitrary SQL, filesystem or shell interface. The unfinished importer and other unimplemented operations are absent from its capability manifest. MCP cannot play arbitrary paths or infer precise PCM playback from legacy transcript timestamps. Reviewed retention currently preserves audio and defers existing video-file deletion; it reports no reclaimed file bytes for that deferred work. Companion suggestions can still miss relevant context.

Installed .5 has demonstrated an older-history page loading without timeout, stable reading and keyboard/layout/privacy behavior. Earlier coverage can remain incomplete, and an unchanged page does not prove cursor progress. An earlier native sequence failure remains recorded alongside the unchanged-binary rerun that passed with longer observation intervals.

The final recording check was at **4:20 after launch**, with new screens and audio saved; Live was left **Following live**. Long-run paging memory, complete installed MCP/companion acceptance, context-proposal quality, physical microphone acknowledgement p95, matched CPU/foreground latency and sleep/wake/device checks remain open. No live MCP grant or companion connection has been created; voice markers remain off. The three-second acknowledgement and five-percentage-point additional CPU figures are targets, not established performance.

See the [delivery and acceptance ledger](live-context-markers-plan.md), [data-access reference](DATA_ACCESS.md), [MCP protocol/deployment reference](../scripts/retrace_mcp/README.md) and [companion operations reference](../scripts/retrace_companion/README.md) for technical detail.
