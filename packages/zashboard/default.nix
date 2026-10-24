{ pkgs, dashboard }:
# This deployment serves the controller through the dashboard's own origin.
# Keep credentials empty: users supply the persistent controller secret.
pkgs.runCommand "router-zashboard-${dashboard.version}" { } ''
  mkdir -p "$out"
  cp -r ${dashboard}/. "$out/"
  chmod -R u+w "$out"
  matches=0
  for script in "$out"/assets/index-*.js; do
    if grep -q 'protocol:`http`,host:`127.0.0.1`,port:`9090`' "$script"; then
      substituteInPlace "$script" \
        --replace-fail 'protocol:`http`,host:`127.0.0.1`,port:`9090`' \
        'protocol:window.location.protocol.slice(0,-1),host:window.location.hostname,port:window.location.port||(window.location.protocol===`https:`?`443`:`80`)'
      matches=$((matches + 1))
    fi
  done
  test "$matches" -eq 1
''
