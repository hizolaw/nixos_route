# Boot the FriendlyElec BSP kernel + BSP device tree + FriendlyWrt initramfs,
# then switch-root into the NixOS root.  cgroup_enable/swapaccount mirror the
# working FriendlyWrt cmdline (r8169 PCIe probe investigation).
setenv bootargs "console=ttyS2,1500000 net.ifnames=0 root=/dev/mmcblk1p2 rootfstype=ext4 init=/nix/store/9b6cwjgyyawz0jyi4ck9d08z38j3y0dk-nixos-system-r4s-24.05.7376.b134951a4c9f/init watchdog.handle_boot_enabled=1 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1"

load mmc 1:1 ${kernel_addr_r} bsp/Image
load mmc 1:1 ${ramdisk_addr_r} bsp/ramdisk.gz
setenv ramdisk_size ${filesize}
load mmc 1:1 ${fdt_addr_r} bsp/rk3399-nanopi-r4s.dtb

booti ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr_r}
