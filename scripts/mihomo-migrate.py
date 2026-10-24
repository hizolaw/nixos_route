#!/usr/bin/env python3
"""Explicit, backed-up migration. This is never called from startup or a timer."""
import argparse
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

import yaml


def write_private(path, content):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=".migrate-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def migrate_rules(rules):
    """Preserve direct/reject policy, route other legacy groups through new selection."""
    result = []
    for rule in rules:
        if not isinstance(rule, str):
            raise ValueError("invalid legacy rule")
        parts = rule.split(",")
        if parts[0] == "GEOIP":
            if len(parts) > 2 and parts[1] == "CN":
                result.append("RULE-SET,cncidr,DIRECT,no-resolve")
            # Other country guesses need an external GeoIP DB; use remaining policy.
            continue
        index = -2 if parts[-1] == "no-resolve" else -1
        if parts[index] not in {"DIRECT", "REJECT", "REJECT-DROP", "PASS"}:
            parts[index] = "故障回退"
        result.append(",".join(parts))
    if not result or not result[-1].startswith("MATCH,"):
        result.append("MATCH,故障回退")
    return result


def stage(settings, legacy):
    state = Path(settings["runtimeDirectory"])
    config = state / "config.yaml"
    if config.exists():
        print("Existing standalone profile preserved")
        return
    active = yaml.safe_load((legacy / "active.yaml").read_text())
    proxies = active.get("proxies")
    if not isinstance(proxies, list) or not proxies:
        raise ValueError("legacy profile has no nodes")
    base = json.loads(Path(settings["baseTemplatePath"]).read_text())
    base["rules"] = migrate_rules(active.get("rules", []))
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    console_token = Path("/var/lib/router-console/access.token")
    secret_path = state / "controller-secret"
    if secret_path.exists():
        secret = secret_path.read_text().strip()
    elif console_token.exists():
        secret = console_token.read_text().strip()
    else:
        secret = secrets.token_hex(32)
    base["secret"] = secret
    write_private(secret_path, (secret + "\n").encode())
    write_private(state / "environment", ("CLASH_SECRET=" + secret + "\n").encode())
    write_private(state / "providers/subscription.yaml", yaml.safe_dump({"proxies": proxies}, allow_unicode=True).encode())
    rules_path = state / "rules/cncidr.yaml"
    write_private(rules_path, Path(settings["cncidrAsset"]).read_bytes())
    with tempfile.TemporaryDirectory(prefix=".migrate-check-", dir=state) as temporary:
        candidate = Path(temporary) / "config.yaml"
        candidate.write_text(yaml.safe_dump(base, allow_unicode=True))
        checked = subprocess.run([settings["mihomoBin"], "-t", "-d", str(state), "-f", str(candidate)],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        if checked.returncode:
            raise ValueError("new configuration rejected")
        write_private(config, candidate.read_bytes())
    print(f"Migrated {len(proxies)} nodes and {len(base['rules'])} rules; DNS/TUN/listeners use new local policy")


def connect_sub_store(settings, legacy):
    state = Path(settings["runtimeDirectory"])
    token = Path("/var/lib/sub-store/api-token").read_text().strip()
    address = settings["subStoreAddress"].rstrip("/")
    prefix = address + "/" + token
    http = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def api(path, body=None):
        request = urllib.request.Request(prefix + path,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Content-Type": "application/json"})
        with http.open(request, timeout=15) as response:
            value = json.load(response)
        if value.get("status") != "success":
            raise ValueError("Sub-Store rejected migration")
        return value.get("data")

    existing = {p["name"] for p in api("/api/subs")}
    profiles = json.loads((legacy / "profiles/index.json").read_text())
    names = []
    for index, profile in enumerate(p for p in profiles if p.get("type") == "remote" and p.get("url")):
        name = f"legacy-{index + 1}"
        url = profile["url"]
        parsed = urllib.parse.urlsplit(url)
        if parsed.port == 18080 and parsed.path.lstrip("/").startswith(("http://", "https://")):
            url = parsed.path.lstrip("/") + ("?" + parsed.query if parsed.query else "")
        if name not in existing:
            api("/api/subs", {"name": name, "source": "remote", "url": url,
                              "ua": profile.get("userAgent") or "clash.meta", "process": []})
        names.append(name)
    if not names:
        raise ValueError("no remote subscriptions to migrate")
    collections = {p["name"] for p in api("/api/collections")}
    if "router" not in collections:
        api("/api/collections", {"name": "router", "subscriptions": names, "process": []})
    source = state / "source-url"
    if not source.exists():
        write_private(source, (prefix + "/download/collection/router?target=Mihomo&noCache=true\n").encode())
        # This explicit root-only migration writes one file for the updater user.
        shutil.chown(source, user="mihomo-router", group="mihomo-router")
    print(f"Connected {len(names)} subscription(s); existing Sub-Store entries preserved")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("settings")
    parser.add_argument("action", choices=["stage", "connect-sub-store"])
    parser.add_argument("--legacy", default="/var/lib/metacubexd")
    parser.add_argument("--backup", required=True, help="Previously created private backup archive")
    args = parser.parse_args()
    if os.geteuid() != 0 or not Path(args.backup).is_file():
        print("Root access and an existing backup are required", file=sys.stderr)
        return 1
    os.umask(0o077)
    try:
        settings = json.loads(Path(args.settings).read_text())
        if args.action == "stage":
            stage(settings, Path(args.legacy))
        else:
            connect_sub_store(settings, Path(args.legacy))
        return 0
    except Exception:
        print("Migration failed; legacy data was not modified", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
