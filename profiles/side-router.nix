{ config, lib, ... }: {
  imports = [
    ../modules/system/base.nix
    ../modules/system/access.nix
    ../modules/networking/side-router.nix
    ../modules/services/metacubexd.nix
    ../modules/services/subscription-relay.nix
    ../modules/services/udpxy.nix
  ];
  router.network.enable = lib.mkDefault true;
  router.metacubexd = {
    enable = lib.mkDefault true;
    backendURL = lib.mkDefault "http://${config.router.network.address}:${toString config.router.metacubexd.apiPort}";
  };
  router.subscriptionRelay = {
    enable = lib.mkDefault true;
    listenAddress = lib.mkDefault config.router.network.address;
  };
}
