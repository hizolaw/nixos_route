#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
target=${ROUTER_ASSETS:?Set ROUTER_ASSETS to an absolute destination}
[[ "$target" = /* ]] || { echo 'ROUTER_ASSETS must be absolute' >&2; exit 1; }
[[ ! -e "$target" ]] || { echo "Destination already exists: $target (use just assets-check)" >&2; exit 1; }
for file in bsp-Image bsp-ramdisk.gz bsp-r4s.dtb; do
  test -s "$repo/ref-fw/$file"
done
test -d "$repo/ref-fw/modules"
test -s "$repo/sd-bootloader-32MiB.bin"
mkdir -p "$(dirname "$target")"
staging=$(mktemp -d "$(dirname "$target")/.r4s-assets.XXXXXX")
cp -a "$repo/ref-fw/modules" "$staging/modules"
cp "$repo/ref-fw/bsp-Image" "$repo/ref-fw/bsp-ramdisk.gz" "$repo/ref-fw/bsp-r4s.dtb" "$staging/"
cp "$repo/sd-bootloader-32MiB.bin" "$staging/bootloader-32MiB.bin"
bash "$repo/scripts/check-assets.sh" "$staging"
mv "$staging" "$target"
echo "Prepared $target"
