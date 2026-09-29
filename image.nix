# Evaluate the R4S configuration for aarch64-linux and return the SD image
# derivation.  Used from inside the qemu/chroot sandbox (see nix-ns-chroot.sh).
let
  # nixos-26.05 (stable), unpacked
  nixpkgs = /nix/store/3q95vz593xbq4rrpsd3yr6lixsygkhcj-nixexprs.tar.xz;

  evalCfg = import (nixpkgs + "/nixos/lib/eval-config.nix") {
    system = "aarch64-linux";
    modules = [ ./r4s.nix ];
  };
in
evalCfg.config.system.build.sdImage
