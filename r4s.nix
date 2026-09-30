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

  # systemd generator: run as early as possible and dump the kernel log (which,
  # with systemd.log_target=kmsg, contains systemd's own early-boot messages)
  # plus the mount table to the FAT /boot partition, so a crash before sysinit
  # can be read back from the SD card without a serial console.
  r4sGenScript = pkgs.writeShellScript "r4s-gen-dmesg" ''
    export PATH=${pkgs.util-linux}/bin:${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:$PATH
    mkdir -p /run/r4s-gen
    for i in 1 2 3 4 5 6 7 8 9 10; do
      if mount -t vfat /dev/mmcblk1p1 /run/r4s-gen 2>/dev/null; then
        {
          echo "=== r4s generator $(date -Is 2>/dev/null || echo n/a) ==="
          echo "--- dmesg tail ---"
          dmesg 2>/dev/null | tail -140
          echo "--- mounts ---"
          mount 2>/dev/null | grep -E "mmcblk|overlay|/boot|/nix|/proc|/sys|/dev|/run|cgroup"
        } > /run/r4s-gen/gen-dmesg.txt 2>&1
        sync
        umount /run/r4s-gen
        break
      fi
      sleep 1
    done
    exit 0
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
    "ramoops.mem_address=0x20000000"
    "ramoops.mem_size=0x100000"
    "ramoops.record_size=0x20000"
    "ramoops.console_size=0x80000"
  ];

  # The PCIe RTL8111H (r8169) is a prime crash suspect on this BSP kernel.
  # For diagnosis, keep it out of the picture entirely: only the native
  # GMAC (eth0) is used.
  boot.blacklistedKernelModules = [ "r8169" ];

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

  # The RK3399 watchdog is fed by a dedicated service (see watchdogFeedScript),
  # not by systemd's RuntimeWatchdogSec: the BSP dw_wdt driver reports
  # "No valid TOPs array specified", so WDIOC_SETTIMEOUT fails and systemd's
  # runtime watchdog is unreliable.  Feed it directly instead.
  systemd.services.watchdog-feed = {
    description = "Feed the RK3399 hardware watchdog";
    wantedBy = [ "sysinit.target" ];
    before = [ "sysinit.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${watchdogFeedScript}";
      Restart = "always";
      RestartSec = "1";
    };
  };

  # Dump the kernel log (which includes systemd's kmsg output) from a systemd
  # *generator* — this runs before any unit, so it catches crashes that happen
  # during early boot / generator / unit-loading, before sysinit.target.
  systemd.generators.r4s-dmesg = r4sGenScript;

  # Capture how far systemd gets before the board dies.  Writes a marker +
  # dmesg + mount/cgroup state to the FAT /boot partition as early as sysinit,
  # so the failure point can be read back from the SD card without a UART.
  systemd.services.r4s-early-log = {
    description = "Write early-boot diagnostic to /boot";
    wantedBy = [ "sysinit.target" ];
    before = [ "sysinit.target" ];
    after = [ "systemd-udevd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /run/earlymnt
      if mount -t vfat /dev/mmcblk1p1 /run/earlymnt 2>/dev/null; then
        {
          echo "=== r4s-early-log ==="
          echo "systemd reached sysinit"
          echo "--- dmesg tail ---"
          dmesg | tail -80
          echo "--- systemd units failed ---"
          systemctl --no-pager list-units --state=failed 2>&1 | head -20
          echo "--- mounts ---"
          mount | grep -E "mmcblk|overlay|/boot|/nix" | head -20
          echo "--- cgroup ---"
          ls -la /sys/fs/cgroup 2>/dev/null
        } > /run/earlymnt/early-log.txt 2>&1
        sync
        umount /run/earlymnt
      fi
    '';
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
  # Minimal setup for diagnosis: only the native GMAC (eth0, WAN port) with a
  # static address.  The PCIe NIC (r8169) is blacklisted above.
  networking = {
    hostName = "r4s";
    useDHCP = false;
    usePredictableInterfaceNames = false;
    interfaces.eth0 = {
      useDHCP = false;
      macAddress = "a2:fe:c3:06:8f:78";
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

  # Dump the previous boot's pstore/ramoops console to the FAT /boot partition
  # so a crash can be read back from the SD card without a serial console.
  systemd.services.r4s-pstore = {
    wantedBy = [ "multi-user.target" ];
    before = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if [ -d /sys/fs/pstore ]; then
        mkdir -p /boot/pstore
        cp -a /sys/fs/pstore/. /boot/pstore/ 2>/dev/null || true
        sync
      fi
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
