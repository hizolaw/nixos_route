#!/usr/bin/env bash
# Build aarch64 derivations on this x86_64 laptop, without root and without
# any system-wide binfmt registration.
#
# Layout inside the user namespace:
#   * a private binfmt_misc instance with qemu-aarch64 registered, so any
#     aarch64 ELF (including the Nix builders) runs under emulation;
#   * a private chroot whose /nix/store is a fresh, user-owned store.  The
#     host store paths needed to *run* nix (nix itself, qemu, nixpkgs) are
#     bind-mounted read-only into that store, everything else is downloaded
#     or built into the private store.
#
# Usage:
#   ./nix-ns-chroot.sh build --impure -I nixpkgs=... --expr '...'
#   (the arguments are passed to `nix` inside the chroot)
set -euo pipefail

qemu_user=/nix/store/475vzq8qm85h4a5gqg4srlw8wdzfbi5r-qemu-user-11.0.1
nixpkgs_src=/nix/store/0000000000000000000000000000aaaa-nixos-24.05-nixexprs

# everything (private store, chroot root, logs) stays next to this script
script_dir=$(cd "$(dirname "$0")" && pwd)
base=${R4S_NS_BASE:-$script_dir/.store-root}

if [ "${R4S_IN_NS:-0}" != "1" ]; then
  mkdir -p "$base/nix/store" "$base/nix/var/nix" "$base/tmp" "$base/dev" "$base/proc" \
           "$base/etc/ssl" "$base/out" "$base/work" "$base/nix-root"
  exec unshare -Urm --map-root-user --pid --fork \
    env R4S_IN_NS=1 R4S_NS_BASE="$base" bash "$0" "$@"
fi

nix_bin=$(readlink -f "$(command -v nix)")
nix_store_path=$(dirname "$(dirname "$nix_bin")")

# CA bundle of the host system (needed for the substituters inside the chroot)
ca_bundle=$(readlink -f /etc/ssl/certs/ca-bundle.crt)
ca_store=${ca_bundle%%/etc/*}

# 1. private binfmt_misc + qemu-aarch64 -----------------------------------
mkdir -p /tmp/binfmt-r4s
mount -t binfmt_misc binfmt_misc /tmp/binfmt-r4s 2>/dev/null || true
printf '%s\n' ":qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:${base}${qemu_user}/bin/qemu-aarch64:F" \
  > /tmp/binfmt-r4s/register

# 2. make the pieces needed to run nix itself visible in the chroot ------
# qemu and nixpkgs live *inside* the private store (immune to GC); only the
# host's nix closure and CA bundle need to be bind-mounted from /nix/store.
for p in "$nix_store_path" "$ca_store" \
         $(nix-store -qR "$nix_store_path" "$ca_store"); do
  target="$base$p"
  # already materialised inside the private store (qemu, nixpkgs, …)?
  if [ -e "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then continue; fi
  [ -e "$p" ] || continue
  if [ ! -e "$target" ]; then
    if [ -d "$p" ]; then mkdir -p "$target"; else touch "$target"; fi
  fi
  mountpoint -q "$target" || mount --bind "$p" "$target"
done

[ -e "$base$nixpkgs_src/default.nix" ] || { echo "nixpkgs missing in private store" >&2; exit 1; }
[ -x "$base$qemu_user/bin/qemu-aarch64" ] || { echo "qemu missing in private store" >&2; exit 1; }

# whole /dev (recursively, so /dev/pts and /dev/ptmx work too)
mountpoint -q "$base/dev" || mount --rbind /dev "$base/dev"
mountpoint -q "$base/work" || mount --bind "${R4S_WORKDIR:-$script_dir}" "$base/work"
# fresh pid namespace above, so a real procfs can be mounted here
mount -t proc proc "$base/proc"
cp /etc/resolv.conf "$base/etc/resolv.conf"
mount --bind /etc/ssl/certs "$base/etc/ssl/certs" 2>/dev/null || true
mkdir -p "$base/etc/nix"

# minimal passwd/group/nsswitch: some builders call `id -un`
cat > "$base/etc/passwd" <<EOF
root:x:0:0:root:/nix-root:/noshell
nobody:x:65534:65534:nobody:/:/noshell
EOF
cat > "$base/etc/group" <<EOF
root:x:0:
nogroup:x:65534:
EOF
printf 'hosts: files dns\n' > "$base/etc/nsswitch.conf"
printf '127.0.0.1 localhost\n' > "$base/etc/hosts"

cat > "$base/etc/nix/nix.conf" <<EOF
experimental-features = nix-command flakes
build-users-group =
sandbox = false
extra-platforms = aarch64-linux
require-drop-supplementary-groups = false
ssl-cert-file = $ca_bundle
substituters = https://mirrors.ustc.edu.cn/nix-channels/store https://cache.nixos.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
EOF

# 3. run nix inside the chroot ------------------------------------------
export HOME=/nix-root
export TMPDIR=/tmp
export PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin

if [ "${R4S_DEBUG:-0}" = "1" ]; then
  echo "--- mount table (private ns) ---"; awk '{print $2, $3}' /proc/self/mounts | grep -E "rlnix-root" | head -5
  echo "--- store inside chroot ---"; ls "$base/nix/store" | wc -l
  echo "--- nix path present? ---"; ls -la "$base$nix_store_path/bin/" 2>&1 | head -5
  exit 0
fi

exec chroot "$base" "$nix_bin" "$@"
