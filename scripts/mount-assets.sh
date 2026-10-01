#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" = Darwin ]] || exit 0
# A custom asset directory is managed by the caller.
[[ "${ROUTER_ASSETS:?}" = /Volumes/R4SBuildAssets/r4s ]] || exit 0
mountpoint=/Volumes/R4SBuildAssets
image_path="$HOME/Document/r4s-build-assets.sparseimage"
if mount | grep -F " on $mountpoint (" >/dev/null; then
  exit 0
fi
if [[ -e "$mountpoint" ]]; then
  echo "$mountpoint exists but is not mounted; refusing to use it as a volume." >&2
  exit 1
fi
if [[ ! -e "$image_path" ]]; then
  mkdir -p "$(dirname "$image_path")"
  hdiutil create -size 2g -type SPARSE -fs 'Case-sensitive APFS' \
    -volname R4SBuildAssets "$image_path"
fi
hdiutil attach "$image_path" -mountpoint "$mountpoint" -nobrowse
