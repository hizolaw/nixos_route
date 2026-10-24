import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import stat
import unittest
from unittest.mock import patch
import urllib.error

spec = importlib.util.spec_from_file_location("updater", Path(__file__).parents[1] / "scripts/mihomo-update.py")
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.settings = {"runtimeDirectory": str(self.root), "sourceFile": str(self.root / "source"),
                         "subStoreAddress": "http://127.0.0.1:17893"}
        self.instance = updater.Updater(self.settings)
        self.instance.provider.parent.mkdir()
        self.instance.provider.write_bytes(b"old nodes")
        Path(self.settings["sourceFile"]).write_text("http://127.0.0.1:17893/download/nodes?token=SECRET")

    def test_reject_policy_overrides(self):
        for field in ("dns", "tun", "rules", "external-controller", "proxy-providers"):
            with self.subTest(field=field), self.assertRaises(updater.UpdateError):
                updater.provider_content(f"proxies: [{{name: example}}]\n{field}: {{}}")

    def test_duplicate_and_empty_nodes(self):
        for content in ("proxies: []", "proxies: [{name: a}, {name: a}]", "proxies: [null]"):
            with self.assertRaises(updater.UpdateError):
                updater.provider_content(content)

    def test_failed_validation_preserves_file(self):
        with patch.object(self.instance, "validate", side_effect=updater.UpdateError("invalid")), \
             patch.object(self.instance, "refresh") as refresh:
            with self.assertRaises(updater.UpdateError):
                self.instance.apply(b"new")
            refresh.assert_not_called()
        self.assertEqual(self.instance.provider.read_bytes(), b"old nodes")

    def test_failed_apply_restores_old_nodes_and_refreshes(self):
        with patch.object(self.instance, "validate"), \
             patch.object(self.instance, "refresh", side_effect=[OSError("SECRET"), None]) as refresh:
            with self.assertRaisesRegex(updater.UpdateError, "previous nodes restored"):
                self.instance.apply(b"new")
            self.assertEqual(refresh.call_count, 2)
        self.assertEqual(self.instance.provider.read_bytes(), b"old nodes")

    def test_success_updates_nodes_only(self):
        with patch.object(self.instance, "validate"), patch.object(self.instance, "refresh") as refresh:
            self.instance.apply(b"new")
        self.assertEqual(self.instance.provider.read_bytes(), b"new")
        refresh.assert_called_once_with()

    def test_status_redacts_library_exception(self):
        with patch.object(self.instance, "download", side_effect=urllib.error.URLError("SECRET token URL")):
            self.assertEqual(self.instance.run(), 1)
        status = self.instance.status.read_text()
        self.assertNotIn("SECRET", status)
        self.assertNotIn("http", status)
        self.assertEqual(set(json.loads(status)), {"lastAttempt", "lastSuccess", "error", "count", "attemptStatus", "applied", "lastError", "lastFailure"})
        self.assertEqual(self.instance.provider.read_bytes(), b"old nodes")

    def test_external_sources_are_rejected(self):
        for url in ("https://127.0.0.1:17893/nodes", "http://example.org:17893/nodes",
                    "http://127.0.0.1:9090/nodes", "http://user:SECRET@127.0.0.1:17893/nodes"):
            Path(self.settings["sourceFile"]).write_text(url)
            with self.assertRaises(updater.UpdateError):
                self.instance.source()

    def test_missing_source_is_safe_noop(self):
        Path(self.settings["sourceFile"]).unlink()
        self.assertEqual(self.instance.run(), 0)
        self.assertEqual(self.instance.provider.read_bytes(), b"old nodes")

    def test_configured_local_ports(self):
        self.settings["subStoreAddress"] = "http://127.0.0.2:27893"
        Path(self.settings["sourceFile"]).write_text("http://127.0.0.2:27893/download/nodes")
        self.assertEqual(self.instance.source(), "http://127.0.0.2:27893/download/nodes")
        self.settings["controller"] = "http://[::1]:29090"
        self.settings["secretFile"] = str(self.root / "secret")
        (self.root / "secret").write_text("SECRET")
        with patch.object(self.instance.http, "open") as request:
            self.instance.refresh()
        self.assertEqual(request.call_args.args[0].full_url,
                         "http://[::1]:29090/providers/proxies/subscription")

    def test_inactive_core_saves_without_starting_or_refreshing(self):
        self.settings["serviceActiveCommand"] = ["systemctl", "is-active", "mihomo-router"]
        with patch.object(self.instance, "download", return_value=b"proxies: [{name: a}]"), \
             patch.object(self.instance, "validate"), \
             patch.object(self.instance, "refresh") as refresh, \
             patch.object(updater.subprocess, "run", return_value=subprocess.CompletedProcess([], 3)) as run:
            self.assertEqual(self.instance.run(), 0)
        refresh.assert_not_called()
        self.assertEqual(run.call_args.args[0], ["systemctl", "is-active", "mihomo-router"])
        self.assertIn(b"name: a", self.instance.provider.read_bytes())
        status = json.loads(self.instance.status.read_text())
        self.assertEqual(status["applied"], "saved")
        self.assertEqual(status["attemptStatus"], "success")

    def test_last_error_survives_successful_attempt(self):
        with patch.object(self.instance, "download", side_effect=OSError("SECRET")):
            self.instance.run()
        failure = json.loads(self.instance.status.read_text())
        with patch.object(self.instance, "download", return_value=b"proxies: [{name: a}]"), \
             patch.object(self.instance, "apply", return_value="refreshed"):
            self.assertEqual(self.instance.run(), 0)
        status = json.loads(self.instance.status.read_text())
        self.assertIsNone(status["error"])
        self.assertEqual(status["attemptStatus"], "success")
        self.assertEqual(status["lastError"], failure["error"])
        self.assertEqual(status["lastFailure"], failure["lastFailure"])

    def test_status_shared_read_only_and_provider_private(self):
        self.settings["statusFile"] = str(self.root / "shared" / "status.json")
        instance = updater.Updater(self.settings)
        with patch.object(instance, "download", return_value=b"proxies: [{name: a}]"), \
             patch.object(instance, "validate"), patch.object(instance, "refresh"):
            self.assertEqual(instance.run(), 0)
        self.assertEqual(stat.S_IMODE(instance.status.stat().st_mode), 0o640)
        self.assertEqual(stat.S_IMODE(instance.provider.stat().st_mode), 0o600)
        self.assertFalse((self.root / "subscription-status.json").exists())
        self.assertNotIn("SECRET", instance.status.read_text())

    def test_redirects_are_rejected(self):
        with self.assertRaises(updater.UpdateError):
            updater.NoRedirect().redirect_request(None, None, 302, "", {}, "http://external/SECRET")


if __name__ == "__main__":
    unittest.main()
