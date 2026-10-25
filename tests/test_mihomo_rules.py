import copy
import fcntl
import importlib.util
import json
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import yaml

spec = importlib.util.spec_from_file_location("mihomo_rules", Path(__file__).parents[1] / "scripts/mihomo-rules.py")
rules = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rules)


class RulesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.asset = self.root / "ads.yaml"
        self.asset.write_text("payload:\n - '+.ads.example'\n")
        self.settings = {"runtimeDirectory": str(self.root), "socket": str(self.root / "rpc.sock"),
                         "mihomoBin": "mihomo", "secretFile": str(self.root / "secret"),
                         "adsAsset": str(self.asset), "defaultSubscriptions": [self.sub()]}
        self.config = {"dns": {"listen": "127.0.0.1:1053"}, "tun": {"auto-route": True},
                       "secret": "PRIVATE", "external-controller": "127.0.0.1:9090", "mixed-port": 7890,
                       "proxy-groups": [{"name": "Select", "type": "select", "proxies": ["DIRECT"]}],
                       "proxy-providers": {"nodes": {"path": "providers/nodes.yaml"}},
                       "rules": ["DOMAIN,original.example,DIRECT", "MATCH,Select"],
                       "rule-providers": {}}
        (self.root / "config.yaml").write_text(yaml.safe_dump(self.config))
        self.worker = rules.RulesWorker(self.settings)
        self.worker.initialize()

    def sub(self, **updates):
        value = {"name": "ads", "url": "https://example.org/ads.yaml", "behavior": "domain",
                 "format": "yaml", "policy": "REJECT", "enabled": True}
        value.update(updates)
        return value

    def request(self, **updates):
        state = self.worker.get()
        data = {"revision": state["revision"], "rules": "DOMAIN,custom.example,Select\n", "subscriptions": state["subscriptions"]}
        data.update(updates)
        return data

    def snapshot(self):
        return {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob("*") if p.is_file() and p.name != ".configuration.lock"}

    def test_shared_lock_contention_fails_fast_without_any_changes(self):
        before = self.snapshot()
        with (self.root / ".configuration.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            reply = self.worker.dispatch({"action": "reload"})
        self.assertEqual(reply["status"], 503)
        self.assertEqual(self.snapshot(), before)

    def test_deadline_stops_before_writing_or_starting_validation(self):
        before = self.snapshot()
        with patch.object(self.worker, "budget", side_effect=rules.RulesError(503, "Rules operation timed out")):
            reply = self.worker.dispatch({"action": "save", "data": self.request()})
        self.assertEqual(reply["status"], 503)
        self.assertEqual(self.snapshot(), before)

    def test_initialize_seeds_only_missing_and_never_applies(self):
        before = self.snapshot()
        with patch.object(self.worker, "refresh") as refresh:
            self.worker.initialize()
            refresh.assert_not_called()
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(json.loads(self.worker.state.read_text())["appliedRules"], [])
        self.assertEqual(stat.S_IMODE(self.worker.state.stat().st_mode), 0o600)
        self.assertEqual(yaml.safe_load(self.worker.config.read_text()), self.config)

    def test_fresh_template_prefix_can_be_adopted_without_duplicate(self):
        self.worker.state.unlink()
        fresh = copy.deepcopy(self.config)
        fresh["rules"].insert(0, "RULE-SET,router-ads,REJECT")
        self.worker.config.write_text(yaml.safe_dump(fresh))
        self.worker.initialize()
        state = json.loads(self.worker.state.read_text())
        self.assertEqual(state["appliedRules"], ["RULE-SET,router-ads,REJECT"])
        self.assertEqual(state["managedNames"], ["router-ads"])

    def test_save_preserves_network_nodes_and_base_rules_and_cached_seed(self):
        data = self.request()
        with patch.object(self.worker, "validate") as validate, patch.object(self.worker, "refresh") as refresh, patch.object(self.worker, "download") as download:
            result = self.worker.apply(data)
            validate.assert_called_once()
            refresh.assert_called_once()
            download.assert_not_called()
        current = yaml.safe_load(self.worker.config.read_text())
        for key in self.config.keys() - {"rules", "rule-providers"}:
            self.assertEqual(current[key], self.config[key])
        self.assertEqual(current["rules"], ["DOMAIN,custom.example,Select", "RULE-SET,router-ads,REJECT"] + self.config["rules"])
        self.assertEqual(current["rule-providers"]["router-ads"]["type"], "http")
        self.assertEqual(result["rules"], data["rules"])
        self.assertEqual(result["applied"], "reloaded")
        self.assertNotEqual(result["revision"], data["revision"])
        with patch.object(self.worker, "validate"), patch.object(self.worker, "refresh"):
            self.worker.apply(self.request(rules="DOMAIN,second.example,DIRECT\n"))
        current = yaml.safe_load(self.worker.config.read_text())
        self.assertNotIn("DOMAIN,custom.example,Select", current["rules"])
        self.assertEqual(current["rules"].count("RULE-SET,router-ads,REJECT"), 1)

    def test_unmanaged_provider_is_preserved_and_reserved_collision_is_rejected(self):
        config = copy.deepcopy(self.config)
        config["rule-providers"] = {"external": {"type": "file", "path": "external.yaml", "behavior": "domain"}}
        self.worker.config.write_text(yaml.safe_dump(config))
        with patch.object(self.worker, "validate"), patch.object(self.worker, "refresh"):
            self.worker.apply(self.request())
        current = yaml.safe_load(self.worker.config.read_text())
        self.assertEqual(current["rule-providers"]["external"], config["rule-providers"]["external"])
        current["rule-providers"]["router-other"] = {"type": "file", "path": "external.yaml"}
        self.worker.config.write_text(yaml.safe_dump(current))
        before = self.snapshot()
        with self.assertRaises(rules.RulesError) as error:
            self.worker.apply(self.request(subscriptions=[self.sub(name="other")]))
        self.assertEqual(error.exception.status, 409)
        self.assertEqual(self.snapshot(), before)

    def test_revision_and_modified_managed_prefix_conflict(self):
        data = self.request(revision="stale")
        with self.assertRaises(rules.RulesError) as error:
            self.worker.apply(data)
        self.assertEqual(error.exception.status, 409)
        with patch.object(self.worker, "validate"), patch.object(self.worker, "refresh"):
            self.worker.apply(self.request())
        config = yaml.safe_load(self.worker.config.read_text())
        config["rules"][0] = "DOMAIN,external-change.example,DIRECT"
        self.worker.config.write_text(yaml.safe_dump(config))
        before = self.snapshot()
        with self.assertRaises(rules.RulesError) as error:
            self.worker.apply(self.request())
        self.assertEqual(error.exception.status, 409)
        self.assertEqual(self.snapshot(), before)

    def test_download_or_validation_failure_changes_nothing(self):
        before = self.snapshot()
        for method, data in [("download", self.request(subscriptions=[self.sub(url="https://example.org/new.yaml")])),
                             ("validate", self.request())]:
            with self.subTest(method=method), patch.object(self.worker, method, side_effect=RuntimeError("SECRET URL")):
                reply = self.worker.dispatch({"action": "save", "data": data})
                self.assertFalse(reply["ok"])
                self.assertNotIn("SECRET", json.dumps(reply))
                self.assertEqual(self.snapshot(), before)

    def test_reload_failure_rolls_back_all_files_and_reloads_previous_config(self):
        before = self.snapshot()
        with patch.object(self.worker, "download", return_value=b"payload: ['+.new.example']\n"), patch.object(self.worker, "validate"), patch.object(self.worker, "refresh", side_effect=[RuntimeError("SECRET"), None]) as refresh:
            reply = self.worker.dispatch({"action": "save", "data": self.request(subscriptions=[self.sub(url="https://example.org/new.yaml")])})
        self.assertEqual(reply["status"], 503)
        self.assertEqual(refresh.call_count, 2)
        self.assertEqual(self.snapshot(), before)
        self.assertNotIn("SECRET", json.dumps(reply))

    def test_inactive_core_is_saved_without_start_or_reload(self):
        with patch.object(self.worker, "service_active", return_value=False), patch.object(self.worker, "validate"), patch.object(self.worker, "refresh") as refresh:
            result = self.worker.apply(self.request())
        refresh.assert_not_called()
        self.assertEqual(result["applied"], "saved")

    def test_reload_reads_handwritten_custom_file(self):
        self.worker.custom.write_text("# comment\nDOMAIN,handwritten.example,DIRECT\n")
        with patch.object(self.worker, "validate"), patch.object(self.worker, "refresh"):
            self.worker.apply()
        self.assertEqual(yaml.safe_load(self.worker.config.read_text())["rules"][0], "DOMAIN,handwritten.example,DIRECT")

    def test_geo_keywords_in_domains_do_not_trigger_database_checks(self):
        self.assertEqual(self.worker.custom_rules("DOMAIN,geoip.example,DIRECT"), ["DOMAIN,geoip.example,DIRECT"])
        self.assertFalse(rules.geo_rule("DOMAIN,geosite,DIRECT"))
        self.assertTrue(rules.geo_rule("AND,((NETWORK,TCP),(GEOIP,CN)),DIRECT"))

    def test_dense_provider_is_rejected_before_large_yaml_object_graph(self):
        content = b"payload: [" + b"a," * 30001 + b"a]"
        with self.assertRaises(rules.RulesError):
            rules.provider_entries(content, "domain", "yaml", "REJECT")

    def test_rejects_invalid_settings_and_content(self):
        for sub in [self.sub(name="../escape"), self.sub(name="x" * 49), self.sub(url="http://example.org/a"), self.sub(url="https://user:secret@example.org/a"), self.sub(policy="missing"), self.sub(behavior="bad"), self.sub(format="mrs"), self.sub(enabled=1)]:
            with self.subTest(sub=sub), self.assertRaises(rules.RulesError):
                self.worker.subscriptions([sub], ["DIRECT", "REJECT"])
        with self.assertRaises(rules.RulesError):
            self.worker.subscriptions([self.sub(), self.sub()], ["REJECT"])
        for text in ["x" * (rules.CUSTOM_LIMIT + 1), "\n" * 2001, "GEOIP,CN,DIRECT"]:
            with self.assertRaises(rules.RulesError):
                self.worker.custom_rules(text)
        for content, behavior in [(b"payload: [null]", "domain"), (b"payload: ['bad domain']", "domain"), (b"payload: ['bad/cidr']", "ipcidr"), (b"payload: ['DOMAIN,example.org,DIRECT']", "classical"), (b"payload: ['GEOIP,CN']", "classical")]:
            with self.subTest(content=content), self.assertRaises(rules.RulesError):
                rules.provider_entries(content, behavior, "yaml", "REJECT")

    def test_classical_entries_are_validated_as_top_level_and_providers_are_offline(self):
        cache = self.root / "classical.yaml"
        content = b"payload: ['DOMAIN,ads.example', 'IP-CIDR,192.0.2.0/24,no-resolve']"
        checks = rules.provider_entries(content, "classical", "yaml", "REJECT")
        self.assertEqual(checks, ["DOMAIN,ads.example,REJECT", "IP-CIDR,192.0.2.0/24,REJECT,no-resolve"])
        candidate = copy.deepcopy(self.config)
        candidate["rule-providers"] = {"classical": {"type": "http", "path": str(cache), "url": "https://example.org/list", "behavior": "classical"}}
        def validate_process(command, **kwargs):
            test = yaml.safe_load(Path(command[-1]).read_text())
            self.assertEqual(test["rules"][:2], checks)
            provider = test["rule-providers"]["classical"]
            self.assertEqual(provider["type"], "file")
            self.assertNotIn("url", provider)
            self.assertEqual(Path(provider["path"]).read_bytes(), content)
            return subprocess.CompletedProcess(command, 0)
        with patch.object(rules.subprocess, "run", side_effect=validate_process):
            self.worker.validate(candidate, {cache: content}, checks)
        self.assertEqual(candidate["rule-providers"]["classical"]["type"], "http")


if __name__ == "__main__":
    unittest.main()
