# Boot the FriendlyElec BSP kernel + BSP device tree + the FriendlyWrt
# initramfs (proven on this board), then switch-root into the NixOS root.
setenv bootargs "console=ttyS2,1500000 net.ifnames=0 root=/dev/mmcblk1p2 rootfstype=ext4 init=/nix/store/v9k87kgwrflbnbazhrfyvbd7m4s3g0dd-nixos-system-r4s-sd-card-26.05.10620.f5c082a40f75/init"

load mmc 1:1 ${kernel_addr_r} bsp/Image
load mmc 1:1 ${ramdisk_addr_r} bsp/ramdisk.gz
setenv ramdisk_size ${filesize}
load mmc 1:1 ${fdt_addr_r} bsp/rk3399-nanopi-r4s.dtb

booti ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr_r}
