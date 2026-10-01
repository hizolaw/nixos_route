{ config, lib, pkgs, modulesPath, routerAssets, ... }: {
  imports = [ "${modulesPath}/installer/sd-card/sd-image.nix" ];
  sdImage = {
    firmwarePartitionOffset = 32;
    firmwareSize = 512;
    compressImage = false;
    populateRootCommands = lib.mkForce "";
    populateFirmwareCommands = lib.mkForce ''
      mkdir -p firmware/bsp
      cp ${routerAssets}/bsp-Image firmware/bsp/Image
      cp ${routerAssets}/bsp-ramdisk.gz firmware/bsp/ramdisk.gz
      cp ${routerAssets}/bsp-r4s.dtb firmware/bsp/rk3399-nanopi-r4s.dtb
      cat > boot.cmd <<EOF
setenv bootargs "console=ttyS2,1500000 net.ifnames=0 root=/dev/mmcblk1p2 rootfstype=ext4 init=${config.system.build.toplevel}/init watchdog.handle_boot_enabled=1 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1"
load mmc 1:1 \''${kernel_addr_r} bsp/Image
load mmc 1:1 \''${ramdisk_addr_r} bsp/ramdisk.gz
setenv ramdisk_size \''${filesize}
load mmc 1:1 \''${fdt_addr_r} bsp/rk3399-nanopi-r4s.dtb
booti \''${kernel_addr_r} \''${ramdisk_addr_r}:\''${ramdisk_size} \''${fdt_addr_r}
EOF
      ${pkgs.ubootTools}/bin/mkimage -A arm -O linux -T script -C none \
        -n "NixOS R4S BSP boot" -d boot.cmd firmware/boot.scr
    '';
    postBuildCommands = ''
      chmod u+w "$img"
      dd if=${routerAssets}/bootloader-32MiB.bin of="$img" \
        bs=512 skip=64 seek=64 count=65472 conv=notrunc status=none
      ${pkgs.util-linux}/bin/sfdisk --activate "$img" 1 2
    '';
  };
}
