#!/usr/bin/env python3
"""Bounded Unix RPC for explicit, transactional Mihomo rule updates."""
import copy
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import signal
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

import yaml

RPC_LIMIT = 512 * 1024
PROVIDER_LIMIT = 2 * 1024 * 1024
CUSTOM_LIMIT = 128 * 1024
AGGREGATE_PROVIDER_LIMIT = 8 * 1024 * 1024
PROVIDER_ENTRY_LIMIT = 20000
CLASSICAL_CHECK_LIMIT = 50000


class RulesError(Exception):
    def __init__(self, status, message):
        self.status = status
        self.message = message
        super().__init__(message)


def invalid():
    raise RulesError(400, "Invalid rules or subscription settings")


def conflict():
    raise RulesError(409, "Configuration changed; reload before saving")


def atomic_write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".rules-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            os.fchmod(output.fileno(), 0o600)
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def json_bytes(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def read_bounded(path, limit):
    with Path(path).open("rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        invalid()
    return data


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RulesError(503, "Rule subscription download failed")


def domain(value):
    if not isinstance(value, str) or len(value) > 253 or not value or value != value.strip():
        invalid()
    value = value.removeprefix("+.").removeprefix(".")
    if not value or not all(re.fullmatch(r"[A-Za-z0-9_*](?:[A-Za-z0-9_*-]*[A-Za-z0-9_*])?", part)
                            for part in value.split(".")):
        invalid()


def top_rule(entry, policy):
    # Classical rule providers omit the policy. Validate that shape before -t;
    # Mihomo otherwise only warns and skips malformed provider records.
    parts = entry.split(",")
    options = []
    if parts[-1] == "no-resolve":
        options = [parts.pop()]
    kinds = {"DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX",
             "IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR", "SRC-PORT", "DST-PORT",
             "NETWORK", "PROCESS-NAME", "PROCESS-PATH", "PROCESS-NAME-REGEX",
             "PROCESS-PATH-REGEX", "UID", "DSCP", "IN-PORT", "IN-TYPE", "IN-USER", "IN-NAME"}
    if len(parts) != 2 or parts[0] not in kinds or not parts[1] or parts[1] != parts[1].strip():
        invalid()
    if parts[0] in {"IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR"}:
        try:
            network = ipaddress.ip_network(parts[1], strict=False)
        except ValueError:
            invalid()
        if parts[0] == "IP-CIDR6" and network.version != 6:
            invalid()
    return ",".join(parts + [policy] + options)


def provider_entries(content, behavior, format_, policy):
    try:
        text = content.decode("utf-8")
        if format_ == "yaml":
            # Scan incrementally before building PyYAML's object graph: a small
            # flow-style document can otherwise allocate hundreds of thousands
            # of scalar nodes inside a 2 MiB transfer limit.
            for index, _token in enumerate(yaml.scan(text)):
                if index > 60020:
                    invalid()
            value = yaml.safe_load(text)
            if not isinstance(value, dict) or set(value) != {"payload"} or not isinstance(value["payload"], list):
                invalid()
            entries = value["payload"]
        else:
            entries = [line.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith("#")]
    except (UnicodeError, yaml.YAMLError, RecursionError):
        invalid()
    if not entries or len(entries) > PROVIDER_ENTRY_LIMIT:
        invalid()
    checks = []
    for entry in entries:
        if not isinstance(entry, str) or not entry or len(entry) > 4096 or any(ord(c) < 32 for c in entry):
            invalid()
        if behavior == "domain":
            domain(entry)
        elif behavior == "ipcidr":
            try:
                ipaddress.ip_network(entry, strict=False)
            except ValueError:
                invalid()
        else:
            checks.append(top_rule(entry, policy))
    return checks


def geo_rule(rule):
    # Inspect rule syntax, not domain values, URLs, policies or other config.
    # Also cover nested logical rules to prevent implicit database downloads.
    return bool(re.search(r"(?:^|\()\s*(?:GEOIP|GEOSITE|GEOIP6)\s*,", rule, re.I))


class RulesWorker:
    def __init__(self, settings):
        self.settings = settings
        self.runtime = Path(settings["runtimeDirectory"])
        self.config = self.runtime / "config.yaml"
        self.custom = self.runtime / "rules/custom.list"
        self.state = self.runtime / "rule-sources.json"
        self.deadline = None
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def lock(self):
        self.runtime.mkdir(parents=True, exist_ok=True)
        handle = (self.runtime / ".configuration.lock").open("a")
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            handle.close()
            raise RulesError(503, "Configuration update is already in progress") from None
        return handle

    def budget(self, maximum):
        remaining = maximum if self.deadline is None else self.deadline - time.monotonic()
        if remaining <= 0:
            raise RulesError(503, "Rules operation timed out")
        return min(maximum, remaining)

    def load(self):
        config_bytes = read_bounded(self.config, 8 * 1024 * 1024)
        custom_bytes = read_bounded(self.custom, CUSTOM_LIMIT)
        state_bytes = read_bounded(self.state, RPC_LIMIT)
        try:
            config = yaml.safe_load(config_bytes)
            state = json.loads(state_bytes)
            custom = custom_bytes.decode()
        except (ValueError, UnicodeError, yaml.YAMLError, RecursionError):
            invalid()
        if not isinstance(config, dict) or not isinstance(config.get("rules", []), list) or not all(isinstance(r, str) for r in config.get("rules", [])):
            invalid()
        if not isinstance(config.get("rule-providers", {}), dict) or not isinstance(state, dict):
            invalid()
        prefix = state.get("appliedRules")
        names = state.get("managedNames")
        if not isinstance(prefix, list) or not all(isinstance(r, str) for r in prefix) or not isinstance(names, list) or not all(isinstance(r, str) and re.fullmatch(r"router-[A-Za-z0-9_-]{1,48}", r) for r in names):
            invalid()
        revision = hashlib.sha256()
        for data in (config_bytes, custom_bytes, state_bytes):
            revision.update(len(data).to_bytes(8, "big"))
            revision.update(data)
        return config, state, custom, revision.hexdigest()

    @staticmethod
    def policies(config):
        groups = config.get("proxy-groups", [])
        if not isinstance(groups, list):
            invalid()
        return list(dict.fromkeys(["DIRECT", "REJECT", "REJECT-DROP"] + [g["name"] for g in groups if isinstance(g, dict) and isinstance(g.get("name"), str)]))

    def subscriptions(self, value, policies):
        if not isinstance(value, list) or len(value) > 16:
            invalid()
        names = set()
        result = []
        for item in value:
            if not isinstance(item, dict) or set(item) != {"name", "url", "behavior", "format", "policy", "enabled"}:
                invalid()
            name, url = item["name"], item["url"]
            if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,48}", name) or name in names:
                invalid()
            names.add(name)
            if not isinstance(url, str) or len(url) > 4096 or any(ord(c) <= 32 for c in url):
                invalid()
            try:
                parsed = urllib.parse.urlsplit(url)
                valid = parsed.scheme == "https" and parsed.hostname and not parsed.username and not parsed.password and not parsed.fragment
                parsed.port
            except ValueError:
                valid = False
            if not valid or item["behavior"] not in ("domain", "ipcidr", "classical") or item["format"] not in ("yaml", "text") or item["policy"] not in policies or type(item["enabled"]) is not bool:
                invalid()
            result.append(copy.deepcopy(item))
        return result

    @staticmethod
    def custom_rules(text):
        if not isinstance(text, str) or len(text.encode()) > CUSTOM_LIMIT or len(text.splitlines()) > 2000 or "\0" in text:
            invalid()
        entries = [line.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith("#")]
        # Geo database acquisition is outside this worker's scope.
        if any(geo_rule(rule) for rule in entries):
            invalid()
        return entries

    def initialize(self):
        with self.lock():
            if not self.custom.exists():
                atomic_write(self.custom, b"# Custom Mihomo rules, one rule per line.\n")
            ads = self.runtime / "rules/providers/router-ads.yaml"
            if not ads.exists() and self.settings.get("adsAsset"):
                data = read_bounded(self.settings["adsAsset"], PROVIDER_LIMIT)
                provider_entries(data, "domain", "yaml", "REJECT")
                atomic_write(ads, data)
            if not self.state.exists():
                try:
                    config = yaml.safe_load(read_bounded(self.config, 8 * 1024 * 1024))
                except (yaml.YAMLError, ValueError, RecursionError):
                    invalid()
                if not isinstance(config, dict):
                    invalid()
                subscriptions = self.subscriptions(self.settings.get("defaultSubscriptions", []), self.policies(config))
                prefix = [f'RULE-SET,router-{s["name"]},{s["policy"]}' for s in subscriptions if s["enabled"]]
                adopted = config.get("rules", [])[:len(prefix)] == prefix
                atomic_write(self.state, json_bytes({"subscriptions": subscriptions, "appliedRules": prefix if adopted else [], "managedNames": [f'router-{s["name"]}' for s in subscriptions if s["enabled"]] if adopted else []}))

    def get(self):
        with self.lock():
            config, state, custom, revision = self.load()
            subscriptions = self.subscriptions(state.get("subscriptions"), self.policies(config))
            return {"revision": revision, "rules": custom, "subscriptions": subscriptions, "policies": self.policies(config), "file_path": str(self.custom)}

    def download(self, url):
        try:
            with self.http.open(url, timeout=self.budget(5)) as response:
                chunks, size = [], 0
                while True:
                    self.budget(5)
                    chunk = response.read1(min(65536, PROVIDER_LIMIT + 1 - size))
                    if not chunk:
                        break
                    chunks.append(chunk)
                    size += len(chunk)
                    if size > PROVIDER_LIMIT:
                        invalid()
                data = b"".join(chunks)
            if len(data) > PROVIDER_LIMIT:
                invalid()
            return data
        except RulesError:
            raise
        except Exception:
            raise RulesError(503, "Rule subscription download failed") from None

    def service_active(self):
        command = self.settings.get("serviceActiveCommand")
        if command is None:
            return True
        result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=self.budget(10), check=False)
        if result.returncode == 0:
            return True
        if result.returncode == 3:
            return False
        raise RulesError(503, "Cannot determine Mihomo service state")

    def refresh(self):
        controller = self.settings.get("controller", "http://127.0.0.1:9090")
        try:
            parsed = urllib.parse.urlsplit(controller)
            valid = parsed.scheme == "http" and ipaddress.ip_address(parsed.hostname).is_loopback and parsed.port and not parsed.username and not parsed.password and parsed.path in ("", "/") and not parsed.query and not parsed.fragment
        except (ValueError, TypeError):
            valid = False
        if not valid:
            raise RulesError(503, "Local controller is unavailable")
        secret = Path(self.settings["secretFile"]).read_text().strip()
        request = urllib.request.Request(controller.rstrip("/") + "/configs", method="PUT", data=json_bytes({"path": str(self.config)}), headers={"Content-Type": "application/json", "Authorization": "Bearer " + secret})
        with self.http.open(request, timeout=self.budget(8)):
            pass

    def validate(self, candidate, cache, checks):
        test = copy.deepcopy(candidate)
        test["rules"] = checks + test["rules"]
        # -t must not initiate provider fetches. Keep every provider local during
        # validation, while retaining native HTTP providers in the committed file.
        with tempfile.TemporaryDirectory(prefix=".rules-check-", dir=self.runtime) as directory:
            directory = Path(directory)
            for name, provider in test.get("rule-providers", {}).items():
                if not isinstance(provider, dict) or not isinstance(provider.get("path"), str):
                    invalid()
                source = Path(provider["path"])
                if not source.is_absolute():
                    source = self.runtime / source
                if source in cache:
                    path = directory / f"provider-{len(list(directory.iterdir()))}"
                    atomic_write(path, cache[source])
                elif source.exists():
                    path = source
                else:
                    raise RulesError(503, "A rule provider cache is unavailable")
                provider["type"] = "file"
                provider["path"] = str(path)
                for key in ("url", "interval", "size-limit", "proxy", "header"):
                    provider.pop(key, None)
            # Native geo rules may already exist, but never bootstrap databases.
            serialized = yaml.safe_dump(test, allow_unicode=True)
            if any(geo_rule(rule) for rule in test["rules"]):
                raise RulesError(400, "Geo database rules are not supported by this editor")
            path = directory / "config.yaml"
            atomic_write(path, serialized.encode())
            result = subprocess.run([self.settings["mihomoBin"], "-t", "-d", str(self.runtime), "-f", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=self.budget(30), check=False)
            if result.returncode:
                raise RulesError(400, "Mihomo rejected the candidate rules")

    def apply(self, data=None):
        # The worker is deliberately single-threaded. A process timer also bounds
        # slow-drip HTTP headers/bodies, which socket idle timeouts alone cannot.
        previous_handler = signal.getsignal(signal.SIGALRM)
        def expired(_number, _frame):
            raise RulesError(503, "Rules operation timed out")
        signal.signal(signal.SIGALRM, expired)
        signal.setitimer(signal.ITIMER_REAL, 35)
        try:
            return self._apply(data)
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous_handler)
            self.deadline = None

    def _apply(self, data=None):
        self.deadline = time.monotonic() + 35
        with self.lock():
            config, state, custom, revision = self.load()
            if data is not None:
                if not isinstance(data, dict) or set(data) != {"revision", "rules", "subscriptions"}:
                    invalid()
                if data["revision"] != revision:
                    conflict()
                custom = data["rules"]
                subscription_value = data["subscriptions"]
            else:
                subscription_value = state.get("subscriptions")
            subscriptions = self.subscriptions(subscription_value, self.policies(config))
            prefix = self.custom_rules(custom)
            old_prefix = state["appliedRules"]
            if config.get("rules", [])[:len(old_prefix)] != old_prefix:
                conflict()
            candidate = copy.deepcopy(config)
            remaining = config.get("rules", [])[len(old_prefix):]
            providers = {name: value for name, value in config.get("rule-providers", {}).items() if name not in state["managedNames"]}
            previous = {s["name"]: s for s in self.subscriptions(state.get("subscriptions"), self.policies(config))}
            cache, checks, names = {}, [], []
            aggregate_bytes = 0
            for sub in subscriptions:
                if not sub["enabled"]:
                    continue
                name = "router-" + sub["name"]
                if name in providers:
                    conflict()
                path = self.runtime / f'rules/providers/{name}.{sub["format"]}'
                old = previous.get(sub["name"])
                if not path.exists() or old is None or old["url"] != sub["url"]:
                    content = self.download(sub["url"])
                    cache[path] = content
                else:
                    content = read_bounded(path, PROVIDER_LIMIT)
                aggregate_bytes += len(content)
                if aggregate_bytes > AGGREGATE_PROVIDER_LIMIT:
                    raise RulesError(400, "Combined rule providers exceed the resource budget")
                checks.extend(provider_entries(content, sub["behavior"], sub["format"], sub["policy"]))
                if len(checks) > CLASSICAL_CHECK_LIMIT:
                    raise RulesError(400, "Combined rule providers exceed the resource budget")
                providers[name] = {"type": "http", "behavior": sub["behavior"], "format": sub["format"], "url": sub["url"], "path": str(path), "interval": 86400, "size-limit": PROVIDER_LIMIT}
                names.append(name)
                prefix.append(f'RULE-SET,{name},{sub["policy"]}')
            candidate["rules"] = prefix + remaining
            candidate["rule-providers"] = providers
            self.validate(candidate, cache, checks)
            active = self.service_active()
            changes = {**cache, self.config: yaml.safe_dump(candidate, allow_unicode=True, sort_keys=False).encode(), self.custom: custom.encode(), self.state: json_bytes({"subscriptions": subscriptions, "appliedRules": prefix, "managedNames": names})}
            old_files = {path: read_bounded(path, 8 * 1024 * 1024) if path.exists() else None for path in changes}
            try:
                for path, content in changes.items():
                    atomic_write(path, content)
                if active:
                    self.refresh()
            except Exception:
                self.deadline = time.monotonic() + 8
                signal.setitimer(signal.ITIMER_REAL, 8)
                try:
                    for path, content in old_files.items():
                        if content is None:
                            path.unlink(missing_ok=True)
                        else:
                            atomic_write(path, content)
                    if active:
                        self.refresh()
                except Exception:
                    raise RulesError(503, "Rules apply failed; configuration recovery failed") from None
                raise RulesError(503, "Rules apply failed; previous configuration restored") from None
        self.deadline = None
        result = self.get()
        result["applied"] = "reloaded" if active else "saved"
        return result

    def dispatch(self, request):
        try:
            if not isinstance(request, dict) or set(request) - {"action", "data"}:
                invalid()
            action = request.get("action")
            if action == "get":
                result = self.get()
            elif action == "save":
                if "data" not in request:
                    invalid()
                result = self.apply(request["data"])
            elif action == "reload":
                result = self.apply()
            else:
                invalid()
            reply = {"ok": True, "data": result}
            if len(json_bytes(reply)) + 1 > RPC_LIMIT:
                raise RulesError(503, "Rules response is too large")
            return reply
        except RulesError as error:
            return {"ok": False, "status": error.status, "error": error.message}
        except Exception:
            return {"ok": False, "status": 503, "error": "Rules operation is unavailable"}
        finally:
            self.deadline = None

    def serve(self):
        self.initialize()
        path = Path(self.settings["socket"])
        path.unlink(missing_ok=True)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            server.bind(str(path))
            os.chmod(path, 0o660)
            server.listen(4)
            while True:
                connection, _ = server.accept()
                with connection:
                    connection.settimeout(60)
                    try:
                        with connection.makefile("rb") as stream:
                            line = stream.readline(RPC_LIMIT + 1)
                            if len(line) > RPC_LIMIT or not line.endswith(b"\n"):
                                invalid()
                            request = json.loads(line)
                        reply = self.dispatch(request)
                    except RulesError as error:
                        reply = {"ok": False, "status": error.status, "error": error.message}
                    except Exception:
                        reply = {"ok": False, "status": 400, "error": "Invalid rules request"}
                    try:
                        connection.sendall(json_bytes(reply) + b"\n")
                    except OSError:
                        pass


if __name__ == "__main__":
    try:
        settings = json.loads(Path(sys.argv[1]).read_text())
        RulesWorker(settings).serve()
    except Exception:
        print("Mihomo rules service failed", file=sys.stderr)
        sys.exit(1)
