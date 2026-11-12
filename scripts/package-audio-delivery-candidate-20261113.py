"""Package the verified V23 audio repair without installing or launching it."""
from pathlib import Path
import gzip
import hashlib
import io
import json
import os
import plistlib
import shutil
import subprocess
import tarfile
import tempfile

SOURCE = Path('/Users/stuartbond/backintime-audio-delivery-20261113')
ARTIFACTS = SOURCE / 'docs/fixtures/repair-20261113-audio-integration-harness'
STAMP = '20261112T205343667848Z'
BUILD = SOURCE / '.build-validation/release/arm64-apple-macosx/release'
BASE = Path.home() / 'Library/Application Support/Retrace Candidates/2026-11-13-audio-delivery'
PREVIOUS = Path('/Applications/Retrace.app')
CANDIDATE = BASE / 'Retrace 2611.13.2 candidate.app'
IDENTITY = 'Developer ID Application: SIMPLE CLICK PTY LTD (CC88WZ5SQ7)'
LIBRARIES = ('libwhisper.1.dylib', 'libggml.dylib', 'libggml-base.dylib',
             'libggml-cpu.dylib', 'libggml-blas.dylib', 'libggml-metal.dylib')


def run(*args):
    return subprocess.check_output(list(args), text=True, stderr=subprocess.STDOUT, timeout=90)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def no_links(path):
    for part in (path, *path.parents):
        require(not part.is_symlink(), 'Unexpected symbolic link: ' + str(part))


def destination(path):
    no_links(path)
    require(path.resolve().is_relative_to(CANDIDATE.resolve()), 'Outside candidate: ' + str(path))
    return path


def verify_commands(receipt):
    require(receipt.get('completed') and receipt.get('error') is None
            and receipt.get('interruptedSignal') is None, 'Validation incomplete')
    require(len(receipt['commands']) == 2, 'Unexpected validation commands')
    for command in receipt['commands']:
        require(command['exitCode'] == 0 and command['groupDrained']
                and not command['remainingActivePIDs'] and not command['cleanupErrors'],
                'Validation command did not finish cleanly')


def verify_log(path, receipt):
    with gzip.open(path, 'rb') as stream:
        require(hashlib.file_digest(stream, 'sha256').hexdigest() == receipt['logSHA256'],
                'Validation log changed')


def verify_inputs(snapshot):
    paths = {SOURCE / name for name in snapshot['explicitInputs']}
    for folder in snapshot['roots']:
        paths.update(path for path in (SOURCE / folder).rglob('*')
                     if path.is_file() or path.is_symlink())
    current = []
    for path in sorted(paths):
        no_links(path)
        require(path.resolve().is_relative_to(SOURCE.resolve()), 'Input outside source')
        current.append({'path': path.relative_to(SOURCE).as_posix(),
                        'bytes': path.stat().st_size, 'sha256': digest(path),
                        'symlinkTarget': None})
    require(current == snapshot['files'], 'Frozen whole-app inputs changed')


def verify_focused_inputs(snapshot, focused):
    path = ARTIFACTS / 'source-inputs.json'
    retained = json.loads(path.read_text())
    require(retained['productionCommit'] == focused['productionSourceCommit'], 'Focused source checkpoint changed')
    entries = retained['files']
    require(len(entries) == focused['before']['productionInputsMatched']
            == focused['after']['productionInputsMatched'] == 348, 'Focused inventory count changed')
    # Bind the retained manifest to the actual committed production/test bytes,
    # not merely to an editable result file and the current working tree.
    archived = subprocess.check_output(['/usr/bin/git', '-C', str(SOURCE), 'archive', '--format=tar',
                                       retained['productionCommit'], '--', *[entry['path'] for entry in entries]],
                                      timeout=90)
    release_inputs = {entry['path']: entry['sha256'] for entry in snapshot['files']}
    with tarfile.open(fileobj=io.BytesIO(archived)) as archive:
        for entry in entries:
            name, expected = entry['path'], entry['sha256']
            current = SOURCE / name
            no_links(current)
            require(current.resolve().is_relative_to(SOURCE.resolve()), 'Focused input outside source')
            require(digest(current) == expected, 'Focused input changed: ' + name)
            member = archive.getmember(name)
            require(member.isfile(), 'Focused committed input is not a file')
            with archive.extractfile(member) as stream:
                require(hashlib.file_digest(stream, 'sha256').hexdigest() == expected,
                        'Focused input differs from tested commit: ' + name)
            if name in release_inputs:
                require(release_inputs[name] == expected, 'Focused and release input differ: ' + name)
    return retained, digest(path)


def write_json(path, value):
    no_links(path)
    with path.open('x') as stream:
        json.dump(value, stream, sort_keys=True, indent=2)
        stream.write('\n')


def verify_retained_sparkle():
    framework = SOURCE / '.build-validation/release/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
    installed = PREVIOUS / 'Contents/Frameworks/Sparkle.framework'
    versions = []
    hashes = []
    # Signing changes bytes. Compare disposable arm64 copies after removing only
    # their signatures; never mutate the installed or SwiftPM artifact framework.
    with tempfile.TemporaryDirectory(prefix='retrace-package-sparkle-') as temporary:
        for index, bundle in enumerate((framework, installed)):
            fields = plistlib.loads((bundle / 'Resources/Info.plist').read_bytes())
            versions.append([fields['CFBundleShortVersionString'], fields['CFBundleVersion']])
            target = Path(temporary) / str(index)
            run('/usr/bin/lipo', str(bundle / 'Sparkle'), '-thin', 'arm64', '-output', str(target))
            run('/usr/bin/codesign', '--remove-signature', str(target))
            hashes.append(digest(target))
    require(versions[0] == versions[1] == ['2.8.1', '2050'] and hashes[0] == hashes[1],
            'Retained Sparkle framework differs from build artifact')
    return {'version': versions[0], 'unsignedArm64SHA256': hashes[0], 'matchedBuildArtifact': True}


def main():
    os.umask(0o077)
    release_path = ARTIFACTS / ('release-validation-' + STAMP + '.json')
    release = json.loads(release_path.read_text())
    focused_path = ARTIFACTS / 'focused-validation.json'
    focused = json.loads(focused_path.read_text())
    focused_result = json.loads((ARTIFACTS / 'focused-result.json').read_text())
    snapshot_path = ARTIFACTS / release['before']['inputSnapshot']
    snapshot = json.loads(snapshot_path.read_text())
    verify_commands(release)
    verify_commands(focused)
    verify_log(ARTIFACTS / ('release-' + STAMP + '.log.gz'), release)
    verify_log(ARTIFACTS / 'focused-tests.log.gz', focused)
    require((focused_result['tests'], focused_result['skips'], focused_result['failures']) == (15, 0, 0),
            'Unexpected focused-test result')
    require(focused_result['logSHA256'] == focused['logSHA256'], 'Focused result not bound to log')
    require(release['wholeAppOptimizedBuild'] is True, 'Not a whole-app optimised build')
    require(release['after']['wholeAppInputsMatched'] == len(snapshot['files']) == 751,
            'Incomplete source input freeze')
    require(digest(snapshot_path) == release['before']['inputSnapshotSHA256']
            == release['after']['inputSnapshotSHA256'], 'Source freeze changed')
    require(snapshot['sourceCommit'] == release['sourceCommit'], 'Source checkpoint differs')
    verify_inputs(snapshot)
    _, focused_manifest_hash = verify_focused_inputs(snapshot, focused)
    no_links(BUILD / 'Retrace')
    raw = digest(BUILD / 'Retrace')
    require(raw == release['after']['binarySHA256'], 'Release executable changed')
    helper_dir = BASE / 'Recovery helper'
    installer_material = (
        (SOURCE / 'scripts/recovery/clone_native_library.py', helper_dir / 'clone_native_library.py'),
        (SOURCE / 'scripts/install-audio-delivery-candidate-20261113.py', BASE / 'install_app_only.py'),
        (ARTIFACTS / 'app-only-compatibility.json', BASE / 'app-only-compatibility.json'),
    )
    installer_hashes = {}
    for original, target in installer_material:
        no_links(original)
        no_links(target)
        require(original.is_file(), 'Missing installer input: ' + str(original))
        require(not target.exists(), 'Refuse to overwrite installer material')
        installer_hashes[str(target.relative_to(BASE))] = digest(original)
    compatibility = json.loads(installer_material[-1][0].read_text())
    require(compatibility['sourceCommit'] == release['sourceCommit']
            and compatibility['releaseExecutableSHA256'] == raw
            and compatibility['installedBaseBuild'] == '2610.22.5'
            and compatibility['schemaTransition'] == 'none; remains V23'
            and compatibility['storageFormatTransition'] == 'none', 'Installer compatibility differs')
    no_links(BASE / 'candidate-2611.13.2.json')
    require(not (BASE / 'candidate-2611.13.2.json').exists(), 'Candidate receipt already exists')
    sparkle = verify_retained_sparkle()
    require(shutil.disk_usage(SOURCE).free > 20 * 1024**3, 'Preserve 20 GiB recording headroom')
    no_links(BASE)
    BASE.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(BASE.stat().st_mode & 0o777 == 0o700, 'Expected private candidate directory')
    require(not CANDIDATE.exists() and not CANDIDATE.is_symlink(), 'Candidate already exists')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(PREVIOUS))
    protected = {name: digest(PREVIOUS / name) for name in ('Contents/MacOS/Retrace', 'Contents/Info.plist')}
    require(plistlib.loads((PREVIOUS / 'Contents/Info.plist').read_bytes())['CFBundleVersion'] == '2610.22.5',
            'Installed base changed')
    run('/usr/bin/ditto', str(PREVIOUS), str(CANDIDATE))
    exe = destination(CANDIDATE / 'Contents/MacOS/Retrace')
    resources = destination(CANDIDATE / 'Contents/Resources')
    resource_bundle = destination(resources / 'Retrace_Retrace.bundle')
    info = destination(CANDIDATE / 'Contents/Info.plist')
    shutil.copy2(BUILD / 'Retrace', exe)
    require(digest(exe) == raw, 'Copied executable differs')
    shutil.rmtree(resource_bundle)
    run('/usr/bin/ditto', str(BUILD / 'Retrace_Retrace.bundle'), str(resource_bundle))
    # Use the exact native libraries used by this build, then sign each nested library.
    native_inputs = {}
    for name in LIBRARIES:
        original = SOURCE / 'Vendors/whisper/lib' / name
        no_links(original)
        target = destination(CANDIDATE / 'Contents/lib' / name)
        native_inputs[name] = digest(original)
        shutil.copy2(original, target)
        require(digest(target) == native_inputs[name], 'Native library copy differs')
        run('/usr/bin/codesign', '--force', '--sign', IDENTITY, '--timestamp', '--options', 'runtime', str(target))
    run('/usr/bin/install_name_tool', '-add_rpath', '@executable_path/../Frameworks',
        '-delete_rpath', str(SOURCE / 'Vendors/whisper/lib'),
        '-delete_rpath', '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx', str(exe))
    revision = run('/usr/bin/git', '-C', str(SOURCE), 'rev-parse', 'HEAD').strip()
    fields = plistlib.loads(info.read_bytes())
    fields.update(CFBundleVersion='2611.13.2', RetraceSourceCommit=release['sourceCommit'],
                  CFBundleGetInfoString='Retrace 0.7.6 (2611.13.2) Audio and Timeline repair local trial',
                  RetraceLocalBuild='2026-11-13 current Timeline, bounded audio preparation, lossless AAC padding removal; native speech trials off')
    validation = {'release': release, 'focused': focused, 'focusedResult': focused_result,
                  'scope': '15 clean focused integration tests and separate clean whole-app release; prior native branch full suite is separate evidence',
                  'priorNativeBranch': {'commit': '0ea09c9', 'tests': 1733, 'skips': 24, 'failures': 0},
                  'actualNativeModelInference': False, 'installedAcceptance': False}
    outputs = {name: destination(resources / name) for name in
               ('SourceManifest.json', 'FocusedSourceManifest.json', 'ReleaseBuildReceipt.json', 'BuildProvenance.json', 'ValidationReceipt.json')}
    for path in outputs.values():
        if path.exists():
            path.unlink()
    write_json(outputs['SourceManifest.json'], snapshot)
    fields.update(RetraceBuildGitRevision=release['sourceCommit'],
                  RetraceBuildSourceState='verified-worktree-manifest',
                  RetraceSourceManifestSHA256=digest(outputs['SourceManifest.json']))
    info.write_bytes(plistlib.dumps(fields))
    shutil.copy2(ARTIFACTS / 'source-inputs.json', outputs['FocusedSourceManifest.json'])
    require(digest(outputs['FocusedSourceManifest.json']) == focused_manifest_hash,
            'Focused manifest copy differs')
    write_json(outputs['ValidationReceipt.json'], validation)
    receipt = {'schemaVersion': 3, 'configuration': 'release', 'sourceRoot': str(SOURCE),
               'testedSourceCommit': release['sourceCommit'], 'productionSourceCommit': focused['productionSourceCommit'],
               'packagingSourceRevision': revision, 'codeInputManifestSHA256': digest(outputs['SourceManifest.json']),
               'verifiedBuildBinarySHA256': raw, 'validationReceiptSHA256': digest(outputs['ValidationReceipt.json']),
               'releaseValidationSHA256': digest(release_path), 'focusedValidationSHA256': digest(focused_path),
               'focusedSourceManifestSHA256': focused_manifest_hash, 'focusedInputsMatchedTestedCommit': 348,
               'packagingInputCheck': 'all 751 frozen code, resource, native and build inputs matched',
               'nativeLibraryInputSHA256': native_inputs,
               'retainedSparkleFramework': sparkle,
               'nativeSpeechLatencyAccepted': False, 'nativeSpeechTrialsDefaultEnabled': False,
               'audioPaddingCompactionDefaultEnabled': True, 'existingMediaModified': False,
               'installed': False, 'performanceAccepted': False}
    write_json(outputs['ReleaseBuildReceipt.json'], receipt)
    write_json(outputs['BuildProvenance.json'], {'build': '2611.13.2', **receipt,
               'scope': 'signed local trial candidate; not installed or performance accepted'})
    run('/usr/bin/codesign', '--force', '--sign', IDENTITY, '--timestamp', '--options', 'runtime',
        '--entitlements', str(SOURCE / 'UI/Retrace.entitlements'), str(CANDIDATE))
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(CANDIDATE))
    verify_inputs(snapshot)
    require(digest(BUILD / 'Retrace') == raw, 'Build executable changed during packaging')
    for name, before in protected.items():
        require(digest(PREVIOUS / name) == before, 'Installed app changed during packaging')
    receipt.update(candidate=str(CANDIDATE), packagedExecutableSHA256=digest(exe), signatureVerified=True,
                   installedExecutableAndPlistUnchanged=True)
    no_links(helper_dir)
    helper_dir.mkdir(mode=0o700, exist_ok=True)
    for original, target in installer_material:
        no_links(original)
        no_links(target)
        require(not target.exists(), 'Refuse to overwrite installer material')
        shutil.copy2(original, target)
        require(digest(target) == digest(original) == installer_hashes[str(target.relative_to(BASE))],
                'Installer input or copy changed')
    receipt['installerMaterialSHA256'] = installer_hashes
    write_json(BASE / 'candidate-2611.13.2.json', receipt)
    print(json.dumps({'candidate': str(CANDIDATE), 'signatureVerified': True, 'installed': False}))


if __name__ == '__main__':
    main()
