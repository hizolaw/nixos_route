# nix-instantiate --eval --strict tests/proxy-eval.nix --arg nixpkgs /path/to/nixpkgs
{ nixpkgs }:
let
  lib = import (nixpkgs + "/lib");
  evaluate = system: enable: dashboard: (import (nixpkgs + "/nixos/lib/eval-config.nix") {
    inherit system;
    modules = [
      ../modules/services/mihomo.nix
      ../modules/services/sub-store.nix
      ({ pkgs, ... }: {
        system.stateVersion = "24.05";
        # Inspect generated policy and cleanup contents without building packages.
        nixpkgs.overlays = [ (_: previous: {
          writeShellScript = name: text:
            assert name != "mihomo-router-cleanup" || (
              lib.hasInfix "seq 10000 10010" text
              && lib.hasInfix "rule del priority" text
              && lib.hasInfix "route flush table 2033" text
            );
            previous.writeShellScript name text;
          writeText = name: text:
            assert name != "mihomo-router-template.json" || (
              (builtins.fromJSON (builtins.unsafeDiscardStringContext text)).external-controller == "127.0.0.1:19090"
              && (builtins.fromJSON (builtins.unsafeDiscardStringContext text)).tun.iproute2-table-index == 2033
              && (builtins.fromJSON (builtins.unsafeDiscardStringContext text)).tun.iproute2-rule-index == 10000
              && (builtins.fromJSON (builtins.unsafeDiscardStringContext text)).tun.dns-hijack == []
              && (builtins.fromJSON (builtins.unsafeDiscardStringContext text)).dns.enhanced-mode == "redir-host"
            );
            assert name != "mihomo-update-settings.json" || (
              (builtins.fromJSON (builtins.unsafeDiscardStringContext text)).controller == "http://127.0.0.1:19090"
              && (builtins.fromJSON (builtins.unsafeDiscardStringContext text)).subStoreAddress == "http://127.0.0.1:17894"
            );
            previous.writeText name text;
        }) ];
        router.mihomo = {
          inherit enable;
          package = pkgs.hello;
          dashboardPackage = if dashboard then pkgs.hello else null;
          apiPort = 19090;
          dashboardPort = 18080;
          subStoreAddress = "http://127.0.0.1:17894";
        };
        router.subStore = {
          inherit enable;
          package = pkgs.hello;
          frontendPackage = pkgs.hello;
          port = 17894;
        };
      })
    ];
  }).config;
  dependencies = unit:
    unit.after ++ unit.requires ++ unit.wants ++ unit.bindsTo ++ unit.partOf;
  independent = unit: lib.all (dependency:
    !(lib.hasInfix "dnsmasq" dependency)
    && !(lib.hasInfix "mihomo" dependency)
    && !(lib.hasInfix "sub-store" dependency)
  ) (dependencies unit);
  check = system:
    let
      enabled = evaluate system true false;
      disabled = evaluate system false false;
      withDashboard = evaluate system true true;
      mihomo = enabled.systemd.services.mihomo-router;
      subStore = enabled.systemd.services.sub-store;
      update = enabled.systemd.services.mihomo-subscription-update;
      timer = enabled.systemd.timers.mihomo-subscription-update;
      nginx = withDashboard.services.nginx.virtualHosts.router-dashboard;
    in
    assert !(disabled.systemd.services ? mihomo-router);
    assert !(disabled.systemd.services ? mihomo-subscription-update);
    assert !(disabled.systemd.timers ? mihomo-subscription-update);
    assert !(disabled.systemd.services ? sub-store);
    assert !enabled.services.nginx.enable;
    assert lib.hasInfix "mihomo-router-cleanup" mihomo.serviceConfig.ExecStopPost;
    assert lib.hasPrefix "+" mihomo.serviceConfig.ExecStopPost;
    assert lib.hasInfix "mihomo-router-cleanup" (builtins.head mihomo.serviceConfig.ExecStartPre);
    assert mihomo.serviceConfig.AmbientCapabilities == [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];
    assert mihomo.serviceConfig.CapabilityBoundingSet == [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];
    assert independent mihomo && independent subStore && independent update;
    assert lib.all (dependency: !(lib.hasInfix "mihomo" dependency)) timer.requires;
    assert subStore.serviceConfig.User == "sub-store";
    assert subStore.serviceConfig.StateDirectoryMode == "0700";
    assert subStore.serviceConfig.StandardOutput == "null";
    assert subStore.serviceConfig.StandardError == "null";
    assert subStore.environment.SUB_STORE_BACKEND_API_PORT == "17894";
    assert subStore.environment.NODE_OPTIONS == "--max-old-space-size=96";
    assert subStore.environment.SUB_STORE_CORS_ALLOWED_ORIGINS == "http://127.0.0.1:17894";
    assert subStore.serviceConfig.MemoryMax == "192M";
    assert builtins.length nginx.listen == 1;
    assert (builtins.head nginx.listen).addr == "127.0.0.1";
    assert (builtins.head nginx.listen).port == 18080;
    assert nginx.locations."~ ^/(version|configs|proxies|providers|rules|connections|traffic|logs|dns|cache|group)(/|$)".proxyPass == "http://127.0.0.1:19090";
    # Force script derivations, including assertions inspecting generated content.
    builtins.deepSeq (map toString (mihomo.serviceConfig.ExecStartPre ++ [
      update.serviceConfig.ExecStart subStore.serviceConfig.ExecStart
    ])) true;
in {
  aarch64 = check "aarch64-linux";
  x86_64 = check "x86_64-linux";
}
