{ config, lib, pkgs, routerAssets, ... }:
let
  bspModules = pkgs.runCommand "bsp-kernel-modules-6.6.134" { } ''
    mkdir -p $out/lib/modules
    cp -r ${routerAssets + "/modules"}/* $out/lib/modules/
  '';

  # The RK3399 watchdog is armed by the bootloader and the BSP dw_wdt driver
  # cannot set its timeout ("No valid TOPs array specified"), so systemd's
  # RuntimeWatchdogSec (which does WDIOC_SETTIMEOUT) is unreliable here.  Feed
  # it directly, every second, without touching the timeout.
  watchdogFeedScript = pkgs.writeShellScript "watchdog-feed" ''
    wdt=""
    while [ -z "$wdt" ]; do
      for d in /dev/watchdog /dev/watchdog0; do
        if [ -c "$d" ]; then wdt="$d"; break; fi
      done
      [ -n "$wdt" ] || sleep 0.2
    done
    exec 3>"$wdt"
    while :; do
      printf '1' >&3 2>/dev/null || true
      sleep 1
    done
  '';

  updateBootScript = pkgs.writeShellScript "update-r4s-boot-script" ''
    set -eu
    system_path="$1"
    cmd="$(${pkgs.coreutils}/bin/mktemp)"
    image="$(${pkgs.coreutils}/bin/mktemp)"
    trap '${pkgs.coreutils}/bin/rm -f "$cmd" "$image"' EXIT
    ${pkgs.coreutils}/bin/cat > "$cmd" <<EOF
setenv bootargs "console=ttyS2,1500000 net.ifnames=0 root=/dev/mmcblk1p2 rootfstype=ext4 init=$system_path/init watchdog.handle_boot_enabled=1 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1"
load mmc 1:1 \''${kernel_addr_r} bsp/Image
load mmc 1:1 \''${ramdisk_addr_r} bsp/ramdisk.gz
setenv ramdisk_size \''${filesize}
load mmc 1:1 \''${fdt_addr_r} bsp/rk3399-nanopi-r4s.dtb
booti \''${kernel_addr_r} \''${ramdisk_addr_r}:\''${ramdisk_size} \''${fdt_addr_r}
EOF
    ${pkgs.ubootTools}/bin/mkimage -A arm -O linux -T script -C none \
      -n "NixOS R4S BSP boot" -d "$cmd" "$image"
    ${pkgs.coreutils}/bin/install -m 0755 "$image" /boot/boot.scr
  '';
in {
  boot.loader.generic-extlinux-compatible = {
    enable = lib.mkForce false;
    configurationLimit = 5;
  };

  # The running kernel is the FriendlyElec BSP 6.6.134+ (mainline does not
  # boot this board), so make its modules visible at /lib/modules/6.6.134+
  # via an activation script.  (boot.extraModulePackages would not work here:
  # it merges module trees and rejects mismatched kernel versions.)
  system.activationScripts.bspModules = ''
    mkdir -p /lib/modules
    ln -sfn ${bspModules}/lib/modules/6.6.134+ /lib/modules/6.6.134+
  '';

  # R4S debug UART: ttyS2 @ 1500000 8N1.  net.ifnames=0 keeps the native GMAC
  # named eth0 (see networking.usePredictableInterfaceNames below).
  boot.kernelParams = lib.mkForce [
    "console=ttyS2,1500000n8"
    "net.ifnames=0"
  ];

  # bcache-tools ships a udev rule referencing /bin/sh, which trips NixOS 24.05's
  # udev sanity check.  The R4S doesn't use bcache, so drop it entirely.
  boot.bcache.enable = false;

  hardware.deviceTree = {
    enable = true;
    name = "rockchip/rk3399-nanopi-r4s.dtb";
  };

  hardware.enableRedistributableFirmware = true;

  systemd.services.watchdog-feed = {
    description = "Feed the RK3399 hardware watchdog";
    wantedBy = [ "multi-user.target" ];
    before = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${watchdogFeedScript}";
      Restart = "always";
      RestartSec = "1";
    };
  };


  boot.loader.grub.enable = false;
  system.build.installBootLoader = updateBootScript;
  fileSystems."/" = { device = "/dev/disk/by-label/NIXOS_SD"; fsType = "ext4"; };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [ "umask=0022" ];
  };
  networking.usePredictableInterfaceNames = false;
}
