#!/usr/bin/env python3
"""Clean whole-app release with full local input freeze and owned process groups."""
import gzip
import importlib.util
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[3]
PRIVATE = ROOT / '.audio-integration-validation'
ARTIFACTS = Path(__file__).resolve().parent
PRODUCTION_ROOTS = ('Shared', 'Database', 'Storage', 'Capture', 'Processing',
                    'Search', 'Migration', 'App', 'UI', 'Sources', 'Vendors')
EXPLICIT_INPUTS = ('Package.swift', 'Package.resolved',
                   'scripts/validate_noninteractive.py',
                   'scripts/create-release.sh', 'scripts/release.sh',
                   'docs/fixtures/repair-20261113-audio-integration-harness/release.py')


def main():
    spec = importlib.util.spec_from_file_location('audio_validation', PRIVATE / 'run.py')
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)

    def full_inputs():
        paths = {ROOT / name for name in EXPLICIT_INPUTS}
        for folder in PRODUCTION_ROOTS:
            paths.update(path for path in (ROOT / folder).rglob('*')
                         if path.is_file() or path.is_symlink())
        result = []
        for path in sorted(paths):
            relative = path.relative_to(ROOT).as_posix()
            if path.is_symlink() and not path.is_file():
                raise RuntimeError('Non-file symlink in input inventory: ' + relative)
            result.append({'path': relative, 'bytes': path.stat().st_size,
                           'sha256': runner.sha256(path),
                           'symlinkTarget': os.readlink(path) if path.is_symlink() else None})
        return result

    before_harness = runner.verify()
    before = full_inputs()
    if shutil.disk_usage(ROOT).free < 20 * 1024**3:
        raise RuntimeError('Less than 20 GiB free; preserve recording headroom')
    source_commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    when = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    snapshot_path = ARTIFACTS / ('release-inputs-' + when + '.json')
    with snapshot_path.open('x') as target:
        json.dump({'sourceCommit': source_commit, 'roots': PRODUCTION_ROOTS,
                   'explicitInputs': EXPLICIT_INPUTS, 'files': before}, target, indent=2)
        target.write('\n')

    def postcheck():
        after_harness = runner.verify()
        after = full_inputs()
        if before != after:
            raise RuntimeError('Whole-app code/resource/native/input inventory changed during release')
        binary = ROOT / '.build-validation/release/arm64-apple-macosx/release/Retrace'
        result = {'wholeAppInputsMatched': len(after), 'harnessInputs': after_harness,
                  'inputSnapshotSHA256': runner.sha256(snapshot_path)}
        if binary.is_file():
            result.update(binary=str(binary), binarySHA256=runner.sha256(binary),
                          binaryBytes=binary.stat().st_size)
        return result

    environment = runpy.run_path(str(ROOT / 'scripts/validate_noninteractive.py'))['validation_environment'](os.environ)
    commands = [
        ['/usr/bin/nice', '-n', '15', '/usr/bin/swift', 'package', '--scratch-path',
         str(ROOT / '.build-validation/release'), 'clean'],
        [sys.executable, str(ROOT / 'scripts/validate_noninteractive.py'), 'release'],
    ]
    receipt_path = ARTIFACTS / ('release-validation-' + when + '.json')
    log_path = Path('/tmp') / ('retrace-audio-delivery-release-' + when + '.log')
    metadata = {
        'sourceCommit': source_commit, 'wholeAppOptimizedBuild': True,
        'before': {'wholeAppInputs': len(before), 'harnessInputs': before_harness,
                   'inputSnapshot': snapshot_path.name, 'inputSnapshotSHA256': runner.sha256(snapshot_path)},
        'nativeMicrophoneDraftDefaultEnabled': False,
        'nativeFirstPassReuseDefaultEnabled': False,
        'actualNativeModelInference': False,
        'runtimeSpeechAssets': 'en-AU unavailable according to root check; not rechecked or downloaded here',
        'installed': False,
    }
    receipt = runner.execute_commands(commands, ROOT, environment, log_path, receipt_path,
                                      metadata=metadata, postcheck=postcheck)
    with (ARTIFACTS / ('release-' + when + '.log.gz')).open('xb') as output:
        with log_path.open('rb') as source:
            with gzip.GzipFile(fileobj=output, mode='wb', mtime=0) as compressed:
                shutil.copyfileobj(source, compressed)
    print(json.dumps(receipt, sort_keys=True))
    return 0 if receipt['completed'] and receipt['after'].get('binarySHA256') else 1


if __name__ == '__main__':
    raise SystemExit(main())
