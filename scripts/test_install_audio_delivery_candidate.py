"""Private-filesystem tests for installer failure reporting; no app/library access."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import plistlib
import re
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name('install-audio-delivery-candidate-20261113.py')
BASE = '/Users/stuartbond/Library/Application Support/Retrace Candidates/2026-11-13-audio-delivery'
LIVE = '/Users/stuartbond/Library/Application Support/Retrace'


def digest(data):
    return hashlib.sha256(data).hexdigest()


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='retrace-installer-test-')
        self.root = Path(self.temp.name)
        self.base = self.root / 'candidate'
        self.base.mkdir(mode=0o700)
        self.live = self.root / 'library'
        self.live.mkdir()
        (self.live / 'retrace.db').write_bytes(b'private fixture, not a database')
        self.apps = self.root / 'apps'
        self.apps.mkdir()
        self.installed = self.apps / 'Retrace.app'
        self.candidate = self.base / 'Retrace 2611.13.2 candidate.app'
        self.old = b'old fixture executable'
        self.new = b'new fixture executable'
        for path, build, binary in [(self.installed, '2610.22.5', self.old), (self.candidate, '2611.13.2', self.new)]:
            (path / 'Contents/MacOS').mkdir(parents=True)
            (path / 'Contents/Resources').mkdir()
            (path / 'Contents/MacOS/Retrace').write_bytes(binary)
            (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier':'io.retrace.app', 'CFBundleShortVersionString':'0.7.6',
                'CFBundleVersion':build, 'RetraceSourceCommit':'e90fcc7',
                'RetraceBuildGitRevision':'e90fcc7', 'RetraceSourceManifestSHA256':digest(b'{}')}))
        resources = self.candidate / 'Contents/Resources'
        for name in ['SourceManifest.json', 'ValidationReceipt.json']:
            (resources / name).write_bytes(b'{}')
        receipt = {'testedSourceCommit':'e90fcc7', 'verifiedBuildBinarySHA256':'build-fixture',
            'packagedExecutableSHA256':digest(self.new), 'validationReceiptSHA256':digest(b'{}'),
            'codeInputManifestSHA256':digest(b'{}')}
        accepted = {'sourceCommit':'e90fcc7', 'releaseExecutableSHA256':'build-fixture',
            'installedBaseBuild':'2610.22.5', 'schemaTransition':'none; remains V23', 'storageFormatTransition':'none'}
        (self.base / 'candidate-2611.13.2.json').write_text(json.dumps(receipt))
        (self.base / 'app-only-compatibility.json').write_text(json.dumps(accepted))
        helper = self.base / 'Recovery helper'
        helper.mkdir()
        (helper / 'clone_native_library.py').write_text('''import contextlib,os
@contextlib.contextmanager
def absolute_directory(path):
    fd=os.open(path,os.O_RDONLY)
    try: yield fd
    finally: os.close(fd)
def assert_no_writers(path): pass
''')
        text = SCRIPT.read_text().replace(BASE, str(self.base)).replace(LIVE, str(self.live))
        text = text.replace('/Applications/', str(self.apps) + '/')
        text = re.sub(r"OLD_HASH = '[a-f0-9]+'", "OLD_HASH = '" + digest(self.old) + "'", text)
        self.script = self.root / 'installer.py'
        self.script.write_text(text)

    def tearDown(self):
        self.temp.cleanup()

    def invoke(self, mode, fail_after_swap=False):
        stdout, stderr = io.StringIO(), io.StringIO()
        def run(command, **kwargs):
            if command[0] == '/usr/bin/codesign':
                if fail_after_swap and command[1] == '--verify' and command[-1] == str(self.installed):
                    if (self.installed / 'Contents/MacOS/Retrace').read_bytes() == self.new:
                        raise subprocess.CalledProcessError(1, ['fixture-verification'])
                details = 'TeamIdentifier=CC88WZ5SQ7\nAuthority=Developer ID Application: SIMPLE CLICK PTY LTD (CC88WZ5SQ7)\n'
                return subprocess.CompletedProcess(command, 0, '', details)
            if command[0] == '/usr/bin/ditto':
                shutil.copytree(command[1], command[2], dirs_exist_ok=True)
                return subprocess.CompletedProcess(command, 0)
            raise AssertionError('Unexpected process: ' + command[0])
        with patch.object(sys, 'argv', [str(self.script), mode]), patch('subprocess.run', side_effect=run), \
             patch('subprocess.check_output', return_value=plistlib.dumps({})), \
             patch.object(sys, 'dont_write_bytecode', False), \
             contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            try:
                runpy.run_path(str(self.script), run_name='__main__')
            except SystemExit as result:
                code = result.code
            else:
                code = 0
        return code, stdout.getvalue(), stderr.getvalue()

    def test_check_creates_no_cache_or_receipts(self):
        before = sorted(str(p.relative_to(self.root)) for p in self.root.rglob('*'))
        code, output, error = self.invoke('--check')
        self.assertEqual((code, error), (0, ''))
        self.assertTrue(json.loads(output)['packageVerified'])
        self.assertEqual(before, sorted(str(p.relative_to(self.root)) for p in self.root.rglob('*')))
        self.assertEqual((self.installed/'Contents/MacOS/Retrace').read_bytes(), self.old)

    def test_post_swap_verification_failure_reports_exact_state(self):
        before = (self.live/'retrace.db').stat()
        code, _, error = self.invoke('--install', fail_after_swap=True)
        self.assertEqual(code, 1)
        failure = json.loads(error)
        self.assertEqual(failure['stage'], 'verify_after_swap')
        self.assertEqual(failure['installed']['build'], '2611.13.2')
        self.assertEqual(failure['retained']['build'], '2610.22.5')
        self.assertFalse(failure['staged']['present'])
        self.assertFalse(failure['installerWroteLibrary'])
        self.assertEqual(len(list(self.base.glob('installation-failure-*.json'))), 1)
        self.assertFalse((self.base/'installation-complete.json').exists())
        after = (self.live/'retrace.db').stat()
        self.assertEqual((before.st_ino,before.st_size,before.st_mtime_ns), (after.st_ino,after.st_size,after.st_mtime_ns))

    def test_previous_settings_receipt_blocks_before_swap(self):
        retained = self.base/'settings-at-install.json'
        retained.write_text('prior attempt')
        code, _, error = self.invoke('--install')
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(error)['errorType'], 'FileExistsError')
        self.assertEqual(retained.read_text(), 'prior attempt')
        self.assertEqual((self.installed/'Contents/MacOS/Retrace').read_bytes(), self.old)

    def test_check_rejects_inherited_old_source_metadata(self):
        path = self.candidate/'Contents/Info.plist'
        info = plistlib.loads(path.read_bytes())
        info['RetraceSourceManifestSHA256'] = 'old-installed-manifest'
        path.write_bytes(plistlib.dumps(info))
        code, _, error = self.invoke('--check')
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(error)['errorType'], 'RuntimeError')
        self.assertEqual((self.installed/'Contents/MacOS/Retrace').read_bytes(), self.old)


if __name__ == '__main__':
    unittest.main()
