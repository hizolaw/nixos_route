# Evaluate the R4S configuration for aarch64-linux and return the SD image
# derivation.  Used from inside the qemu/chroot sandbox (see nix-ns-chroot.sh).
let
  # nixos-24.05 (stable, systemd 255.9 + glibc 2.39, kernel 6.6 era), unpacked
  nixpkgs = /nix/store/0000000000000000000000000000aaaa-nixos-24.05-nixexprs;

  evalCfg = import (nixpkgs + "/nixos/lib/eval-config.nix") {
    system = "aarch64-linux";
    modules = [ ./r4s.nix ];
  };
in
evalCfg.config.system.build.sdImage
