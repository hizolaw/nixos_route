# NixOS on FriendlyElec NanoPi R4S (Rockchip RK3399, 1GB DDR3 model)
#
# Layout notes:
#   * the first 32 MiB of the microSD keep the board's existing U-Boot
#     (OpenWrt U-Boot 2022.07, which understands extlinux/distro boot),
#     so partitioning starts at 32 MiB and the bootloader is never touched.
#   * /boot lives on the ext4 root partition; U-Boot finds
#     /boot/extlinux/extlinux.conf through its default "/boot/" prefix.
{ config, lib, pkgs, modulesPath, ... }:

let
  sshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIwhLf3GOrAj8BuOZrRGNf3JbCF4aTsoUuk8Xu0X4ivR hzluo@macbook-t2"
  ];

  # Kernel modules of the FriendlyElec BSP kernel 6.6.134+, extracted from
  # the working FriendlyWrt 25.12 firmware.  The running kernel on this board
  # is the BSP kernel (mainline does not boot the 1GB DDR3 R4S), so these are
  # the modules that must be loadable at runtime (r8169, usb, …).
  bspModules = pkgs.runCommand "bsp-kernel-modules-6.6.134" { } ''
    mkdir -p $out/lib/modules
    cp -r ${./ref-fw/modules}/* $out/lib/modules/
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

in
{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
  ];

  # ------------------------------------------------------------------ boot
  boot.loader.generic-extlinux-compatible = {
    enable = true;
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

  # The PCIe RTL8111H (r8169) crashes this BSP 6.6 kernel when its module is
  # loaded (modprobe r8169 hard-hangs the board), so the LAN port cannot be
  # used.  Keep it blacklisted and only use the native GMAC (eth0).
  boot.blacklistedKernelModules = [ "r8169" ];

  # bcache-tools ships a udev rule referencing /bin/sh, which trips NixOS 24.05's
  # udev sanity check.  The R4S doesn't use bcache, so drop it entirely.
  boot.bcache.enable = false;

  hardware.deviceTree = {
    enable = true;
    name = "rockchip/rk3399-nanopi-r4s.dtb";
  };

  hardware.enableRedistributableFirmware = true;

  # ------------------------------------------------------------- SD image
  sdImage = {
    # Leave the first 32 MiB free: that is where the existing U-Boot lives.
    firmwarePartitionOffset = 32;
    # Big enough to hold kernel + initrd + dtbs, because /boot lives here.
    firmwareSize = 512;
    # Put the boot files (kernel, initrd, dtbs, extlinux.conf) on the FAT
    # partition: U-Boot's FAT32 support is completely reliable, and the
    # config lands at /extlinux/extlinux.conf (found via the "/" prefix).
    # A copy under the legacy OpenWrt rollback name is added as well.
    populateFirmwareCommands = lib.mkForce ''
      ${config.boot.loader.generic-extlinux-compatible.populateCmd} \
        -c ${config.system.build.toplevel} -d firmware
      cp firmware/extlinux/extlinux.conf \
         firmware/extlinux/extlinux-rollback.conf
    '';
    # /boot is the FAT partition, so no second copy is needed in the rootfs.
    populateRootCommands = lib.mkForce "";
    # Keep the raw image: it is written to the card directly from this
    # machine, and skipping zstd saves a lot of emulated CPU time.
    compressImage = false;
  };

  # The RK3399 watchdog is fed by a dedicated service (see watchdogFeedScript),
  # not by systemd's RuntimeWatchdogSec: the BSP dw_wdt driver reports
  # "No valid TOPs array specified", so WDIOC_SETTIMEOUT fails and systemd's
  # runtime watchdog is unreliable.  Feed it directly instead.
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

  # Persist the journal so a crash can be diagnosed from the SD card.
  services.journald.storage = "persistent";

  # mount the FAT firmware partition as /boot
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [ "umask=0022" ];
  };

  # A router does not need the NixOS manual or man pages.
  documentation = {
    enable = false;
    man.enable = false;
  };

  # -------------------------------------------------------------- network
  # Only the native GMAC (eth0, WAN port) with a static address.  The PCIe NIC
  # (r8169) is blacklisted above.
  networking = {
    hostName = "r4s";
    useDHCP = false;
    usePredictableInterfaceNames = false;
    interfaces.eth0 = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = "192.168.1.5";
          prefixLength = 24;
        }
      ];
    };
    defaultGateway = "192.168.1.1";
    nameservers = [
      "192.168.1.1"
      "223.5.5.5"
      "119.29.29.29"
    ];
    firewall.enable = true;
  };

  # ---------------------------------------------------------- users / ssh
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
    openFirewall = true;
  };

  users.users.root.openssh.authorizedKeys.keys = sshKeys;

  users.users.nixos = {
    isNormalUser = true;
    description = "nixos";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = sshKeys;
    initialPassword = "nixos";
  };

  # ------------------------------------------------------------------ nix
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    substituters = [
      "https://mirrors.ustc.edu.cn/nix-channels/store"
      "https://cache.nixos.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
  };

  # ----------------------------------------------------------------- misc
  time.timeZone = "Asia/Shanghai";
  i18n.defaultLocale = "en_US.UTF-8";

  environment.systemPackages = with pkgs; [
    curl
    git
    htop
    vim
  ];

  system.stateVersion = "24.05";
}
