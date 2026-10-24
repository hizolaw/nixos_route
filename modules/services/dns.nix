{ config, lib, pkgs, ... }:
let
  cfg = config.router.dns;
in {
  options.router.dns = {
    enable = lib.mkEnableOption "independent, direct-upstream DNS resolver";
    listenAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "127.0.0.1" ];
      description = "Explicit local addresses to bind. Add the host's LAN address for clients.";
    };
    upstreamServers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "223.5.5.5" "119.29.29.29" ];
      description = ''
        Literal upstream DNS IP addresses reachable directly. The host must exclude
        this resolver's traffic from transparent proxy interception. Do not point
        these at Mihomo, localhost, or another resolver that forwards back here.
      '';
    };
    filterAAAA = lib.mkOption { type = lib.types.bool; default = false; description = "Suppress AAAA replies when the LAN IPv6 gateway bypasses this router."; };
    port = lib.mkOption {
      type = lib.types.port;
      default = 53;
      description = "DNS UDP and TCP listening port.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.listenAddresses != [] && cfg.upstreamServers != [];
        message = "router.dns requires explicit listen addresses and direct DNS upstreams.";
      }
      {
        assertion = !(config.services.dnsmasq.settings ? dhcp-range);
        message = "router.dns is DNS-only; configure DHCP separately.";
      }
    ];

    environment.systemPackages = [ pkgs.bind.dnsutils ];
    services.dnsmasq = {
      enable = true;
      # The host owns /etc/resolv.conf; never import it as an upstream source.
      resolveLocalQueries = false;
      settings = {
        inherit (cfg) port;
        listen-address = cfg.listenAddresses;
        bind-dynamic = true;
        no-resolv = true;
        server = cfg.upstreamServers;
        cache-size = 2048;
        filter-AAAA = cfg.filterAAAA;
        domain-needed = true;
        bogus-priv = true;
        # No synthetic addresses or proxy-owned forwarding rules.
      };
    };
    systemd.services.dnsmasq.serviceConfig = {
      Restart = lib.mkForce "on-failure";
      RestartSec = "2s";
    };
  };
}
