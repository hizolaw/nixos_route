{ pkgs }:

let
  mihomoGz = pkgs.fetchurl {
    url = "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.27/mihomo-linux-arm64-v1.19.27.gz";
    hash = "sha256-h9sMZmCpVXqQG1dQ+ZeWfnHYwK8H6h0d1NBMKNp/fm8=";
  };
in
pkgs.runCommand "metacubexd-server-1.273.1" {
  nativeBuildInputs = [ pkgs.makeWrapper pkgs.gzip ];
} ''
  mkdir -p "$out/lib/metacubexd-server" "$out/bin"
  tar -C "$out/lib/metacubexd-server" -xzf ${./metacubexd-server-dist-v1.273.1.tar.gz}
  # The static panel config would shadow the server's dynamic /config.js,
  # preventing the UI from receiving its control token and hiding Profiles.
  rm "$out/lib/metacubexd-server/server/public/config.js"
  sed -i '/^  "\/config.js": {$/,/^  },$/d' \
    "$out/lib/metacubexd-server/server/server/chunks/nitro/nitro.mjs"
  gzip -dc ${mihomoGz} > "$out/bin/mihomo"
  chmod 0555 "$out/bin/mihomo"
  makeWrapper ${pkgs.nodejs_22}/bin/node "$out/bin/metacubexd-server" \
    --add-flags "$out/lib/metacubexd-server/server/server/index.mjs" \
    --set UI_DIST "$out/lib/metacubexd-server/ui-dist" \
    --set MIHOMO_BIN "$out/bin/mihomo"
''
