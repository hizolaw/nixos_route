#!/usr/bin/env python3
"""Produce private service links from runtime tokens, never from Nix secrets."""
import json
import os
from pathlib import Path
import sys
import tempfile
from urllib.parse import urlencode, urlsplit


def links(settings):
    result = {}
    for name, kind in (("DASHBOARD_URL", "dashboard"), ("SUB_STORE_URL", "subStore")):
        spec = settings.get(kind)
        if not spec:
            continue
        try:
            token = Path(spec["tokenFile"]).read_text().strip()
        except OSError:
            continue
        # Runtime services currently generate hexadecimal tokens. Reject malformed
        # state instead of accidentally embedding whitespace or a second URL.
        if not token or len(token) > 512 or not all(c.isalnum() or c in "_-" for c in token):
            continue
        origin = spec["origin"].rstrip("/")
        parsed = urlsplit(origin)
        if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password:
            continue
        if kind == "dashboard":
            query = urlencode({"hostname": parsed.hostname, "port": parsed.port or (443 if parsed.scheme == "https" else 80),
                               "protocol": parsed.scheme, "secret": token, "label": "R4S",
                               "disableUpgradeCore": "1"})
            # Zashboard accepts settings in the fragment; no token goes to nginx.
            result[name] = origin + "/#/setup?" + query
        else:
            result[name] = origin + "/?" + urlencode({"api": origin + "/" + token})
    return result


def main():
    os.umask(0o077)
    settings = json.loads(Path(sys.argv[1]).read_text())
    destination = Path(sys.argv[2])
    values = links(settings)
    fd, temporary = tempfile.mkstemp(prefix=".links-", dir=destination.parent)
    try:
        with os.fdopen(fd, "w") as output:
            for key, value in values.items():
                output.write(key + "=" + json.dumps(value) + "\n")
        os.replace(temporary, destination)
    finally:
        Path(temporary).unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("Cannot prepare console service links", file=sys.stderr)
        sys.exit(1)
