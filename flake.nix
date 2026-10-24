{
  description = "Modular NixOS router: runtime configurations and board images";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/b134951a4c9f3c995fd7be05f3243f8ecd65d798";
  inputs.router-console.url = "github:hizolaw/router-console/a311e9d741b17a62515bf29f361ebb218d837228";
  outputs = { self, nixpkgs, router-console }: let
    # Extract the Git LFS archive with `just assets-prepare` before evaluation.
    # The extracted asset directory is supplied explicitly, outside flake source.
    assetsEnv = builtins.getEnv "ROUTER_ASSETS";
    routerAssets = if assetsEnv == "" then
      throw "Set ROUTER_ASSETS to the absolute BSP asset directory; see just assets-check and README.md"
      else builtins.path { path = builtins.toPath assetsEnv; name = "r4s-bsp-assets"; };
    servicePackages = system: import ./packages/proxy-services.nix {
      pkgs = import nixpkgs { inherit system; };
      modernPkgs = import router-console.inputs.nixpkgs { inherit system; };
    };
    runtime = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      specialArgs = { inherit routerAssets; routerServicePackages = servicePackages "aarch64-linux"; };
      modules = [ router-console.nixosModules.default ./hosts/r4s-home ];
    };
    image = runtime.extendModules { modules = [ ./images/nanopi-r4s-ddr3.nix ]; };
  in {
    nixosConfigurations.r4s-home = runtime;
    packages = nixpkgs.lib.genAttrs [ "aarch64-linux" "x86_64-linux" ] (system: {
      router-mihomo = (servicePackages system).mihomo;
      router-zashboard = (servicePackages system).zashboard;
      router-sub-store = (servicePackages system).sub-store;
      router-sub-store-frontend = (servicePackages system).sub-store-frontend;
    } // nixpkgs.lib.optionalAttrs (system == "aarch64-linux") {
      r4s-home-image = image.config.system.build.sdImage;
    });
    nixosModules = {
      router-console = router-console.nixosModules.default;
      side-router = import ./profiles/side-router.nix;
      metacubexd = import ./modules/services/metacubexd.nix;
      subscription-relay = import ./modules/services/subscription-relay.nix;
      mihomo = import ./modules/services/mihomo.nix;
      dns = import ./modules/services/dns.nix;
      sub-store = import ./modules/services/sub-store.nix;
    };
  };
}
