{ config, lib, pkgs, ... }:
let
  cfg = config.router.udpxy;
  package = pkgs.callPackage ../../packages/udpxy { };
in {
  options.router.udpxy = {
    enable = lib.mkEnableOption "IPTV UDP multicast to HTTP relay";
    listenAddress = lib.mkOption {
      type = lib.types.str;
      description = "LAN IPv4 address to bind; do not expose to the Internet.";
    };
    multicastInterface = lib.mkOption {
      type = lib.types.str;
      description = "IPv4 multicast interface; use the bridge when the ingress port is enslaved.";
    };
    port = lib.mkOption { type = lib.types.port; default = 4022; };
    maxClients = lib.mkOption { type = lib.types.ints.between 1 5000; default = 16; };
  };
  config = lib.mkIf cfg.enable {
    systemd.services.udpxy = {
      description = "IPTV multicast to HTTP relay";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = lib.escapeShellArgs [
          "${package}/bin/udpxy" "-T" "-S"
          "-a" cfg.listenAddress "-p" (toString cfg.port)
          "-m" cfg.multicastInterface "-c" (toString cfg.maxClients)
        ];
        DynamicUser = true;
        Restart = "on-failure";
        RestartSec = "3s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_UNIX" ];
      };
    };
  };
}
