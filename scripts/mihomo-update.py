#!/usr/bin/env python3
"""Update one local Mihomo node provider; never import subscription policy."""
import datetime
import fcntl
import json
import ipaddress
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

import yaml

MAX_BYTES = 8 * 1024 * 1024


class UpdateError(Exception):
    """A deliberately credential-free error suitable for status reporting."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise UpdateError("subscription redirects are not allowed")


def atomic_write(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".update-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            os.fchmod(output.fileno(), mode)
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def provider_content(content):
    try:
        value = yaml.safe_load(content)
    except (yaml.YAMLError, UnicodeError):
        raise UpdateError("invalid subscription YAML") from None
    if not isinstance(value, dict) or set(value) != {"proxies"}:
        raise UpdateError("subscription must contain only proxies")
    proxies = value["proxies"]
    if not isinstance(proxies, list) or not proxies or len(proxies) > 10000:
        raise UpdateError("subscription has no usable node list")
    names = []
    for proxy in proxies:
        if not isinstance(proxy, dict) or not isinstance(proxy.get("name"), str) or not proxy["name"].strip():
            raise UpdateError("invalid node name")
        names.append(proxy["name"])
    if len(set(names)) != len(names):
        raise UpdateError("duplicate node names")
    try:
        return yaml.safe_dump({"proxies": proxies}, allow_unicode=True).encode(), len(proxies)
    except (ValueError, RecursionError):
        raise UpdateError("invalid subscription structure") from None


class Updater:
    def __init__(self, settings):
        self.settings = settings
        self.runtime = Path(settings["runtimeDirectory"])
        self.provider = self.runtime / "providers/subscription.yaml"
        self.status = Path(settings.get("statusFile", self.runtime / "subscription-status.json"))
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def source(self):
        path = Path(self.settings["sourceFile"])
        if not path.exists() or not path.read_text().strip():
            return None
        url = path.read_text().strip()
        try:
            parsed = urllib.parse.urlsplit(url)
            expected = urllib.parse.urlsplit(self.settings.get("subStoreAddress", "http://127.0.0.1:17893"))
            valid = (
                parsed.scheme == expected.scheme == "http"
                and ipaddress.ip_address(parsed.hostname).is_loopback
                and parsed.hostname == expected.hostname
                and parsed.port == (expected.port or 17893)
                and parsed.path.startswith("/") and not parsed.fragment
                and not parsed.username and not parsed.password
                and len(url) <= 8192 and not any(c.isspace() for c in url)
            )
        except ValueError:
            valid = False
        if not valid:
            raise UpdateError("source must be a local Sub-Store export")
        return url

    def download(self, url):
        with self.http.open(url, timeout=30) as response:
            data = response.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise UpdateError("subscription exceeds size limit")
        return data

    def validate(self, data):
        with tempfile.TemporaryDirectory(prefix=".validate-", dir=self.runtime) as directory:
            directory = Path(directory)
            candidate = directory / "subscription.yaml"
            candidate.write_bytes(data)
            config = yaml.safe_load(Path(self.settings["baseConfigPath"]).read_text())
            config["proxy-providers"]["subscription"]["path"] = str(candidate)
            config_path = directory / "config.yaml"
            config_path.write_text(yaml.safe_dump(config, allow_unicode=True))
            result = subprocess.run(
                [self.settings["mihomoBin"], "-t", "-d", str(self.runtime), "-f", str(config_path)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30, check=False,
            )
            if result.returncode:
                raise UpdateError("Mihomo rejected candidate nodes")

    def refresh(self):
        controller = self.settings.get("controller", "http://127.0.0.1:9090")
        parsed = urllib.parse.urlsplit(controller)
        try:
            valid = (parsed.scheme == "http" and ipaddress.ip_address(parsed.hostname).is_loopback
                     and parsed.port is not None and not parsed.username and not parsed.password
                     and parsed.path in ("", "/") and not parsed.query and not parsed.fragment)
        except ValueError:
            valid = False
        if not valid:
            raise UpdateError("invalid local controller address")
        secret = Path(self.settings["secretFile"]).read_text().strip()
        request = urllib.request.Request(
            controller.rstrip("/") + "/providers/proxies/subscription", method="PUT", data=b"",
            headers={"Authorization": "Bearer " + secret},
        )
        with self.http.open(request, timeout=30) as response:
            response.read(4096)

    def service_active(self):
        command = self.settings.get("serviceActiveCommand")
        if command is None:
            return True
        result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                timeout=10, check=False)
        if result.returncode == 0:
            return True
        if result.returncode == 3:  # systemctl is-active: inactive or failed
            return False
        raise UpdateError("cannot determine Mihomo service state")

    def apply(self, data):
        with (self.runtime / ".configuration.lock").open("a") as configuration_lock:
            fcntl.flock(configuration_lock, fcntl.LOCK_EX)
            return self.apply_locked(data)

    def apply_locked(self, data):
        self.validate(data)
        old = self.provider.read_bytes() if self.provider.exists() else None
        active = self.service_active()
        atomic_write(self.provider, data)
        if not active:
            return "saved"
        try:
            self.refresh()
        except Exception:
            if old is not None:
                atomic_write(self.provider, old)
                try:
                    self.refresh()
                except Exception:
                    raise UpdateError("provider update failed; disk restored; controller recovery failed") from None
            else:
                self.provider.unlink(missing_ok=True)
            raise UpdateError("provider update failed; previous nodes restored") from None
        return "refreshed"

    def run(self):
        self.runtime.mkdir(parents=True, exist_ok=True)
        with (self.runtime / ".subscription-update.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                previous = json.loads(self.status.read_text())
            except (OSError, ValueError):
                previous = {}
            status = {"lastAttempt": now(), "lastSuccess": previous.get("lastSuccess"),
                      "error": None, "count": previous.get("count", 0),
                      "attemptStatus": "skipped", "applied": None,
                      "lastError": previous.get("lastError"), "lastFailure": previous.get("lastFailure")}
            try:
                url = self.source()
                if url is None:
                    status["error"] = "subscription source is not configured"
                else:
                    data, count = provider_content(self.download(url))
                    applied = self.apply(data)
                    status.update(lastSuccess=now(), count=count, applied=applied, attemptStatus="success")
                result = 0
            except UpdateError as error:
                status["error"] = str(error)
                result = 1
            except Exception:
                # Library exceptions may embed request URLs, node secrets or paths.
                status["error"] = "subscription update failed"
                result = 1
            if result:
                status.update(attemptStatus="failed", lastError=status["error"], lastFailure=now())
            atomic_write(self.status, (json.dumps(status) + "\n").encode(), mode=0o640)
            return result


def main():
    try:
        settings = json.loads(Path(sys.argv[1]).read_text())
        return Updater(settings).run()
    except Exception:
        print("subscription updater initialization failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
