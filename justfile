set shell := ["bash", "-euo", "pipefail", "-c"]
host := "r4s-home"
export ROUTER_ASSETS := env_var_or_default("ROUTER_ASSETS", if os() == "macos" { "/Volumes/R4SBuildAssets/r4s" } else { justfile_directory() / "assets/r4s" })
builder_args := if os() == "macos" { "--builders @/etc/nix/machines --max-jobs 0" } else { "" }

default:
    @just --list

# Create/mount the default case-sensitive BSP volume on macOS; no-op on Linux.
assets-mount:
    bash scripts/mount-assets.sh

# Fetch missing LFS assets, extract only when absent, and verify existing assets.
assets-prepare: assets-mount
    if [ -d "$ROUTER_ASSETS" ]; then bash scripts/check-assets.sh; else git lfs pull --include=hardware/nanopi-r4s-ddr3/bsp-assets.tar.xz && bash scripts/prepare-assets.sh; fi

# Check BSP assets against the known-working manifest.
assets-check: assets-mount
    bash scripts/check-assets.sh

# Evaluate runtime and image independently; no build or deployment.
check: assets-check
    nix eval --impure --raw .#nixosConfigurations.{{host}}.config.system.build.toplevel.drvPath
    nix eval --impure --raw .#packages.aarch64-linux.{{host}}-image.drvPath
    git diff --check

# Requires an aarch64 native/remote builder or configured binfmt emulation.
image: assets-prepare
    nix build --impure .#packages.aarch64-linux.{{host}}-image {{builder_args}} --out-link result-image

build: assets-prepare
    nix build --impure .#nixosConfigurations.{{host}}.config.system.build.toplevel {{builder_args}} --out-link result-system

# Run the same asset validation, evaluation and image build as GitHub Actions.
ci-image: assets-prepare
    just host={{host}} check
    just host={{host}} image

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
