# Boot the FriendlyElec BSP kernel + BSP device tree (watchdog ENABLED; fed by
# systemd, matching the working FriendlyWrt firmware) + the FriendlyWrt
# initramfs, then switch-root into the NixOS root.
#
# ramoops/pstore is enabled so that the previous boot's console + panic log
# survives a reset and can be read back from the FAT /boot partition (no UART).
setenv bootargs "console=ttyS2,1500000 net.ifnames=0 root=/dev/mmcblk1p2 rootfstype=ext4 init=/nix/store/1lkibb39y5p4bwjlffn37axlc89kh04q-nixos-system-r4s-24.05.7376.b134951a4c9f/init watchdog.handle_boot_enabled=1"

load mmc 1:1 ${kernel_addr_r} bsp/Image
load mmc 1:1 ${ramdisk_addr_r} bsp/ramdisk.gz
setenv ramdisk_size ${filesize}
load mmc 1:1 ${fdt_addr_r} bsp/rk3399-nanopi-r4s.dtb

booti ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr_r}
