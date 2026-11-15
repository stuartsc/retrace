import unittest
from unittest.mock import patch
from types import SimpleNamespace
from validate_noninteractive import main, validation_environment


class NoninteractiveValidationTests(unittest.TestCase):
    def test_inherited_interactive_and_live_export_settings_are_removed(self):
        env = validation_environment(
            {
                "PATH": "/usr/bin",
                "DEVELOPER_DIR": "/test/sdk",
                "RETRACE_TEST_NATIVE_SETTINGS": "1",
                "RETRACE_TEST_NATIVE_LIVE_CONTEXT_VISIBLE": "1",
                "RETRACE_TEST_NATIVE_LIVE_CONTEXT_INPUT": "1",
                "RETRACE_OCR_QUALITY_EXPORT": "/live/path",
                "RUN_INTERACTIVE_ACCESSIBILITY_INSPECTOR": "1",
                "AX_VERBOSE": "1",
                "TEST_SCREENSHOT_PATH": "/live/screenshot.png",
                "RETRACE_TEST_DISABLE_FILE_LOGGING": "0",
            }
        )
        self.assertEqual(
            env,
            {
                "PATH": "/usr/bin",
                "DEVELOPER_DIR": "/test/sdk",
                "RETRACE_TEST_DISABLE_FILE_LOGGING": "1",
                "RETRACE_TEST_NONINTERACTIVE": "1",
            },
        )

    def test_native_coverage_requires_explicit_opt_in_and_stays_headless(self):
        for opt_in in (False, True):
            argv = ["validate_noninteractive.py", "debug", "--skip-build"]
            if opt_in:
                argv.append("--native-coverage")
            with (
                patch("sys.argv", argv),
                patch(
                    "shutil.disk_usage",
                    return_value=SimpleNamespace(free=100 * 1024**3),
                ),
                patch("subprocess.call", return_value=0) as run,
                patch.dict(
                    "os.environ",
                    {
                        "RETRACE_NATIVE_FIRST_PASS_COVERAGE_TEST": "1",
                        "RETRACE_TEST_NATIVE_LIVE_CONTEXT_VISIBLE": "1",
                    },
                    clear=True,
                ),
            ):
                self.assertEqual(main(), 0)
            environment = run.call_args.kwargs["env"]
            self.assertNotIn("RETRACE_TEST_NATIVE_LIVE_CONTEXT_VISIBLE", environment)
            self.assertEqual(environment["RETRACE_TEST_NONINTERACTIVE"], "1")
            self.assertEqual(
                environment.get("RETRACE_NATIVE_FIRST_PASS_COVERAGE_TEST"),
                "1" if opt_in else None,
            )
            if opt_in:
                self.assertEqual(
                    run.call_args.args[0][-2:],
                    ["--filter", "LiveTranscriptionNativeTests"],
                )


if __name__ == "__main__":
    unittest.main()
