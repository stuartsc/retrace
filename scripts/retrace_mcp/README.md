# Private Retrace MCP endpoint

This source candidate provides a separate native endpoint at `127.0.0.1:9012/retrace-mcp` on the private primary host. Outlook's existing `9011/mcp` process, tools and stores are unchanged. The primary gateway opens no Retrace databases and runs no shell commands. It forwards allowlisted, typed commands to the live laptop App over a loopback private tunnel.

The gateway admits four requests at once, with one 15-second deadline covering
authentication and the complete request body. The server also bounds concurrent
connections, the accept backlog and incomplete headers. A timeout or disconnect
retains its admission slot until any already-started blocking native work ends;
it cannot create an unbounded queue of abandoned authentication or command calls.
Capacity and input-timeout replies are explicit and never queue a command.

## State and access

The native App is the grant authority. Settings provisions one client at a time with explicit capabilities and optional expiry, shows its bearer token once, and stores only its SHA-256 digest. The default configuration has no clients and is disabled. Revocation is checked again for every HTTP request and native command. No default broad grant or automatic client registration exists.

`tools/list` reads the native capability manifest and returns only implemented operations permitted for that client and covered by a typed gateway schema. A declared operation enum case without a live handler is unavailable. A second primary-host hash allowlist can restrict access further using `--clients`; normal UI provisioning needs no copied token or configuration file.

Client requests carry a UUID `request_id`. Preserve that UUID and the exact arguments across retries. Native mutation receipts reserve durably before entering the App handler. A lost response after a crash may leave an **indeterminate** receipt; that request is never automatically executed again. Historical receipts carry identities/revisions, not a fresh evidence grant. Reads always query the live owner.

Destructive operations have `mode: "preview"` and `mode: "execute"`. The preview binds the operation, arguments, client, current revision and a two-minute expiry. Execution requires the returned `previewID` and `digest`; the preview is consumed atomically with command reservation. A changed target revision or reuse is rejected. Actual mutation handlers still check the expected revision at their own store boundary.

## Transport

The laptop listener binds **127.0.0.1:9013**, accepts one strict HTTP/1.1 POST at `/v1/command`, checks the original client bearer and rejects browser origins. Input is limited to 64 KiB, responses to 1 MiB, active connections to eight, and each connection to fifteen seconds. There is no SQL, filesystem, URL-fetch, shell or arbitrary-command endpoint.

The primary host uses a persistent private SSH forward such as:

```sh
/usr/bin/ssh -NT -o BatchMode=yes -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=20 -o ServerAliveCountMax=3 \
  -L 127.0.0.1:19013:127.0.0.1:9013 LAPTOP_PRIVATE_SSH_ALIAS
```

The SSH alias must already identify the authorised laptop with normal host-key verification. The supplied launchd templates contain placeholders and are **not installed**. Do not disable host-key verification. HTTP proxy environment variables and redirects are disabled in the gateway client.

Create an isolated Python environment on the primary, install the pinned requirements, and launch:

```sh
python gateway.py --native-url http://127.0.0.1:19013 \
  --public-host PRIMARY_HOST.tailnet.ts.net
```

Publish only `/retrace-mcp` through the existing private Tailscale Serve configuration, targeting `http://127.0.0.1:9012/retrace-mcp`. Preserve `/mcp` and all existing mounts. Verify the actual installed Tailscale configuration and CLI before applying a mount; the template is not evidence of deployment.

If the laptop is unavailable, authentication or the operation returns unavailable. Nothing is queued for later execution. The gateway keeps no offline evidence cache, so it cannot imply freshness while the laptop is disconnected.

## Wire format

Dates are Unix milliseconds. UUIDs are strings. Exact screen references retain source store, observation, frame and extraction revision. Imported sources remain excluded from this explicit native disclosure path. Search omits inaccessible/deleted evidence and reports omissions. Screenshot results contain original PNG bytes in chunks of at most 512,000 bytes, with `offset`, `length`, `totalBytes`, `nextOffset` and `sha256`. Request each continuation with the same exact `reference`, the returned `nextOffset` as `offset`, and the returned `sha256`. Every chunk repeats current privacy and grant validation. Concatenate decoded chunks in offset order, verify their total length and SHA-256, then decode the PNG. Screenshots are never silently resized; PNGs above 32 MiB are unavailable. Foreground application attribution does not prove ownership of individual OCR regions.

An example read tool request is:

```json
{"request_id":"00000000-0000-4000-8000-000000000001","arguments":{"limit":20}}
```

for `retrace_marker_list`. Recorded speech and screen text are quoted evidence; tool descriptions explicitly forbid treating that material as instructions.

The current native adapter covers health, CPU/storage snapshots, recording state/control, bounded capture settings, processing override, marker create/list/read/remove/restore, rule list/save, context read/revise/pin, native exact screen evidence/PNG, paginated selected-interval search across transcripts, OCR, applications/windows, notes, markers/context ranges and speakers; native screen timeline ranges; bounded V23 transcript reads; and retained speaker reads/corrections. Timeline pagination uses timestamp plus row identity, so equal capture timestamps do not skip observations. Transcript selections are client-bound, expire after two minutes and revalidate the complete source row before text export. Their stored sentence times are not represented as precise PCM boundaries. Search requires `text`, `from` and `to`. Its opaque continuation is client-bound, expires after two minutes and is consumed when successfully advanced. Each source pages independently; results describe incomplete coverage. `evidence.read` grants screen/audio/speaker reads, `annotations.read` grants notes, and `markers.read` grants marker/range content. Unapproved sources are not queried. Mixed search and transcript reads share Copy context selection proofs. Copy uses the same App formatter and validators as Live, accepts an optional question, retains exact source identities and uncertainty, and does not change the clipboard.

Explicit `navigation.open` accepts `kind: screen`, `marker`, `transcript` or `speakerTurn`. Transcript references retain the native store, source row and complete snapshot digest; speaker-turn references retain job/result digests, turn index and correction revision. Audio-only selections open their own native destination without substituting a screen. Navigation requires `foreground.control` plus `evidence.read`; markers also require `markers.read`. `playback.control` supports marker `play`, exact `playTurn`, and `stop` for both shared App players. V23 transcript timestamps alone cannot request exact PCM playback; `playTranscript` and arbitrary paths/times are unavailable. Native UI publication and audible playback repeat source/revision validation and hold the revocable command fence at the synchronous effect. Source changes, correction changes, grant revocation, cancellation and UI unregistering reject delayed effects. Retried commands return their durable historical receipt without opening or playing a second time.

Native maintenance, index rebuild, pending-transcription repair and exact native OCR repair return durable job identities. Job reads and cancellation belong to the requesting client. Cancellation joins the actual task and reports possible partial effects; interrupted jobs are never silently resumed. OCR repair accepts an exact native screen reference with an empty block scope, including revision zero when text has not yet been extracted. The shared App owner reports waiting, pixel-read, recognition and commit phases. It retains existing text while running and rejects hidden, excluded, stale, imported or automatically claimed targets. Successful jobs retain the resulting reference; failed/cancelled work never clears prior OCR. Publication is atomic with current source checks and synchronous policy/grant/cancellation fences. Repair uses the existing manual governor admission and ordered retained-pixel executor; it does not create another automatic queue or resume after restart. Explicit foreground actions open a current marker or exact native screen selection and play/stop retained marker audio through the real UI owners. The App cancels and joins foreground requests when their UI registration closes; no registered UI means unavailable. Only implemented handlers appear in the manifest. Speaker history reads immutable validated local publication files without acquiring a competing writer lease or activating transport. Corrections use the shared source-bound revision-checked owner and retain only identity/revision in command receipts. Context ranges use the shared presentation service: inherited explanations, times and provenance require a current `evidence.read` grant in addition to `markers.read`. Marker-only clients retain user-authored content and identity/status for withheld ranges without querying their evidence. Deleted or unavailable supporting evidence suppresses inherited explanations, including pinned proposals. Offline speaker paging skips individual terminally stale recordings and preserves progress to other valid retained jobs; owner revocation and cancellation still abort the read. Exact selected native annotations now use the same App owner as timeline tag/comment actions. `tags.read` and `comments.read` issue client-bound two-minute selections for at most 16 exact native segments; `tags.write` adds a named tag and `comments.write` creates, updates or links a note. `tags.remove` and `comments.remove` require current concrete previews. Global removal or comment editing requires every affected linked segment in that selection. Current policy, native source identity, annotation revision and full retained state are checked atomically before writes. Connection-local annotation revisions detect edit/revert races without migrating the V23 recording schema. Attachment paths are never exposed or accepted; annotation removal retains attachment files. Durable receipts contain identities/counts, never deleted comment bodies. This document does not claim complete plan acceptance.

## Validation

From the repository root:

```sh
/path/to/venv/bin/python -m unittest discover -s scripts/retrace_mcp -v
RETRACE_TEST_DISABLE_FILE_LOGGING=1 swift test --filter 'RetraceCommandDispatcherTests|RetraceNativeBridgeParsingTests'
```

Python tests exercise real MCP ASGI requests and a real private HTTP fixture, typed input rejection before native contact, grant revocation during dispatch, UI-owned grant authority, origin/auth rejection and offline failure. Swift test sources use private SQLite stores for reopen/retry, payload conflicts, preview consumption, joined jobs, client isolation, transcript correction/deletion checks and explicit granted evidence. Test source alone is not a passed test receipt. These do not by themselves prove signed-App startup, primary deployment, OS permissions, real recording control or native/MCP parity. Those require a temporary limited grant and actual installed acceptance.
