"""Opt-in real provider update integration test; isolated from host networking."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request

import yaml


@unittest.skipUnless(os.environ.get("MIHOMO_BIN"), "set MIHOMO_BIN for isolated integration test")
class FileProviderIntegrationTests(unittest.TestCase):
    def test_file_provider_direct_seed_and_put_hot_update(self):
        with tempfile.TemporaryDirectory(prefix="mihomo-provider-test-") as temporary:
            root = Path(temporary)
            provider = root / "nodes.yaml"
            provider.write_text(yaml.safe_dump({"proxies": [{"name": "initial-direct", "type": "direct"}]}))
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                port = reservation.getsockname()[1]
            config = {
                "mixed-port": 0, "port": 0, "socks-port": 0,
                "allow-lan": False, "bind-address": "127.0.0.1",
                "external-controller": f"127.0.0.1:{port}",
                "secret": "isolated-test-secret", "mode": "rule",
                "tun": {"enable": False}, "dns": {"enable": False},
                "proxy-providers": {"subscription": {"type": "file", "path": str(provider),
                                                       "health-check": {"enable": False}}},
                "proxy-groups": [{"name": "test-selection", "type": "select", "use": ["subscription"]}],
                "rules": ["MATCH,DIRECT"],
            }
            config_path = root / "config.yaml"
            config_path.write_text(yaml.safe_dump(config))
            http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            endpoint = f"http://127.0.0.1:{port}/providers/proxies/subscription"

            def request(method="GET"):
                req = urllib.request.Request(endpoint, method=method,
                                             headers={"Authorization": "Bearer isolated-test-secret"})
                with http.open(req, timeout=1) as response:
                    content = response.read()
                return json.loads(content) if content else None

            with (root / "process.log").open("w+") as log:
                process = subprocess.Popen([os.environ["MIHOMO_BIN"], "-d", str(root), "-f", str(config_path)],
                                           stdout=log, stderr=log)
                try:
                    deadline = time.monotonic() + 15
                    while True:
                        if process.poll() is not None:
                            log.seek(0)
                            self.fail("isolated Mihomo exited: " + log.read())
                        try:
                            initial = request()
                            break
                        except (urllib.error.URLError, TimeoutError):
                            if time.monotonic() >= deadline:
                                self.fail("isolated Mihomo controller did not become ready")
                            time.sleep(0.05)
                    self.assertEqual([proxy["name"] for proxy in initial["proxies"]], ["initial-direct"])
                    # Replace the inode, exactly as the updater does; no daemon restart.
                    replacement = root / "replacement.yaml"
                    replacement.write_text(yaml.safe_dump({"proxies": [{"name": "updated-direct", "type": "direct"}]}))
                    os.replace(replacement, provider)
                    request("PUT")
                    updated = request()
                    self.assertEqual([proxy["name"] for proxy in updated["proxies"]], ["updated-direct"])
                    self.assertIsNone(process.poll())
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
