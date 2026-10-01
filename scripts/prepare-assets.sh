#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
target=${ROUTER_ASSETS:?Set ROUTER_ASSETS to an absolute destination}
[[ "$target" = /* ]] || { echo 'ROUTER_ASSETS must be absolute' >&2; exit 1; }
[[ ! -e "$target" ]] || { echo "Destination already exists: $target (use just assets-check)" >&2; exit 1; }
archive="$repo/hardware/nanopi-r4s-ddr3/bsp-assets.tar.xz"
if [[ ! -s "$archive" ]] || head -c 100 "$archive" | grep -q 'version https://git-lfs.github.com/spec/v1'; then
  echo 'BSP archive missing or still an LFS pointer. Run git lfs install && git lfs pull.' >&2
  exit 1
fi
mkdir -p "$(dirname "$target")"
staging=$(mktemp -d "$(dirname "$target")/.r4s-assets.XXXXXX")
# Linux module names can differ only by case (xt_DSCP.ko / xt_dscp.ko).
touch "$staging/.case-check"
if [[ -e "$staging/.CASE-CHECK" ]]; then
  rm "$staging/.case-check"
  rmdir "$staging"
  echo 'Use a case-sensitive filesystem for ROUTER_ASSETS; see README macOS instructions.' >&2
  exit 1
fi
rm "$staging/.case-check"
tar -xJf "$archive" -C "$staging"
bash "$repo/scripts/check-assets.sh" "$staging"
mv "$staging" "$target"
echo "Prepared $target"
