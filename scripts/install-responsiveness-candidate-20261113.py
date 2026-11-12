"""Verified application-only swap after normal Quit; current library and prior backups stay in place."""
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import time
import sys

sys.dont_write_bytecode = True

if sys.argv[1:] not in (["--check"], ["--install"]):
    raise SystemExit("Use --check for read-only package validation or --install after normal Quit.")

BASE = Path('/Users/stuartbond/Library/Application Support/Retrace Candidates/2026-11-13-responsiveness')
LIVE = Path('/Users/stuartbond/Library/Application Support/Retrace')
INSTALLED = Path('/Applications/Retrace.app')
CANDIDATE = BASE / 'Retrace 2611.13.1 candidate.app'
STAGED = Path('/Applications/.Retrace-2611.13.1-installing.app')
RETAINED = BASE / 'Installed 2610.22.5 before recovery repair.app'
OLD_HASH = '4ceb173a8c956ae21951a545ec2e95a8bac879c290ce2579dfa8f188ff878d6d'
HELPER = Path('/Users/stuartbond/Library/Application Support/Retrace Candidates/2026-11-13-responsiveness/Recovery helper/clone_native_library.py')
CRITICAL = ('retrace.db', 'retrace.db-wal', 'retrace.db-journal')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(name, value):
    with (BASE / name).open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())


def identity(path):
    st = path.lstat()
    return [st.st_dev, st.st_ino]


def file_state(path):
    st = path.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
        raise RuntimeError('Unexpected database file type or links')
    return [st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns, st.st_uid, st.st_gid, stat.S_IMODE(st.st_mode)]


def verify_bundle(path, build, expected):
    with guard.absolute_directory(path):
        pass
    with guard.absolute_directory(path / 'Contents/MacOS'):
        pass
    executable = path / 'Contents/MacOS/Retrace'
    if executable.is_symlink() or digest(executable) != expected:
        raise RuntimeError('Bundle executable identity changed')
    fields = plistlib.loads((path / 'Contents/Info.plist').read_bytes())
    if (fields['CFBundleIdentifier'], fields['CFBundleShortVersionString'], fields['CFBundleVersion']) != ('io.retrace.app', '0.7.6', build):
        raise RuntimeError('Unexpected bundle version')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(path)], check=True, timeout=30)
    details = subprocess.run(['/usr/bin/codesign', '-dvv', str(path)], check=True,
        capture_output=True, text=True, timeout=15).stderr.splitlines()
    if ('TeamIdentifier=CC88WZ5SQ7' not in details or
            'Authority=Developer ID Application: SIMPLE CLICK PTY LTD (CC88WZ5SQ7)' not in details):
        raise RuntimeError('Unexpected signing identity')
    if build == '2611.13.1':
        if fields.get('RetraceSourceCommit') != accepted['sourceCommit']:
            raise RuntimeError('Candidate source differs from accepted release')
        resources = path / 'Contents/Resources'
        if digest(resources / 'ValidationReceipt.json') != candidate['validationReceiptSHA256']:
            raise RuntimeError('Candidate validation receipt differs')
        if digest(resources / 'SourceManifest.json') != candidate['codeInputManifestSHA256']:
            raise RuntimeError('Candidate code-input manifest differs')
    return identity(path), identity(executable)


def rename_exclusive(source, destination):
    library = ctypes.CDLL(None, use_errno=True)
    rename = library.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 4) != 0:
        raise OSError(ctypes.get_errno(), 'Exclusive rename failed')


def observed_bundle(path):
    # Diagnose only known bundle paths. Never follow an unexpected link.
    if not os.path.lexists(path):
        return {"present": False}
    result = {"present": True, "identity": identity(path)}
    try:
        with guard.absolute_directory(path / 'Contents/MacOS'):
            pass
        with guard.absolute_directory(path / 'Contents'):
            pass
        exe = path / 'Contents/MacOS/Retrace'
        info = path / 'Contents/Info.plist'
        if exe.is_symlink() or info.is_symlink():
            raise RuntimeError('Unexpected bundle file link')
        result.update(build=plistlib.loads(info.read_bytes()).get('CFBundleVersion'), executableSHA256=digest(exe))
    except Exception as error:
        result['inspectionError'] = type(error).__name__
    return result


stage = 'initialise'
base_verified = False
try:
    os.umask(0o077)
    spec = importlib.util.spec_from_file_location('snapshot_guard', HELPER)
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)
    with guard.absolute_directory(BASE) as fd:
        st = os.fstat(fd)
        if st.st_uid != os.geteuid() or stat.S_IMODE(st.st_mode) != 0o700:
            raise RuntimeError('Recovery directory is not private')
    base_verified = True
    with guard.absolute_directory(LIVE):
        pass
    if BASE.stat().st_dev != INSTALLED.parent.stat().st_dev:
        raise RuntimeError('Bundle swap requires the same filesystem')
    for path in (STAGED, RETAINED, BASE / 'settings-at-install.json', BASE / 'installation-attempt.json', BASE / 'installation-complete.json'):
        if os.path.lexists(path):
            raise FileExistsError('Refuse to overwrite installation or rollback evidence')
    candidate = json.loads((BASE / 'candidate-2611.13.1.json').read_text())
    accepted = json.loads((BASE / 'app-only-compatibility.json').read_text())
    if (candidate['testedSourceCommit'] != accepted['sourceCommit'] or
            candidate['verifiedBuildBinarySHA256'] != accepted['releaseExecutableSHA256'] or
            accepted.get('installedBaseBuild') != '2610.22.5' or
            accepted.get('schemaTransition') != 'none; remains V23' or
            accepted.get('storageFormatTransition') != 'none'):
        raise RuntimeError('Release is not accepted for application-only rollback')
    new_hash = candidate['packagedExecutableSHA256']
    if sys.argv[1:] == ['--check']:
        verify_bundle(INSTALLED, '2610.22.5', OLD_HASH)
        verify_bundle(CANDIDATE, '2611.13.1', new_hash)
        print(json.dumps({'packageVerified': True, 'installed': False, 'requiresNormalQuit': True}))
        raise SystemExit(0)
    stage = 'quiescence'
    guard.assert_no_writers(LIVE)
    old_identity = verify_bundle(INSTALLED, '2610.22.5', OLD_HASH)
    verify_bundle(CANDIDATE, '2611.13.1', new_hash)
    preferences = plistlib.loads(subprocess.check_output(['/usr/bin/defaults', 'export', 'io.retrace.app', '-'], timeout=5))
    configured_root = Path(preferences.get('customRetraceDBLocation', str(LIVE))).expanduser()
    if configured_root != LIVE:
        raise RuntimeError('Configured library root changed')
    settings = {key: value for key, value in preferences.items() if key in ('shouldAutoStartRecording', 'activityContextEnabled', 'excludedApps', 'customRetraceDBLocation')}
    stage = 'retain_settings'
    save('settings-at-install.json', settings)
    # This scheduling/UI repair has no schema or media-format migrations. Observe metadata only; do not open
    # or copy the database. Roll back only the application against the current library.
    before = {name: file_state(LIVE / name) for name in CRITICAL if (LIVE / name).exists()}
    if 'retrace.db' not in before:
        raise RuntimeError('Canonical database is absent')
    stage = 'record_attempt'
    save('installation-attempt.json', {'startedAtMs': int(time.time() * 1000), 'oldHash': OLD_HASH,
        'newHash': new_hash, 'schemaTransition': 'none; remains V23', 'databaseBefore': before,
        'installerWritesLibrary': False, 'rollbackApp': str(RETAINED), 'databaseBackupCreated': False, 'rollbackUsesCurrentLibrary': True, 'sourceCommit': accepted['sourceCommit']})
    stage = 'stage_candidate'
    STAGED.mkdir(mode=0o700)
    stage_identity = identity(STAGED)
    subprocess.run(['/usr/bin/ditto', str(CANDIDATE), str(STAGED)], check=True, timeout=60)
    verified_stage = verify_bundle(STAGED, '2611.13.1', new_hash)
    if verified_stage[0] != stage_identity:
        raise RuntimeError('Owned staging directory changed')
    guard.assert_no_writers(LIVE)
    if before != {name: file_state(LIVE / name) for name in CRITICAL if (LIVE / name).exists()}:
        raise RuntimeError('Database changed before install')
    if verify_bundle(INSTALLED, '2610.22.5', OLD_HASH) != old_identity:
        raise RuntimeError('Installed app changed before swap')
    stage = 'retain_old_app'
    rename_exclusive(INSTALLED, RETAINED)
    moved_identity = identity(RETAINED)
    try:
        # An older installer does not share a lock with this one. Verify the bundle
        # actually moved before replacing it, not just the path checked beforehand.
        if verify_bundle(RETAINED, '2610.22.5', OLD_HASH) != old_identity:
            raise RuntimeError('Installed app changed during the exclusive move')
        stage = 'activate_candidate'
        rename_exclusive(STAGED, INSTALLED)
    except BaseException:
        # Return exactly what this attempt moved, including an unexpected new app.
        # Never replace an app another process has placed at the destination.
        if (not os.path.lexists(INSTALLED) and os.path.lexists(RETAINED)
                and identity(RETAINED) == moved_identity):
            rename_exclusive(RETAINED, INSTALLED)
        raise
    stage = 'verify_after_swap'
    if verify_bundle(INSTALLED, '2611.13.1', new_hash) != verified_stage:
        raise RuntimeError('Installed candidate identity differs')
    if verify_bundle(RETAINED, '2610.22.5', OLD_HASH) != old_identity:
        raise RuntimeError('Rollback app identity differs')
    if before != {name: file_state(LIVE / name) for name in CRITICAL if (LIVE / name).exists()}:
        raise RuntimeError('Database changed during bundle swap')
    result = {'outcome': 'passed', 'completedAtMs': int(time.time() * 1000), 'build': '2611.13.1',
        'newExecutableSHA256': new_hash, 'oldExecutableSHA256': OLD_HASH, 'rollbackApp': str(RETAINED),
        'databaseBackupCreated': False, 'databaseMetadataUnchanged': before,
        'rollbackUsesCurrentLibrary': True, 'sourceCommit': accepted['sourceCommit'], 'installerWroteLibrary': False, 'launched': False}
    stage = 'record_completion'
    save('installation-complete.json', result)
    print(json.dumps(result), flush=True)
except Exception as error:
    failure = {'outcome': 'incomplete', 'stage': stage, 'errorType': type(error).__name__,
        'reason': getattr(error, 'code', None), 'installerWroteLibrary': False,
        'installed': observed_bundle(INSTALLED), 'retained': observed_bundle(RETAINED),
        'staged': observed_bundle(STAGED),
        'recovery': 'Keep Retrace closed. Inspect these bundle identities before retrying. The old app and current library must be preserved; do not delete installation receipts or staging material.'}
    if sys.argv[1:] == ['--install'] and base_verified:
        try:
            save('installation-failure-' + str(time.time_ns()) + '.json', failure)
        except Exception as receipt_error:
            failure['receiptError'] = type(receipt_error).__name__
    print(json.dumps(failure), file=sys.stderr, flush=True)
    raise SystemExit(1) from None
