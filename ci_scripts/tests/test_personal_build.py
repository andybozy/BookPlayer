"""Exercise the build-time guard without Xcode or real signing/account secrets."""
import os
from pathlib import Path
import subprocess
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'validate_personal_build.sh'
VALID = {
    'BP_SELF_HOSTED': 'YES',
    'BP_API_SCHEME': 'https',
    'BP_API_DOMAIN': 'bookplayer.androshera.xyz',
    'BP_API_PORT': '',
    'BP_ENTITLEMENTS': 'BookPlayer-SelfHosted',
    'BP_WATCH_ENTITLEMENTS': 'BookPlayerWatch-SelfHosted',
    'BP_MOCKED_BEARER_TOKEN': '',
    'BP_REVENUECAT_KEY': '',
    'BP_SENTRY_DSN': '',
}


class PersonalBuildTests(unittest.TestCase):
    def run_guard(self, overrides):
        env = {key: value for key, value in os.environ.items() if not key.startswith('BP_')}
        env.update(VALID)
        for key, value in overrides.items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value
        return subprocess.run(['/bin/sh', str(SCRIPT)], env=env, text=True,
                              capture_output=True, timeout=5)

    def test_personal_login_configuration_passes(self):
        result = self.run_guard({})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('username/password login', result.stdout)

    def test_omitted_or_disabled_personal_mode_fails_before_apple_login_can_ship(self):
        for value in [None, '', 'NO', '$(BP_SELF_HOSTED)']:
            with self.subTest(value=value):
                result = self.run_guard({'BP_SELF_HOSTED': value})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('BP_SELF_HOSTED must be YES', result.stderr)

    def test_upstream_placeholder_and_insecure_endpoints_are_rejected(self):
        for override in [{'BP_API_SCHEME': 'http'}, {'BP_API_DOMAIN': 'api.bookplayer.app'},
                         {'BP_API_DOMAIN': 'replace.me'}, {'BP_API_PORT': '5003'}]:
            with self.subTest(override=override):
                self.assertNotEqual(self.run_guard(override).returncode, 0)

    def test_both_targets_require_personal_entitlements(self):
        for key, value in [('BP_ENTITLEMENTS', 'BookPlayer-NoCarPlay'),
                           ('BP_WATCH_ENTITLEMENTS', 'BookPlayerWatch')]:
            with self.subTest(key=key):
                result = self.run_guard({key: value})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('entitlements', result.stderr)

    def test_stale_mock_or_upstream_credentials_fail_without_being_printed(self):
        secret = 'fixture-secret-must-never-be-logged'
        for key in ['BP_MOCKED_BEARER_TOKEN', 'BP_REVENUECAT_KEY', 'BP_SENTRY_DSN']:
            with self.subTest(key=key):
                result = self.run_guard({key: secret})
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(secret, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
