# Active responsiveness implementation — 13 November

User authorised the full repair plan. Work is ongoing; do not treat the first source candidate as completion or installation. Do not use foreground computer control, visible tests or live capture devices. Preserve all recorded history.

## Workspaces

- Primary repair: `/Users/stuartbond/backintime-responsiveness-20261113`, branch `repair/responsiveness-20261113`, baseline commit `25296e1`. Responsiveness source commit `e90fcc7` is pushed to origin; validation is still in progress. Root owns integration, validation, packaging and journal.
- Original recovery `/Users/stuartbond/backintime-live-context` was left unchanged. Its dirty source was copied and frozen before repair. Installed bundle manifest matches 753/763 inputs; other differences are nine approved lazy-scroll UI files and removed manual-page view. Governor/audio/Timeline originals match installed 2610.22.5 exactly.
- Storage candidate: `/Users/stuartbond/backintime-storage-20261113`, branch `repair/storage-20261113`, baseline `4b5062b`. Storage source commit `ef3eeb2` implements optional AAC padding compaction and tests, default off. Full tests remain pending; do not enable V32. This is separate from the narrow installed-family repair.
- Running `/Applications/Retrace.app` remains 2610.22.5; PID13811 at last check. Signing identity exists and installed app team is CC88WZ5SQ7. Do not use existing `build_and_sign.sh`: it automatically kills/replaces the installed app, contrary to the staged restart plan.

## Written implementation

- Audio priority no longer expires into idle-only work. Three recent turns alternate with oldest pending work. Old/quiet first passes are single-threaded and paced to one per30s during activity; quiet catch-up reuses a20s native grant. New speech cancels/joins both waiting and running overdue work. Raw pending recordings survive cancellation.
- Committed text emits coalesced Live refresh notifications before optional companion work. Root also added notifications after pass2/pass3 durable replacements.
- Timeline normal open/Now requests saved current head, rejects stale async results after browsing/deeplinks, refreshes after wake/visible polling only at Now, and no longer captures another screenshot/OCR on ordinary open.
- Default-off native microphone draft trial uses existing sample-timed PCM, bounded partial replacement, clear fallback and joined teardown. CPU Whisper still owns canonical text. System-audio streaming remains outstanding; no identity is fabricated.
- Bounded queue summaries (indexed LIMIT1001 per lane, cached30s) show lower-bound counts, oldest pending time and observation time in Live and operations. Unknown stays unknown. Root added optional audioPreparation to operations snapshots.
- HEVC inventory availability/requested selection/actual-use-unverified reporting ported from main with real encode/decode tests. Production selection remains automatic.
- `scripts/validate_noninteractive.py` strips all inherited RETRACE flags, disables live file logging, limits jobs2 with nice15, and preserves20GiB headroom. `debug --native-draft` explicitly runs silent real authoredPCM speech test. UI native settings/AppKit observer refuse noninteractive profile. Python environment-isolation test passed.

## Validation state and active command

- One advisory code review completed. Its high issue (running overdue inference blocks new speech) was fixed by audio worker with a held-exit regression. Earlier cooldown wait issue also fixed. Do not restart review loops.
- Initial exploratory debug build FAILED because Timeline source changed during compilation, not a type error. Preserve `/tmp/retrace-repair-debug.log`.
- All Swift repair source frozen before clean debug build. `docs/repair-20261113-code-freeze.json` records688 code inputs. Do not edit code during build.
- Active exec session50125 runs the clean focused suite, log `/tmp/retrace-repair-clean-debug.log`:
  `python3 scripts/validate_noninteractive.py debug --filter 'AutomaticAudioSelectionTests|AudioProcessingFreshnessTests|BackgroundProcessingGovernorTests|ResourceProcessingPolicyTests|TimelineOriginalFrameTests|TimelineEvidenceSelectionTests|TimelineBackgroundRefreshPolicyTests|LiveTranscriptionControllerTests|LiveContextWorkspaceTests|HEVCEncoderTests|StorageUsage|RetraceOperationsTests'`
- Scratch `.build-validation/debug` was cleaned immediately before launch. Fresh optimised build must use `.build-validation/release` through runner, separately, after debug passes. Native speech test has not run. It uses tracked authored.wav hash271a49fc…, en-AU installed assets only, no recording/playback/download/UI. Firstdraft<=5s and critical negation phrase gate must pass; unavailable assets are a skip, never acceptance.
- Disk free49GiB after initial build; preserve20GiB. No library copy was made. Source frozen~30MB.

## Remaining

Finish debug, fix actual failures, retain receipts. Run native speech and separate optimised build, appropriate broader isolated regressions. Package a signed candidate with source/build manifests and app-only rollback; do not install/unannounced-restart before concrete reviewable candidate. No installed acceptance or measured CPU/energy claim yet. Update journal/changelog, commit and push branch after validation.

Full plan still includes native two-source streaming/canonical integration, representative accuracy/latency/energy, native original retention then OCR/archive release, unchanged-frame reuse with occurrence navigation, exact non-overlap audio storage gate. Main contains uninstalled V24–V32 candidates and must not replace V23 as a shortcut.

## Sources and security

Repair journal: `/Users/stuartbond/backintime-responsiveness-20261113/docs/repair-20261113-journal.md`. Source/installed comparison manifests beside it. Baseline scan found four exact copies of the previously classified public upstream Rewind compatibility constant, plus six tokenizer hashes; no new credential. Values never printed. Frozen baseline preserves one pre-existing EOF whitespace issue. Vendor external header links were materialised locally; repaired source is independent of those external links.

Memory used: MEMORY.md1260–1263 and1278–1281; final reply needs the required memory citation block. Rollouts01a15dce-680d-71f1-aaac-9f03713f0a29 and01a08fec-d782-7cd3-9801-2de32d112239. Do not update memory without user request.

## Storage follow-up checkpoint

- Agent storage implementation/review finished. Review high issue (staging failure orphaning valid saved audio) was fixed by full original-or-candidate readback fallback. No further review loop required.
- Independent root smoke compiled the production compactor silently against a retained authored M4A: 60,047 to37,086bytes (38.238%), native AVAudioFile all171,707 PCM samples bit-identical. FFmpeg independent decode also identical before/after (343,936bytes, includes its own padding convention). Receipt `docs/aac-padding-smoke-20261113.json` in storage worktree. Not fullpromotion.
- Native source/tests toport into V23repair: Storage/Audio/AACContainerCompactor.swift, AudioSegmentWriter smallinit/optionalcall diff, Storage/Tests/AACContainerCompactorTests.swift, and retained `docs/fixtures/responsiveness/2026-09-28/authored-codec-output/existing-quality-based.m4a` fixture. Keep optiondisabled until fullnative tests and savingsgates pass. No schema change needed.
- Clean primary build now compiled app and is compiling RetraceTests; still no executable testresult yet at4:43AEST. Do notedit source until it finishes.
