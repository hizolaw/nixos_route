#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "${1:-${ROUTER_ASSETS:?Set ROUTER_ASSETS}}"
sha256sum --strict -c "$repo/hardware/nanopi-r4s-ddr3/assets.sha256" --quiet
digest=$(find modules -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum)
test "${digest%% *}" = 6757c58c32ca0fea2458b16ae993c56080c5bb1dd1f7636ccdc0e6760313b7c8 || {
  echo 'BSP module tree checksum mismatch' >&2; exit 1;
}
