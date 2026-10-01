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

  # Browser code cannot override the User-Agent header.  Some subscription
  # servers return an empty response unless it identifies as a Clash client,
  # so provide a LAN-only relay for dashboard subscription imports.
  # Usage: http://192.168.1.5:18080/http://provider.example/subscribe?token=...
  subscriptionRelay = pkgs.writeText "mihomo-subscription-relay.py" ''
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from urllib.error import HTTPError, URLError
    from urllib.request import Request, urlopen

    class Handler(BaseHTTPRequestHandler):
        def do_OPTIONS(self):
            self.send_response(204)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
            self.end_headers()

        def do_GET(self):
            target = self.path.lstrip("/")
            if not target.startswith(("http://", "https://")):
                self.send_error(400, "prefix the subscription URL with this relay URL")
                return
            try:
                request = Request(target, headers={"User-Agent": "clash.meta"})
                with urlopen(request, timeout=30) as upstream:
                    body = upstream.read()
                    self.send_response(upstream.status)
                    for name in ("Content-Type", "Content-Disposition",
                                 "Subscription-Userinfo", "Profile-Update-Interval"):
                        value = upstream.headers.get(name)
                        if value:
                            self.send_header(name, value)
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("Access-Control-Allow-Origin", "*")
                    self.end_headers()
                    self.wfile.write(body)
            except HTTPError as error:
                self.send_error(error.code, str(error.reason))
            except (URLError, TimeoutError, ValueError) as error:
                self.send_error(502, str(error))

        def log_message(self, format, *args):
            print("%s - %s" % (self.client_address[0], format % args), flush=True)

    ThreadingHTTPServer(("192.168.1.5", 18080), Handler).serve_forever()
  '';

  metacubexdServer = import ./metacubexd-server.nix { inherit pkgs; };

  # Seed a persistent MetaCubeXD merge overlay for router-specific settings.
  # It is deliberately created only once: after that the dashboard owns the
  # profile, so edits made in the UI are never reverted on service restart.
  routerLocalOverlay = pkgs.writeText "metacubexd-router-local.yaml" ''
    allow-lan: true
    bind-address: "*"
    # Keep IPv6 support in mihomo, but do not hand AAAA answers to LAN clients.
    # Their IPv6 default route is advertised by the upstream router and would
    # otherwise bypass this IPv4 side-router entirely.
    ipv6: true
    tun:
      enable: true
      stack: system
      auto-route: true
      auto-detect-interface: true
      dns-hijack:
        - any:53
    dns:
      enable: true
      listen: 0.0.0.0:53
      ipv6: false
  '';

  prepareMetacubexd = pkgs.writeShellScript "prepare-metacubexd" ''
    set -eu
    install -d -m 0700 /var/lib/metacubexd/profiles
    if [ ! -s /var/lib/metacubexd/environment ]; then
      umask 077
      control_token="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/base64 | ${pkgs.coreutils}/bin/tr -d '\n=')"
      clash_secret="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/base64 | ${pkgs.coreutils}/bin/tr -d '\n=')"
      {
        echo "CONTROL_TOKEN=$control_token"
        echo "CLASH_SECRET=$clash_secret"
      } > /var/lib/metacubexd/environment
      chmod 0600 /var/lib/metacubexd/environment
    fi
    if [ ! -s /var/lib/metacubexd/active.yaml ]; then
      install -m 0600 ${./mihomo-config.yaml} /var/lib/metacubexd/active.yaml
    fi

    overlay_id="00000000-0000-4000-8000-000000000005"
    overlay_path="/var/lib/metacubexd/profiles/$overlay_id.yaml"
    index_path="/var/lib/metacubexd/profiles/index.json"
    [ -s "$index_path" ] || echo '[]' > "$index_path"
    if ! ${pkgs.jq}/bin/jq -e \
      '.[] | select(.type == "merge" and .name == "router-local")' \
      "$index_path" >/dev/null; then
      install -m 0600 ${routerLocalOverlay} "$overlay_path"
      tmp="$(${pkgs.coreutils}/bin/mktemp /var/lib/metacubexd/profiles/index.json.XXXXXX)"
      ${pkgs.jq}/bin/jq \
        --arg id "$overlay_id" \
        '. + [{id: $id, name: "router-local", type: "merge", enabled: true}]' \
        "$index_path" > "$tmp"
      chmod 0600 "$tmp"
      mv "$tmp" "$index_path"
      touch /var/lib/metacubexd/.router-local-needs-apply
    fi
  '';

  applyMetacubexdSeed = pkgs.writeShellScript "apply-metacubexd-seed" ''
    set -eu
    marker=/var/lib/metacubexd/.router-local-needs-apply
    [ -e "$marker" ] || exit 0

    # The overlay will be picked up on the first future activation even when
    # no base profile exists yet.  If one is active already, recompose it now.
    active_id="$(${pkgs.jq}/bin/jq -r '.activeId // empty' \
      /var/lib/metacubexd/profiles/state.json 2>/dev/null || true)"
    if [ -n "$active_id" ]; then
      control_token="$(${pkgs.gnused}/bin/sed -n 's/^CONTROL_TOKEN=//p' \
        /var/lib/metacubexd/environment)"
      attempt=0
      until ${pkgs.curl}/bin/curl --fail --silent --show-error \
        -X POST -H "Authorization: Bearer $control_token" \
        "http://127.0.0.1:8080/api/control/profiles/$active_id/activate" \
        >/dev/null; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 30 ] || exit 1
        sleep 1
      done
    fi
    rm -f "$marker"
  '';

  startMetacubexd = pkgs.writeShellScript "start-metacubexd" ''
    set -a
    . /var/lib/metacubexd/environment
    set +a
    exec ${metacubexdServer}/bin/metacubexd-server
  '';

  updateBootScript = pkgs.writeShellScript "update-r4s-boot-script" ''
    set -eu
    system_path="$(${pkgs.coreutils}/bin/readlink -f /nix/var/nix/profiles/system)"
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

  systemd.services.mihomo-subscription-relay = {
    description = "LAN subscription relay with a Clash-compatible User-Agent";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${subscriptionRelay}";
      DynamicUser = true;
      Restart = "on-failure";
      RestartSec = "2s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
    };
  };

  systemd.services.metacubexd = {
    description = "MetaCubeXD profile manager and Mihomo supervisor";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStartPre = prepareMetacubexd;
      ExecStart = startMetacubexd;
      ExecStartPost = applyMetacubexdSeed;
      Environment = [
        "PORT=8080"
        "CONTROL_PORT=8080"
        "CLASH_API_PORT=9090"
        "MIXED_PORT=7890"
        "DATA_DIR=/var/lib/metacubexd"
        "DEFAULT_BACKEND_URL=http://192.168.1.5:9090"
        "TZ=Asia/Shanghai"
      ];
      AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" ];
      CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" ];
      Restart = "on-failure";
      RestartSec = "2s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      StateDirectory = "metacubexd";
      StateDirectoryMode = "0700";
      ReadWritePaths = [ "/var/lib/metacubexd" ];
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_NETLINK" ];
    };
  };

  systemd.services.r4s-boot-script = {
    description = "Keep the R4S U-Boot script on the current NixOS profile";
    wantedBy = [ "multi-user.target" ];
    after = [ "boot.mount" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = updateBootScript;
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
  # 旁路由：两个网口桥接成一个 br0，同属上游 192.168.1.0/24；本机网关仍是
  # 192.168.1.1。不开 DHCP，其它机器把网关/路由指到 192.168.1.5 即可经它上网。
  networking = {
    hostName = "r4s";
    useDHCP = false;
    usePredictableInterfaceNames = false;
    bridges.br0.interfaces = [ "eth0" "eth1" ];
    interfaces = {
      eth0.useDHCP = false;
      eth1 = {
        useDHCP = false;
        macAddress = "a2:fe:c3:06:8f:79";
      };
      br0 = {
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
    # 旁路由要转发 LAN 过来的流量，关掉防火墙避免拦截
    firewall.enable = false;
  };

  # 开启 IPv4 转发，让其它机器经本机路由上网
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  # MetaCubeXD Server owns the mihomo process and persists profiles, schedules,
  # active configuration and caches under /var/lib/metacubexd.
  services.mihomo.enable = false;

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
