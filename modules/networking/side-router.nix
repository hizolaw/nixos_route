{ config, lib, ... }:
let cfg = config.router.network;
in {
  options.router.network = {
    enable = lib.mkEnableOption "IPv4 side router";
    interfaces = lib.mkOption { type = lib.types.listOf lib.types.str; };
    address = lib.mkOption { type = lib.types.str; };
    prefixLength = lib.mkOption { type = lib.types.ints.between 0 32; default = 24; };
    gateway = lib.mkOption { type = lib.types.str; };
    nameservers = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ cfg.gateway "223.5.5.5" "119.29.29.29" ]; };
  };
  config = lib.mkIf cfg.enable {
    networking.useDHCP = false;
    networking.bridges.br0.interfaces = cfg.interfaces;
    networking.interfaces = lib.genAttrs cfg.interfaces (_: { useDHCP = false; }) // {
      br0.ipv4.addresses = [{ address = cfg.address; prefixLength = cfg.prefixLength; }];
    };
    networking.defaultGateway = cfg.gateway;
    networking.nameservers = cfg.nameservers;
    # Preserves the existing trusted-LAN deployment; not a WAN firewall policy.
    networking.firewall.enable = false;
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  };
}
