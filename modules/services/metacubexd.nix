{ config, lib, pkgs, ... }:
let
  cfg = config.router.metacubexd;
  metacubexdServer = import ../../packages/metacubexd/default.nix { inherit pkgs; };

  # Seed a persistent MetaCubeXD merge overlay for router-specific settings.
  # It is deliberately created only once: after that the dashboard owns the
  # profile, so edits made in the UI are never reverted on service restart.
  routerLocalOverlay = pkgs.writeText "metacubexd-router-local.yaml" ''
    allow-lan: true
    bind-address: "*"
    # Keep IPv6 support in mihomo, but do not hand AAAA answers to LAN clients.
    # Their IPv6 default route is advertised by the upstream router and would
    # otherwise bypass this IPv4 side-router entirely.
    ipv6: true
    tun:
      enable: true
      stack: system
      auto-route: true
      auto-detect-interface: true
      dns-hijack:
        - any:53
    dns:
      enable: true
      listen: 0.0.0.0:53
      ipv6: false
  '';

  prepareMetacubexd = pkgs.writeShellScript "prepare-metacubexd" ''
    set -eu
    install -d -m 0700 /var/lib/metacubexd/profiles
    if [ ! -s /var/lib/metacubexd/environment ]; then
      umask 077
      control_token="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/base64 | ${pkgs.coreutils}/bin/tr -d '\n=')"
      clash_secret="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/base64 | ${pkgs.coreutils}/bin/tr -d '\n=')"
      {
        echo "CONTROL_TOKEN=$control_token"
        echo "CLASH_SECRET=$clash_secret"
      } > /var/lib/metacubexd/environment
      chmod 0600 /var/lib/metacubexd/environment
    fi
    if [ ! -s /var/lib/metacubexd/active.yaml ]; then
      install -m 0600 ${./mihomo-config.yaml} /var/lib/metacubexd/active.yaml
    fi

    overlay_id="00000000-0000-4000-8000-000000000005"
    overlay_path="/var/lib/metacubexd/profiles/$overlay_id.yaml"
    index_path="/var/lib/metacubexd/profiles/index.json"
    [ -s "$index_path" ] || echo '[]' > "$index_path"
    if ! ${pkgs.jq}/bin/jq -e \
      '.[] | select(.type == "merge" and .name == "router-local")' \
      "$index_path" >/dev/null; then
      install -m 0600 ${routerLocalOverlay} "$overlay_path"
      tmp="$(${pkgs.coreutils}/bin/mktemp /var/lib/metacubexd/profiles/index.json.XXXXXX)"
      ${pkgs.jq}/bin/jq \
        --arg id "$overlay_id" \
        '. + [{id: $id, name: "router-local", type: "merge", enabled: true}]' \
        "$index_path" > "$tmp"
      chmod 0600 "$tmp"
      mv "$tmp" "$index_path"
      touch /var/lib/metacubexd/.router-local-needs-apply
    fi
  '';

  applyMetacubexdSeed = pkgs.writeShellScript "apply-metacubexd-seed" ''
    set -eu
    marker=/var/lib/metacubexd/.router-local-needs-apply
    [ -e "$marker" ] || exit 0

    # The overlay will be picked up on the first future activation even when
    # no base profile exists yet.  If one is active already, recompose it now.
    active_id="$(${pkgs.jq}/bin/jq -r '.activeId // empty' \
      /var/lib/metacubexd/profiles/state.json 2>/dev/null || true)"
    if [ -n "$active_id" ]; then
      control_token="$(${pkgs.gnused}/bin/sed -n 's/^CONTROL_TOKEN=//p' \
        /var/lib/metacubexd/environment)"
      attempt=0
      until ${pkgs.curl}/bin/curl --fail --silent --show-error \
        -X POST -H "Authorization: Bearer $control_token" \
        "http://127.0.0.1:${toString cfg.port}/api/control/profiles/$active_id/activate" \
        >/dev/null; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 30 ] || exit 1
        sleep 1
      done
    fi
    rm -f "$marker"
  '';

  startMetacubexd = pkgs.writeShellScript "start-metacubexd" ''
    set -a
    . /var/lib/metacubexd/environment
    set +a
    exec ${metacubexdServer}/bin/metacubexd-server
  '';


in {
  options.router.metacubexd = {
    enable = lib.mkEnableOption "MetaCubeXD profile manager";
    port = lib.mkOption { type = lib.types.port; default = 8080; };
    apiPort = lib.mkOption { type = lib.types.port; default = 9090; };
    mixedPort = lib.mkOption { type = lib.types.port; default = 7890; };
    backendURL = lib.mkOption { type = lib.types.str; };
  };
  config = lib.mkIf cfg.enable {
  systemd.services.metacubexd = {
    description = "MetaCubeXD profile manager and Mihomo supervisor";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStartPre = prepareMetacubexd;
      ExecStart = startMetacubexd;
      ExecStartPost = applyMetacubexdSeed;
      Environment = [
        "PORT=${toString cfg.port}"
        "CONTROL_PORT=${toString cfg.port}"
        "CLASH_API_PORT=${toString cfg.apiPort}"
        "MIXED_PORT=${toString cfg.mixedPort}"
        "DATA_DIR=/var/lib/metacubexd"
        "DEFAULT_BACKEND_URL=${cfg.backendURL}"
        "TZ=Asia/Shanghai"
      ];
      AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" ];
      CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" ];
      Restart = "on-failure";
      RestartSec = "2s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      StateDirectory = "metacubexd";
      StateDirectoryMode = "0700";
      ReadWritePaths = [ "/var/lib/metacubexd" ];
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_NETLINK" ];
    };
  };

  services.mihomo.enable = false;
  };
}
