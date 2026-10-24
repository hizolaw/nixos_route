{ config, lib, ... }: {
  imports = [
    ../modules/system/base.nix
    ../modules/system/access.nix
    ../modules/networking/side-router.nix
    ../modules/services/metacubexd.nix
    ../modules/services/subscription-relay.nix
    ../modules/services/dns.nix
    ../modules/services/mihomo.nix
    ../modules/services/sub-store.nix
    ../modules/services/udpxy.nix
  ];
  router.network.enable = lib.mkDefault true;
  router.metacubexd = {
    enable = lib.mkDefault false;
    backendURL = lib.mkDefault "http://${config.router.network.address}:${toString config.router.metacubexd.apiPort}";
  };
  router.dns.enable = lib.mkDefault true;
  router.mihomo.enable = lib.mkDefault true;
  router.subStore.enable = lib.mkDefault true;
  router.subscriptionRelay = {
    enable = lib.mkDefault false;
    listenAddress = lib.mkDefault config.router.network.address;
  };
}
