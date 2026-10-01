{
  description = "Modular NixOS router: runtime configurations and board images";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/b134951a4c9f3c995fd7be05f3243f8ecd65d798";
  outputs = { self, nixpkgs }: let
    # Extract the Git LFS archive with `just assets-prepare` before evaluation.
    # The extracted asset directory is supplied explicitly, outside flake source.
    assetsEnv = builtins.getEnv "ROUTER_ASSETS";
    routerAssets = if assetsEnv == "" then
      throw "Set ROUTER_ASSETS to the absolute BSP asset directory; see just assets-check and README.md"
      else builtins.path { path = builtins.toPath assetsEnv; name = "r4s-bsp-assets"; };
    runtime = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      specialArgs = { inherit routerAssets; };
      modules = [ ./hosts/r4s-home ];
    };
    image = runtime.extendModules { modules = [ ./images/nanopi-r4s-ddr3.nix ]; };
  in {
    nixosConfigurations.r4s-home = runtime;
    packages.aarch64-linux.r4s-home-image = image.config.system.build.sdImage;
    nixosModules = {
      side-router = import ./profiles/side-router.nix;
      metacubexd = import ./modules/services/metacubexd.nix;
      subscription-relay = import ./modules/services/subscription-relay.nix;
    };
  };
}
