# Explicit audio worker candidate

This processes one immutable, explicitly supplied job on the primary spare Mac.
It is not a daemon, does not scan history, and cannot write the Retrace or Outlook
databases. App-owned job publication, transport, result import and speaker
corrections are still required before this can supply the installed UI.

The worker reuses Outlook's read-only voice library, embedding matcher and WAV
decoder. MLX Whisper and pyannote load only the exact local model snapshots in
`runtime-pins.json`; no model downloads occur. Segmentation and embedding paths
are rewritten into the verified pipeline config so environment cache overrides
cannot select a different model. The request contains no executable model or
configuration paths.

Known names remain suggestions. The library's cosine thresholds are not a
measured 98% naming-precision calibration. Unnamed matches stay anonymous, and
words crossing multiple voices remain explicitly overlapping. First-pass text
must remain available independently of this worker.

## Contract

- Request filename: SHA-256 of exact JSON bytes plus `.job.json`.
- Media: SHA-256-named AAC objects, each bounded to 16 MiB and verified before
  decoding a private byte snapshot. One source per job, 16 kHz mono, at most
  120 seconds. Ordered sample ranges must agree with their original identity
  and chronology; gaps require a different job.
- Result: job/store/generation/source/time/sample identity, full transcript,
  timed speaker segments, unplaced-word count, model pins and process metrics.
  A process lock prevents concurrent workers for the same output directory.
  Atomic publication never overwrites a different result. Retries validate an
  existing result rather than trusting the presence of a filename.
- Decoder/model errors leave the request pending. A parent service must own
  timeouts, cancellation, backoff, transport acknowledgement and disk limits.
  Those lifecycle pieces are not implied by this one-job CLI.

## Run explicitly on the primary host

Use the verified Outlook environment; the pinned package versions intentionally
reject another interpreter. Place private jobs/media/results in a 0700 directory.

```sh
PYTHONPATH=scripts /Users/stuartbond/outlook/.venv/bin/python -m audio_worker \
  --request /private/jobs/<sha256>.job.json \
  --media /private/media --results /private/results
```

The primary-host role check and package/source/model checks precede inference.
The CLI emits a JSON status. Native libraries may emit diagnostics to stderr.
Results and logs can contain private text and suggested names; keep them local.

## Verification

```sh
PYTHONPATH=scripts /Users/stuartbond/outlook/.venv/bin/python \
  -m unittest discover -s scripts/audio_worker/tests -v
ruff check scripts/audio_worker
ruff format --check scripts/audio_worker
```

Boundary tests require PyYAML and a real `ffmpeg` executable. They do not open
enrollment stores or load models. Native authored-AAC acceptance is separate in
`docs/recovery-20261019.md`; it does not establish human speaker accuracy,
continuous-worker memory, whole-system energy or installed integration.
