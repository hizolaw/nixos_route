import importlib.util
from pathlib import Path
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit

spec = importlib.util.spec_from_file_location("console_links", Path(__file__).parents[1] / "scripts/console-links.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class LaunchLinks(unittest.TestCase):
    def test_credentials_are_encoded_and_dashboard_secret_is_only_in_fragment(self):
        with tempfile.TemporaryDirectory() as directory:
            token = Path(directory) / "token"
            token.write_text("test-only-token\n")
            result = module.links({
                "dashboard": {"origin": "http://192.0.2.1:8080", "tokenFile": str(token)},
                "subStore": {"origin": "http://192.0.2.1:17893", "tokenFile": str(token)},
            })
            dashboard = urlsplit(result["DASHBOARD_URL"])
            self.assertEqual(dashboard.query, "")
            self.assertEqual(parse_qs(dashboard.fragment.split("?", 1)[1])["secret"], ["test-only-token"])
            self.assertEqual(parse_qs(urlsplit(result["SUB_STORE_URL"]).query)["api"], ["http://192.0.2.1:17893/test-only-token"])

    def test_missing_service_and_invalid_token_remove_only_affected_link(self):
        with tempfile.TemporaryDirectory() as directory:
            token = Path(directory) / "token"
            token.write_text("not\na\ntoken")
            self.assertEqual(module.links({"dashboard": {"origin": "http://192.0.2.1", "tokenFile": str(token)}, "subStore": None}), {})
            token.unlink()
            self.assertEqual(module.links({"dashboard": {"origin": "http://192.0.2.1", "tokenFile": str(token)}}), {})
