# Responsiveness repair — 13 November 2026

## State

Implementation in progress on `repair/responsiveness-20261113`, isolated from the running app and both earlier checkouts. Installed app remains 2610.22.5. No installation, live settings changes, history deletion, foreground automation or physical acceptance has occurred.

## Baseline and source recovery

- Recovered the installed bundle's `SourceManifest.json`, `BuildProvenance.json` and clean release receipt. Manifest SHA-256: `e2c8cc509bc783d7ecf86902635ffdefb552360ba61a75b7e34bdb33513f694d`.
- 753 of 763 manifest inputs match the recovery checkout. Nine changed inputs and one removed input belong to the previously requested Live lazy-scroll restoration. Audio, governor and Timeline originals match installed sources. Exact comparison is retained beside this journal.
- Froze 886 source files (about 30 MB); no recorded library was copied. Vendor header links were materialised so this checkout does not depend on external source paths. Dependency resolution matched the recovery checkout's existing `Package.resolved`.
- Baseline checkpoint: `25296e1`. This is reconstructed source, including approved but uninstalled lazy-scrolling changes, rather than a claim that all files reproduce the installed executable.
- Source secret scan: ten findings. Four exactly match the previously classified public Rewind compatibility constant; six are model/tokenizer file hashes in runtime pins. Values were not printed. No new credential was identified. One pre-existing trailing blank line in `AudioBufferSourceRangeTests.swift` was retained in the frozen baseline.

## Findings

- Current screen rows and saved audio files advance. A bounded sample of 1,000 audio rows had no prepared text; most were low-energy pending/silence classifications, so that sample alone does not prove recorded speech was lost.
- First-pass priority expired after 120 seconds. Low-energy rows waited for idle from the outset. The app-only CPU target could prevent fresh transcription while recording itself used the budget.
- Each background row finished a native scheduler grant, despite capture producing around six batches per minute per source. Batches span 15 seconds with five-second overlap; the Live view also slept eight seconds between reads.
- Ordinary cached Timeline opening did not fetch the current database head. Opening also launched another screenshot/OCR path.
- Short CPU readings do not establish matched performance. Existing recording/audio history stays protected.

## Implementation and remaining acceptance

The first candidate repairs durable first-pass scheduling, bounded catch-up, event-driven text updates and Timeline Now. A separately selectable native microphone draft preview uses the existing sample-timed stream without enabling voice rules or the companion. Canonical Whisper text and playback remain independent. Native preview availability and latency must be measured before promotion; system-audio drafts are not implemented in this slice.

HEVC reporting now separates inventory availability, requested preference and unverified actual usage. Automatic encoding remains the default. Existing periodic storage accounting is retained and tested. Native-resolution original retention, changed-screen reuse and unique audio chunk migration remain separate source candidates; previous failing codec/recognition comparisons do not justify enabling them.

Routine checks use `scripts/validate_noninteractive.py`: low-priority two-job builds, private test fixtures, no inherited Retrace opt-ins, disabled live file logging and a 20 GiB free-space preflight. The runner's environment isolation test passed. Native settings and AppKit observation helpers additionally reject the noninteractive profile. No CUA/browser/native-app control is used.

Clean debug validation, independent optimised build, advisory review, measured native speech, staged packaging, installation and installed acceptance are separate pending steps. Failed receipts are retained rather than overwritten. The full accepted plan also requires representative accuracy/energy measurements and original-retention/storage promotion; this first repair is not completion of those gates.

## Validation progress

- Initial exploratory debug build was rejected because Timeline source changed during compilation. This is a build ownership failure, not a successful validation; `/tmp/retrace-repair-debug.log` is retained. Final source was frozen before a clean rebuild.
- One advisory review found overdue inference could still delay fresh speech after acquiring a permit. The owner now cancels and joins the active overdue native token on a fresh speech arrival, retaining its original pending row. Held-exit and three-turn fairness regressions were added.
- Live and operations now expose cached bounded queue counts, oldest pending time and observation time. Truncation is explicit; failed reads retain their last timestamp.
