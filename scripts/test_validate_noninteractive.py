import unittest
from validate_noninteractive import validation_environment


class NoninteractiveValidationTests(unittest.TestCase):
    def test_inherited_interactive_and_live_export_settings_are_removed(self):
        env = validation_environment({
            "PATH": "/usr/bin", "DEVELOPER_DIR": "/test/sdk",
            "RETRACE_TEST_NATIVE_SETTINGS": "1",
            "RETRACE_TEST_NATIVE_LIVE_CONTEXT_VISIBLE": "1",
            "RETRACE_TEST_NATIVE_LIVE_CONTEXT_INPUT": "1",
            "RETRACE_OCR_QUALITY_EXPORT": "/live/path",
            "RETRACE_TEST_DISABLE_FILE_LOGGING": "0",
        })
        self.assertEqual(env, {"PATH": "/usr/bin", "DEVELOPER_DIR": "/test/sdk",
            "RETRACE_TEST_DISABLE_FILE_LOGGING": "1",
            "RETRACE_TEST_NONINTERACTIVE": "1"})


if __name__ == "__main__":
    unittest.main()
