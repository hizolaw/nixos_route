# nix-instantiate --eval --strict tests/dns-eval.nix --arg nixpkgs /path/to/nixpkgs
{ nixpkgs }:
let
  lib = import (nixpkgs + "/lib");
  evaluate = system: enable: (import (nixpkgs + "/nixos/lib/eval-config.nix") {
    inherit system;
    modules = [ ../modules/services/dns.nix {
      system.stateVersion = "24.05";
      router.dns = {
        inherit enable;
        listenAddresses = [ "127.0.0.1" "192.0.2.5" ];
      };
    } ];
  }).config;
  check = system:
    let
      enabled = evaluate system true;
      disabled = evaluate system false;
      dns = enabled.services.dnsmasq;
      unit = enabled.systemd.services.dnsmasq;
    in
    assert dns.enable && !dns.resolveLocalQueries;
    assert lib.elem true (lib.toList dns.settings.no-resolv);
    assert lib.elem true (lib.toList dns.settings.bind-dynamic);
    assert dns.settings.listen-address == [ "127.0.0.1" "192.0.2.5" ];
    assert dns.settings.server == [ "223.5.5.5" "119.29.29.29" ];
    assert !(dns.settings ? dhcp-range);
    assert enabled.networking.nameservers == [];
    assert lib.all (dependency: !(lib.hasInfix "mihomo" dependency))
      (unit.after ++ unit.requires ++ unit.wants ++ unit.bindsTo ++ unit.partOf);
    assert !disabled.services.dnsmasq.enable;
    assert !(disabled.systemd.services ? dnsmasq);
    true;
in {
  aarch64 = check "aarch64-linux";
  x86_64 = check "x86_64-linux";
}
