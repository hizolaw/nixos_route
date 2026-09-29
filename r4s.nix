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

  # R4S debug UART: ttyS2 @ 1500000 8N1.
  # (mkForce drops the aarch64 sd-image defaults for ttyS0/ttyAMA0/tty0, so
  # any other kernel parameter has to be listed here explicitly -- including
  # net.ifnames=0 from networking.usePredictableInterfaceNames below.)
  boot.kernelParams = lib.mkForce [
    "console=ttyS2,1500000n8"
    "net.ifnames=0"
    "oops=panic"
    "panic=10"
  ];

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
    # U-Boot 2022.07 cannot read ext4 with orphan_file/metadata_csum_seed.
    rootFilesystemCreator = ./ext4-uboot.nix;
    # Keep the raw image: it is written to the card directly from this
    # machine, and skipping zstd saves a lot of emulated CPU time.
    compressImage = false;
  };

  # The BSP kernel enables the RK3399 watchdog (snps,dw-wdt in the device
  # tree); FriendlyWrt feeds it via a userspace daemon, NixOS does not by
  # default, so the board resets shortly after boot.  Have systemd feed it.
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "10s";
  };

  # Persist the journal so a crash can be diagnosed from the SD card.
  services.journald.storage = "persistent";

  # mount the FAT firmware partition as /boot
  fileSystems."/boot/firmware".enable = lib.mkForce false;
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
  # Same setup as before the switch-over: both ethernet ports bridged,
  # static 192.168.1.5/24 via 192.168.1.1.  This keeps the box reachable.
  networking = {
    hostName = "r4s";
    useDHCP = false;
    usePredictableInterfaceNames = false;
    bridges."br-lan".interfaces = [ "eth0" "eth1" ];
    interfaces = {
      eth0.macAddress = "a2:fe:c3:06:8f:78";
      eth1.macAddress = "a2:fe:c3:06:8f:79";
      br-lan = {
        useDHCP = false;
        ipv4.addresses = [
          {
            address = "192.168.1.5";
            prefixLength = 24;
          }
        ];
      };
    };
    defaultGateway = "192.168.1.1";
    nameservers = [
      "192.168.1.1"
      "223.5.5.5"
      "119.29.29.29"
    ];
    firewall.enable = true;
  };

  # Boot-time network diagnostic written to the FAT /boot partition so it
  # can be read back from the SD card (mtools) without a serial console.
  systemd.services.r4s-diag = {
    wantedBy = [ "multi-user.target" ];
    path = with pkgs; [ iproute2 bridge-utils util-linux systemd ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      exec > /boot/r4s-diag.txt 2>&1
      echo "=== r4s-diag $(date -Is) ==="
      uname -a
      echo "--- net modules ---"
      grep -iE "r8169|stmmac|dwmac|realtek" /proc/modules
      echo "--- /sys/class/net ---"
      ls -l /sys/class/net
      echo "--- ip link ---"
      ip link
      echo "--- ip addr ---"
      ip addr
      echo "--- ip route ---"
      ip route
      echo "--- bridge ---"
      brctl show 2>&1
      echo "--- network units ---"
      systemctl --no-pager status network-setup.service 2>&1 | head -30
      echo "--- boot journal (tail) ---"
      journalctl -b --no-pager -n 80 2>&1
      sync
    '';
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

  system.stateVersion = "26.05";
}
