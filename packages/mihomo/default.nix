{ pkgs }:
let
  targets = {
    aarch64-linux = { arch = "arm64"; hash = "sha256-h9sMZmCpVXqQG1dQ+ZeWfnHYwK8H6h0d1NBMKNp/fm8="; };
    x86_64-linux = { arch = "amd64"; hash = "sha256-+z40xVhE84n/VGeeWjrsMx1ew4AGwg+NzEdvtHdopY8="; };
  };
  target = targets.${pkgs.stdenv.hostPlatform.system} or
    (throw "Mihomo: unsupported architecture ${pkgs.stdenv.hostPlatform.system}");
  archive = pkgs.fetchurl {
    url = "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.27/mihomo-linux-${target.arch}-v1.19.27.gz";
    inherit (target) hash;
  };
in pkgs.runCommand "mihomo-1.19.27" {
  nativeBuildInputs = [ pkgs.gzip ];
  meta = { mainProgram = "mihomo"; platforms = builtins.attrNames targets; };
} ''
  mkdir -p $out/bin
  gzip -dc ${archive} > $out/bin/mihomo
  chmod 0555 $out/bin/mihomo
''
