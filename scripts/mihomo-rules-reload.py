#!/usr/bin/env python3
"""Explicitly re-read hand-written rule files; never run at startup or by timer."""
import json
import socket
import sys

try:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(45)
        client.connect(sys.argv[1])
        client.sendall(b'{"action":"reload"}\n')
        response = client.makefile('rb').readline(524289)
    if len(response) > 524288:
        raise ValueError()
    reply = json.loads(response)
    if not reply.get('ok'):
        print('Rule validation or application failed; previous active configuration preserved', file=sys.stderr)
        sys.exit(1)
    print('Rules validated and applied')
except Exception:
    print('Rule management service unavailable', file=sys.stderr)
    sys.exit(1)
