#!/usr/bin/env bash
# Splice the board's existing bootloader into the freshly built NixOS image.
#
#   * the NixOS image leaves the first 32 MiB empty (sdImage.firmwarePartitionOffset)
#   * sd-bootloader-32MiB.bin is a dump of that same region from the running
#     iStoreOS card, i.e. the U-Boot that is known to boot this exact board
#   * both live at the same absolute offsets (idbloader @ 32 KiB,
#     U-Boot env @ 4 MiB, u-boot.itb @ 8 MiB), so a straight copy works;
#     sector 0 (the partition table) is left untouched.
#
# Usage: ./make-image.sh <raw-nixos-image>
set -euo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
src=${1:?usage: make-image.sh <raw-nixos-image>}
out=$dir/nixos-r4s-sd.img

echo "source image : $src"
echo "output image : $out"

[ -e "$out" ] && chmod u+w "$out"
# NOTE: use a full copy, not reflink.  A reflink + the dd splice below has
# been observed to leave the FAT partition (sector 65536+) zeroed out on some
# filesystems, which yields "non DOS media" and an unbootable card.
cp --reflink=never "$src" "$out"
chmod u+w "$out"

# copy sectors 64 .. 65535 (32 KiB .. 32 MiB) from the bootloader backup
dd if="$dir/sd-bootloader-32MiB.bin" of="$out" \
  bs=512 skip=64 seek=64 count=65472 conv=notrunc status=none

# The U-Boot we keep scans only partitions flagged bootable
# ("part list <dev> <num> -bootable").  Mark the FAT /boot partition active
# as well, so that it is scanned before the ext4 root partition.
sfdisk --activate "$out" 1 2 >/dev/null 2>&1 || true

sync

echo
echo "partition table:"
sfdisk --quiet -d "$out" 2>/dev/null || true
echo
echo "'$out' is ready to be written to the microSD card, e.g."
echo "  sudo dd if=$out of=/dev/sdX bs=4M status=progress conv=fsync"
