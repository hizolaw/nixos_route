set shell := ["bash", "-euo", "pipefail", "-c"]
host := "r4s-home"
export ROUTER_ASSETS := env_var_or_default("ROUTER_ASSETS", justfile_directory() / "assets/r4s")

default:
    @just --list

# Extract and verify the vendor asset archive downloaded by Git LFS.
assets-prepare:
    bash scripts/prepare-assets.sh

# Check BSP assets against the known-working manifest.
assets-check:
    bash scripts/check-assets.sh

# Evaluate runtime and image independently; no build or deployment.
check: assets-check
    nix eval --impure --raw .#nixosConfigurations.{{host}}.config.system.build.toplevel.drvPath
    nix eval --impure --raw .#packages.aarch64-linux.{{host}}-image.drvPath
    git diff --check

# Requires an aarch64 native/remote builder or configured binfmt emulation.
image: assets-check
    nix build --impure .#packages.aarch64-linux.{{host}}-image --out-link result-image

build: assets-check
    nix build --impure .#nixosConfigurations.{{host}}.config.system.build.toplevel --out-link result-system

# Run on the router; preserve the external asset path through sudo.
boot: assets-check
    sudo env ROUTER_ASSETS="$ROUTER_ASSETS" nixos-rebuild boot --impure --flake .#{{host}}

# Network changes can interrupt SSH: prefer boot when changing network topology.
switch: assets-check
    sudo env ROUTER_ASSETS="$ROUTER_ASSETS" nixos-rebuild switch --impure --flake .#{{host}}

rollback:
    sudo nixos-rebuild switch --rollback

status:
    systemctl status metacubexd mihomo-subscription-relay --no-pager
