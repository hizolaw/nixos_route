#!/usr/bin/env bash
# Turn the freshly built NixOS aarch64 SD image into a bootable NanoPi R4S card.
#
# The NixOS sd-image leaves the first 32 MiB free (for U-Boot) and its FAT
# partition is empty in 24.05, so this script:
#   1. splices in the known-good bootloader (rkbin idbloader + OpenWrt U-Boot),
#   2. formats the FAT /boot partition,
#   3. drops in the BSP kernel + DTB + FriendlyWrt initramfs + boot.scr.
#
# Usage: ./assemble.sh <raw-nixos-image>
set -euo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
src=${1:?usage: assemble.sh <raw-nixos-image>}
out=$dir/nixos-r4s-sd.img

# 1. bootloader splice (sectors 64..65535)
echo "splicing bootloader…"
cp --reflink=never "$src" "$out"
chmod u+w "$out"
dd if="$dir/sd-bootloader-32MiB.bin" of="$out" bs=512 skip=64 seek=64 count=65472 conv=notrunc status=none
sfdisk --activate "$out" 1 2 >/dev/null 2>&1 || true

# 2+3. build a FAT32 firmware partition and populate it
FW=$(mktemp)
truncate -s 512M "$FW"
mkfs.vfat -n FIRMWARE -i 2178694e "$FW" >/dev/null 2>&1

mmd -i "$FW" "::/bsp"
mcopy -i "$FW" "$dir/ref-fw/bsp-Image"      "::/bsp/Image"
mcopy -i "$FW" "$dir/ref-fw/bsp-ramdisk.gz" "::/bsp/ramdisk.gz"
mcopy -i "$FW" "$dir/ref-fw/bsp-r4s.dtb"    "::/bsp/rk3399-nanopi-r4s.dtb"
mcopy -i "$FW" "$dir/boot.scr"              "::/boot.scr"

# write it at sector 65536 (32 MiB), where the FAT partition starts
dd if="$FW" of="$out" bs=512 seek=65536 conv=notrunc status=none
rm -f "$FW"

sync
echo "'$out' is ready:"
echo "  sudo dd if=$out of=/dev/sdX bs=4M status=progress conv=fsync"
