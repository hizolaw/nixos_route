{ config, lib, pkgs, routerServicePackages, ... }:
let
  launchSettings = pkgs.writeText "router-console-links.json" (builtins.toJSON {
    dashboard = if config.router.mihomo.enable && config.router.mihomo.dashboardPackage != null then {
      origin = "http://${config.router.network.address}:${toString config.router.mihomo.dashboardPort}";
      tokenFile = "/var/lib/mihomo-router/controller-secret";
    } else null;
    subStore = if config.router.subStore.enable then {
      origin = config.router.subStore.publicURL;
      tokenFile = "/var/lib/sub-store/api-token";
    } else null;
  });
in {
  imports = [ ../../hardware/nanopi-r4s-ddr3 ../../profiles/side-router.nix ];
  networking.hostName = "r4s";
  router.network = {
    interfaces = [ "eth0" "eth1" ];
    address = "192.168.1.5";
    gateway = "192.168.1.1";
    nameservers = [ "127.0.0.1" "223.5.5.5" "119.29.29.29" ];
  };
  networking.interfaces.eth1.macAddress = "a2:fe:c3:06:8f:79";
  router.udpxy = {
    enable = true;
    listenAddress = "192.168.1.5";
    # Physical WAN eth0 is a member of br0; IPv4/IGMP belongs to the bridge.
    multicastInterface = "br0";
  };
  router.dns = {
    listenAddresses = [ "127.0.0.1" config.router.network.address ];
    filterAAAA = true;
  };
  router.mihomo = {
    package = routerServicePackages.mihomo;
    bootstrapServers = config.router.dns.upstreamServers;
    dashboardPackage = routerServicePackages.zashboard;
    listenAddress = config.router.network.address;
    subStoreAddress = "http://127.0.0.1:${toString config.router.subStore.port}";
  };
  router.subStore = {
    package = routerServicePackages.sub-store;
    frontendPackage = routerServicePackages.sub-store-frontend;
    publicURL = "http://${config.router.network.address}:${toString config.router.subStore.port}";
  };
  # A switch can restart static address setup while network.target stays active.
  systemd.services.nginx = lib.mkIf config.services.nginx.enable { after = [ "network-setup.service" ]; };
  systemd.services.mihomo-router = lib.mkIf config.router.mihomo.enable { after = [ "network-setup.service" ]; };
  services.nginx.enable = lib.mkIf config.router.subStore.enable true;
  services.nginx.virtualHosts.sub-store = lib.mkIf config.router.subStore.enable {
    listen = [ { addr = config.router.network.address; port = config.router.subStore.port; } ];
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.router.subStore.port}";
      proxyWebsockets = true;
    };
    extraConfig = "access_log off; error_log /dev/null crit;";
  };
  systemd.services.router-console-links = lib.mkIf config.services.router-console.enable {
    description = "Prepare private console service launch links";
    after = [ "mihomo-router.service" "sub-store.service" ];
    before = [ "router-console.service" ];
    serviceConfig = {
      Type = "oneshot"; RemainAfterExit = true;
      RuntimeDirectory = "router-console-links"; RuntimeDirectoryMode = "0700";
      UMask = "0077";
      ExecStart = "${pkgs.python3}/bin/python3 ${../../scripts/console-links.py} ${launchSettings} /run/router-console-links/environment";
      ProtectSystem = "strict"; ProtectHome = true; PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };
  systemd.services.router-console = {
    after = [ "mihomo-router.service" "router-console-links.service" ];
    requires = [ "router-console-links.service" ];
    serviceConfig.SupplementaryGroups = [ "router-status" ];
  };
  services.router-console = {
    enable = true;
    listenAddress = config.router.network.address;
    port = 9080;
    environmentFiles = [ "-/var/lib/mihomo-router/environment" "/run/router-console-links/environment" ];
    settings = {
      title = "R4S · Router Console";
      plugins = [
        { id = "system"; name = "系统资源"; kind = "system"; interval_secs = 5; }
        {
          id = "dns"; name = "局域网 DNS"; kind = "dns";
          enabled = config.router.dns.enable;
          dns_server = "${config.router.network.address}:53";
          dns_name = "www.baidu.com";
        }
        {
          id = "mihomo"; name = "Mihomo API"; kind = "http";
          enabled = config.router.mihomo.enable;
          probe_url = "http://127.0.0.1:${toString config.router.mihomo.apiPort}/version";
          token_env = "CLASH_SECRET";
          url_env = "DASHBOARD_URL";
          url = "http://${config.router.network.address}:${toString config.router.mihomo.dashboardPort}";
        }
        {
          id = "dashboard"; name = "Zashboard"; kind = "http";
          url_env = "DASHBOARD_URL";
          enabled = config.router.mihomo.enable && config.router.mihomo.dashboardPackage != null;
          probe_url = "http://${config.router.network.address}:${toString config.router.mihomo.dashboardPort}/";
          url = "http://${config.router.network.address}:${toString config.router.mihomo.dashboardPort}";
        }
        {
          id = "subscription"; name = "订阅更新"; kind = "subscription";
          url_env = "SUB_STORE_URL";
          enabled = config.router.mihomo.enable;
          status_file = "/var/lib/router-status/subscription.json";
          url = "http://${config.router.network.address}:${toString config.router.subStore.port}/";
        }
        {
          id = "sub-store"; name = "Sub-Store"; kind = "http";
          url_env = "SUB_STORE_URL";
          enabled = config.router.subStore.enable;
          probe_url = "http://127.0.0.1:${toString config.router.subStore.port}/";
          url = "http://${config.router.network.address}:${toString config.router.subStore.port}/";
        }
        {
          id = "udpxy"; name = "udpxy"; kind = "http";
          enabled = config.router.udpxy.enable;
          probe_url = "http://${config.router.network.address}:${toString config.router.udpxy.port}/status";
          url = "http://${config.router.network.address}:${toString config.router.udpxy.port}/status";
        }
      ];
    };
  };
  router.access.sshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIwhLf3GOrAj8BuOZrRGNf3JbCF4aTsoUuk8Xu0X4ivR hzluo@macbook-t2"
  ];
  system.stateVersion = "24.05";
}
