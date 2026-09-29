# U-Boot script: boot the NixOS mainline kernel/initrd/dtb directly,
# bypassing extlinux.  Loaded from the FAT partition (p1, mmc 1:1).
setenv bootargs "init=/nix/store/l3k61bpybimlwr783waihg5ngq47r7rg-nixos-system-r4s-sd-card-26.05.10620.f5c082a40f75/init console=ttyS2,1500000n8 net.ifnames=0"

load mmc 1:1 ${kernel_addr_r} nixos/nxj7vzg83q8zh2gydrc77a2a5553hmq5-linux-6.18.53-Image
load mmc 1:1 ${ramdisk_addr_r} nixos/g1p06hm50lqcy7p1n8p767fdzxqg5krp-initrd-linux-6.18.53-initrd
setenv ramdisk_size ${filesize}
load mmc 1:1 ${fdt_addr_r} nixos/nxj7vzg83q8zh2gydrc77a2a5553hmq5-linux-6.18.53-dtbs/rockchip/rk3399-nanopi-r4s.dtb

booti ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr_r}
