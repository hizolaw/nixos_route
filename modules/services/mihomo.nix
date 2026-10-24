{ config, lib, pkgs, ... }:
let
  cfg = config.router.mihomo;
  state = "/var/lib/mihomo-router";
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  cncidr = import ../../packages/mihomo/cncidr.nix { inherit pkgs; };
  policy = {
    mixed-port = cfg.mixedPort;
    allow-lan = true;
    bind-address = cfg.listenAddress;
    external-controller = "127.0.0.1:${toString cfg.apiPort}";
    mode = "rule";
    log-level = "warning";
    ipv6 = false;
    profile.store-selected = true;
    sniffer = {
      enable = true;
      force-dns-mapping = true;
      parse-pure-ip = true;
      override-destination = true;
      sniff = { TLS.ports = [ 443 8443 ]; HTTP = { ports = [ 80 "8080-8880" ]; override-destination = true; }; QUIC.ports = [ 443 8443 ]; };
      skip-domain = [ "+.lan" "+.local" ];
    };
    tun = {
      enable = true;
      device = "router-tun";
      stack = "system";
      auto-route = true;
      auto-redirect = false;
      strict-route = false;
      auto-detect-interface = true;
      iproute2-table-index = cfg.routeTable;
      iproute2-rule-index = cfg.rulePriority;
      dns-hijack = [ ];
      route-exclude-address = cfg.routeExcludes;
    };
    dns = {
      enable = true;
      listen = "127.0.0.1:1053";
      enhanced-mode = "redir-host";
      ipv6 = false;
      nameserver = cfg.bootstrapServers;
      default-nameserver = cfg.bootstrapServers;
      proxy-server-nameserver = cfg.bootstrapServers;
      direct-nameserver = cfg.bootstrapServers;
    };
    rule-providers.cncidr = {
      type = "file"; behavior = "ipcidr"; format = "yaml";
      path = "${state}/rules/cncidr.yaml";
    };
    proxy-providers.subscription = {
      type = "file";
      path = "${state}/providers/subscription.yaml";
      health-check = { enable = true; url = "https://www.gstatic.com/generate_204"; interval = 300; lazy = true; };
    };
    proxy-groups = [
      { name = "节点选择"; type = "select"; proxies = [ "自动选择" "DIRECT" ]; use = [ "subscription" ]; }
      { name = "自动选择"; type = "url-test"; use = [ "subscription" ]; url = "https://www.gstatic.com/generate_204"; interval = 300; tolerance = 50; lazy = true; }
      { name = "故障回退"; type = "fallback"; proxies = [ "节点选择" "DIRECT" ]; url = "https://www.gstatic.com/generate_204"; interval = 60; lazy = false; }
    ];
    rules = [
      "DOMAIN-SUFFIX,lan,DIRECT" "DOMAIN-SUFFIX,local,DIRECT"
      "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve" "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve"
      "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve" "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve"
      "DOMAIN-SUFFIX,cn,DIRECT" "RULE-SET,cncidr,DIRECT,no-resolve" "MATCH,故障回退"
    ];
  };
  template = pkgs.writeText "mihomo-router-template.json" (builtins.toJSON policy);
  cleanup = pkgs.writeShellScript "mihomo-router-cleanup" ''
    set -eu
    # This table and eleven priorities are reserved exclusively for this service.
    for family in -4 -6; do
      for priority in $(${pkgs.coreutils}/bin/seq ${toString cfg.rulePriority} ${toString (cfg.rulePriority + 10)}); do
        while ${pkgs.iproute2}/bin/ip "$family" rule del priority "$priority" 2>/dev/null; do :; done
      done
      ${pkgs.iproute2}/bin/ip "$family" route flush table ${toString cfg.routeTable} 2>/dev/null || true
    done
  '';
  prepare = pkgs.writeText "mihomo-router-prepare.py" ''
    import json, os, pathlib, secrets, shutil
    os.umask(0o077)
    state = pathlib.Path("${state}")
    (state / "providers").mkdir(parents=True, exist_ok=True)
    (state / "rules").mkdir(exist_ok=True)
    if not (state / "rules/cncidr.yaml").exists():
        shutil.copyfile("${cncidr}", state / "rules/cncidr.yaml")
    secret = state / "controller-secret"
    if not secret.exists():
        secret.write_text(secrets.token_hex(32) + "\n")
    # Seed missing files only. Existing profile data and UI selections survive.
    config = state / "config.yaml"
    if not config.exists():
        value = json.loads(pathlib.Path("${template}").read_text())
        value["secret"] = secret.read_text().strip()
        config.write_text(json.dumps(value, ensure_ascii=False))
    provider = state / "providers/subscription.yaml"
    if not provider.exists():
        provider.write_text(json.dumps({"proxies": [{"name": "直连初始节点", "type": "direct"}]}))
    environment = state / "environment"
    environment.write_text("CLASH_SECRET=" + secret.read_text().strip() + "\n")
  '';
  updaterSettings = pkgs.writeText "mihomo-update-settings.json" (builtins.toJSON {
    baseConfigPath = "${state}/config.yaml";
    runtimeDirectory = state;
    mihomoBin = lib.getExe cfg.package;
    controller = "http://127.0.0.1:${toString cfg.apiPort}";
    secretFile = "${state}/controller-secret";
    sourceFile = "${state}/source-url";
    statusFile = "/var/lib/router-status/subscription.json";
    subStoreAddress = cfg.subStoreAddress;
    serviceActiveCommand = [ "${pkgs.systemd}/bin/systemctl" "is-active" "mihomo-router.service" ];
  });
  migrationSettings = pkgs.writeText "mihomo-migrate-settings.json" (builtins.toJSON {
    runtimeDirectory = state;
    baseTemplatePath = template;
    cncidrAsset = cncidr;
    mihomoBin = lib.getExe cfg.package;
    subStoreAddress = cfg.subStoreAddress;
  });
  migrate = pkgs.writeShellScriptBin "mihomo-migrate" ''
    exec ${python}/bin/python3 ${../../scripts/mihomo-migrate.py} ${migrationSettings} "$@"
  '';
  update = pkgs.writeShellScriptBin "mihomo-subscription-update" ''
    exec ${python}/bin/python3 ${../../scripts/mihomo-update.py} ${updaterSettings}
  '';
in {
  options.router.mihomo = {
    enable = lib.mkEnableOption "standalone fail-open Mihomo";
    package = lib.mkOption { type = lib.types.package; default = import ../../packages/mihomo { inherit pkgs; }; };
    dashboardPackage = lib.mkOption { type = lib.types.nullOr lib.types.package; default = null; };
    listenAddress = lib.mkOption { type = lib.types.str; default = "127.0.0.1"; };
    mixedPort = lib.mkOption { type = lib.types.port; default = 7890; };
    apiPort = lib.mkOption { type = lib.types.port; default = 9090; };
    dashboardPort = lib.mkOption { type = lib.types.port; default = 8080; };
    routeTable = lib.mkOption { type = lib.types.ints.between 1000 32000; default = 2033; };
    rulePriority = lib.mkOption { type = lib.types.ints.between 1000 32000; default = 10000; };
    bootstrapServers = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ "223.5.5.5" "119.29.29.29" ]; };
    routeExcludes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "127.0.0.0/8" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "169.254.0.0/16" ]
        ++ map (server: "${server}/${if lib.hasInfix ":" server then "128" else "32"}") cfg.bootstrapServers;
    };
    subStoreAddress = lib.mkOption { type = lib.types.str; default = "http://127.0.0.1:17893"; };
    updateCalendar = lib.mkOption { type = lib.types.str; default = "*-*-* 04:00:00"; };
  };
  config = lib.mkIf cfg.enable {
    assertions = [ { assertion = !(config.router.metacubexd.enable or false); message = "Disable router.metacubexd before enabling standalone Mihomo."; } ];
    users.groups.mihomo-router = { };
    users.groups.router-status = { };
    users.users.mihomo-router = { isSystemUser = true; group = "mihomo-router"; };
    systemd.tmpfiles.rules = [ "d /var/lib/router-status 2750 mihomo-router router-status -" ];
    environment.systemPackages = [ update migrate ];
    systemd.services.mihomo-router = {
      description = "Mihomo proxy with independent LAN DNS";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        User = "mihomo-router"; Group = "mihomo-router";
        StateDirectory = "mihomo-router"; StateDirectoryMode = "0700";
        WorkingDirectory = state; UMask = "0077";
        ExecStartPre = [ "+${cleanup}" "${python}/bin/python3 ${prepare}" "${lib.getExe cfg.package} -t -d ${state} -f ${state}/config.yaml" ];
        ExecStart = "${lib.getExe cfg.package} -d ${state} -f ${state}/config.yaml";
        ExecStopPost = "+${cleanup}";
        Restart = "on-failure"; RestartSec = "5s"; TimeoutStopSec = "15s";
        AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];
        NoNewPrivileges = true; ProtectSystem = "strict"; ProtectHome = true; PrivateTmp = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
        MemoryMax = "256M";
      };
    };
    systemd.services.mihomo-subscription-update = {
      description = "Validate and update only Mihomo subscription nodes";
      after = [ "network.target" ];
      serviceConfig = {
        Type = "oneshot"; User = "mihomo-router"; Group = "mihomo-router";
        UMask = "0077"; ExecStart = "${update}/bin/mihomo-subscription-update";
        StateDirectory = "mihomo-router"; StateDirectoryMode = "0700";
        ProtectSystem = "strict"; ProtectHome = true; PrivateTmp = true;
        ReadWritePaths = [ state "/var/lib/router-status" ];
        NoNewPrivileges = true;
        TimeoutStartSec = "120s";
      };
    };
    systemd.timers.mihomo-subscription-update = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = cfg.updateCalendar; Persistent = true; RandomizedDelaySec = "5m"; };
    };
    services.nginx = lib.mkIf (cfg.dashboardPackage != null) {
      enable = true;
      virtualHosts.router-dashboard = {
        listen = [ { addr = cfg.listenAddress; port = cfg.dashboardPort; } ];
        root = toString cfg.dashboardPackage;
        extraConfig = "access_log off;";
        locations."/".tryFiles = "$uri $uri/ /index.html";
        locations."~ ^/(version|configs|proxies|providers|rules|connections|traffic|logs|dns|cache|group)(/|$)" = {
          proxyPass = "http://127.0.0.1:${toString cfg.apiPort}";
          proxyWebsockets = true;
          extraConfig = "proxy_read_timeout 1h;";
        };
        locations."/upgrade".extraConfig = "return 403;";
        locations."/restart".extraConfig = "return 403;";
      };
    };
  };
}
