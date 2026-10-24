import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("migrate", Path(__file__).parents[1] / "scripts/mihomo-migrate.py")
migrate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migrate)


class RuleMigrationTests(unittest.TestCase):
    def test_preserves_direct_reject_and_replaces_legacy_groups(self):
        rules = migrate.migrate_rules([
            "DOMAIN-SUFFIX,lan,DIRECT", "DOMAIN,ads.example,REJECT",
            "IP-CIDR,192.0.2.0/24,legacy-group,no-resolve",
            "DOMAIN,proxy.example,legacy-group", "GEOIP,CN,DIRECT,no-resolve",
            "GEOIP,US,legacy-group", "MATCH,legacy-group",
        ])
        self.assertEqual(rules, [
            "DOMAIN-SUFFIX,lan,DIRECT", "DOMAIN,ads.example,REJECT",
            "IP-CIDR,192.0.2.0/24,故障回退,no-resolve",
            "DOMAIN,proxy.example,故障回退", "RULE-SET,cncidr,DIRECT,no-resolve",
            "MATCH,故障回退",
        ])
        self.assertFalse(any(rule.startswith("GEOIP,") for rule in rules))

    def test_empty_policy_has_explicit_final_fallback(self):
        self.assertEqual(migrate.migrate_rules([]), ["MATCH,故障回退"])


if __name__ == "__main__":
    unittest.main()
