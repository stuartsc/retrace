from pathlib import Path
import gzip
import hashlib
import json
import plistlib
import shutil
import subprocess

source = Path('/Users/stuartbond/backintime-responsiveness-20261113')
build = source / '.build-validation/release/arm64-apple-macosx/release'
base = Path.home() / 'Library/Application Support/Retrace Candidates/2026-11-13-responsiveness'
previous = Path('/Applications/Retrace.app')
candidate = base / 'Retrace 2611.13.1 candidate.app'
identity = 'Developer ID Application: SIMPLE CLICK PTY LTD (CC88WZ5SQ7)'

def run(*args):
    return subprocess.check_output(list(args), text=True, stderr=subprocess.STDOUT)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def no_links(path):
    for part in (path, *path.parents):
        require(not part.is_symlink(), 'Unexpected symbolic link: ' + str(part))

def destination(path):
    no_links(path)
    require(path.resolve().is_relative_to(candidate.resolve()), 'Outside candidate: ' + str(path))
    return path

validation_path = source / 'docs/fixtures/repair-20261113/validation.json'
validation = json.loads(validation_path.read_text())
freeze_path = source / 'docs/repair-20261113-code-freeze.json'
freeze = json.loads(freeze_path.read_text())
for name, want in freeze.items():
    file = source / name
    require(file.resolve().is_relative_to(source.resolve()), 'Outside source: ' + name)
    no_links(file)
    require(digest(file) == want, 'Code input changed: ' + name)
require(validation['optimizedBuild']['passed'], 'Optimised build not passed')
require(validation['full'] == {'executed': 1719, 'skipped': 23, 'failures': 0}, 'Unexpected test receipt')
log_path = source / 'docs/fixtures/repair-20261113/full-debug.log.gz'
# Retain the exact test evidence, not an inference from the current source revision.
if not log_path.exists():
    log_path = Path('/tmp/retrace-repair-full-debug.log')
    log_bytes = log_path.read_bytes()
else:
    log_bytes = gzip.decompress(log_path.read_bytes())
require(hashlib.sha256(log_bytes).hexdigest() == validation['logs']['full-debug']['sha256'], 'Test log changed')
no_links(build / 'Retrace')
raw = digest(build / 'Retrace')
require(raw == validation['optimizedBuild']['binarySHA256'], 'Binary differs from verified optimised build')
require(shutil.disk_usage(source).free > 20 * 1024**3, 'Insufficient free disk space')
no_links(base)
base.mkdir(mode=0o700, parents=True, exist_ok=True)
require(not base.stat().st_mode & 0o077, 'Expected private candidate directory')
require(not candidate.exists() and not candidate.is_symlink(), 'Candidate already exists')
run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(previous))
protected = {name: digest(previous / name) for name in ('Contents/MacOS/Retrace', 'Contents/Info.plist')}
run('/usr/bin/ditto', str(previous), str(candidate))
exe = destination(candidate / 'Contents/MacOS/Retrace')
resources = destination(candidate / 'Contents/Resources')
dest = destination(resources / 'Retrace_Retrace.bundle')
info = destination(candidate / 'Contents/Info.plist')
outputs = [destination(resources / name) for name in ('SourceManifest.json', 'ReleaseBuildReceipt.json', 'BuildProvenance.json', 'ValidationReceipt.json')]
shutil.copy2(build / 'Retrace', exe)
require(digest(exe) == raw, 'Candidate copy does not match verified binary')
shutil.rmtree(dest)
run('/usr/bin/ditto', str(build / 'Retrace_Retrace.bundle'), str(dest))
revision = run('/usr/bin/git', '-C', str(source), 'rev-parse', 'HEAD').strip()
fields = plistlib.loads(info.read_bytes())
fields.update(CFBundleVersion='2611.13.1', RetraceSourceCommit=validation['sourceCommit'],
    CFBundleGetInfoString='Retrace 0.7.6 (2611.13.1) Responsiveness repair local trial',
    RetraceLocalBuild='2026-11-13 current Timeline and bounded audio preparation; native microphone draft trial off')
info.write_bytes(plistlib.dumps(fields))
run('/usr/bin/install_name_tool', '-add_rpath', '@executable_path/../Frameworks',
    '-delete_rpath', str(source / 'Vendors/whisper/lib'),
    '-delete_rpath', '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx', str(exe))
manifest = {'kind': 'code-input-manifest', 'inputCount': len(freeze), 'files': freeze,
    'excludes': ['Package.swift', 'Package.resolved', 'UI/Retrace.entitlements'],
    'note': 'Code inputs verified against retained freeze at packaging; see ValidationReceipt for build and test evidence.'}
outputs[0].write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
packaging_inputs = {name: digest(source / name) for name in ('Package.swift', 'Package.resolved', 'UI/Retrace.entitlements')}
receipt = {'schemaVersion': 2, 'configuration': 'release', 'sourceRoot': str(source),
    'testedSourceCommit': validation['sourceCommit'], 'packagingSourceRevision': revision,
    'codeInputManifestSHA256': digest(outputs[0]), 'verifiedBuildBinarySHA256': raw,
    'validationReceiptSHA256': digest(validation_path), 'validationReceipt': 'ValidationReceipt.json',
    'packagingCodeInputCheck': 'matched all frozen inputs', 'packagingInputHashes': packaging_inputs,
    'nativeSpeechLatencyAccepted': False, 'nativeSpeechMissingAssets': True, 'installed': False}
outputs[1].write_text(json.dumps(receipt, indent=2) + '\n')
outputs[2].write_text(json.dumps({'build': '2611.13.1', 'testedSourceCommit': validation['sourceCommit'],
    'packagingSourceRevision': revision, 'codeInputManifestSHA256': receipt['codeInputManifestSHA256'],
    'verifiedBuildBinarySHA256': raw, 'scope': 'signed local trial candidate; not installed or performance accepted'}, indent=2) + '\n')
shutil.copy2(validation_path, outputs[3])
run('/usr/bin/codesign', '--force', '--sign', identity, '--timestamp', '--options', 'runtime',
    '--entitlements', str(source / 'UI/Retrace.entitlements'), str(candidate))
run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(candidate))
require(digest(build / 'Retrace') == raw, 'Build binary changed during packaging')
for name, before in protected.items():
    require(digest(previous / name) == before, 'Installed app changed during packaging')
receipt.update(candidate=str(candidate), packagedExecutableSHA256=digest(exe), signatureVerified=True,
    installedExecutableAndPlistUnchanged=True)
no_links(base / 'candidate-2611.13.1.json')
(base / 'candidate-2611.13.1.json').write_text(json.dumps(receipt, indent=2) + '\n')
# Keep the reviewed app-only installer self-contained in the candidate directory.
helper_dir = base / 'Recovery helper'
no_links(helper_dir)
helper_dir.mkdir(mode=0o700, exist_ok=True)
for original, installed_name in (
    (source / 'scripts/recovery/clone_native_library.py', helper_dir / 'clone_native_library.py'),
    (source / 'scripts/install-responsiveness-candidate-20261113.py', base / 'install_app_only.py'),
    (source / 'docs/fixtures/repair-20261113/app-only-compatibility.json', base / 'app-only-compatibility.json'),
):
    no_links(original)
    no_links(installed_name)
    require(not installed_name.exists(), 'Refuse to overwrite installer material: ' + str(installed_name))
    shutil.copy2(original, installed_name)
    require(digest(installed_name) == digest(original), 'Installer material copy changed')
print(json.dumps({'candidate': str(candidate), 'signatureVerified': True, 'installed': False}))
