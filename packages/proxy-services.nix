{ pkgs, modernPkgs }: {
  mihomo = import ./mihomo { inherit pkgs; };
  zashboard = modernPkgs.zashboard;
  sub-store = modernPkgs.sub-store;
  sub-store-frontend = modernPkgs.sub-store-frontend;
}
