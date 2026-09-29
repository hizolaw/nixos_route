# NanoPi R4S (1GB DDR3) 装 NixOS —— 全过程记录

> 目标：在这台 FriendlyElec NanoPi R4S（1GB DDR3 版）上跑起来一个能 SSH 的 NixOS。
> 结论（截至当前）：必须用 FriendlyElec 的 BSP 引导栈（rkbin DDR U-Boot + BSP 内核 6.6.134 + BSP 设备树），主line 内核在这块 1G 板上起不来。

## 硬件事实

- SoC: Rockchip RK3399；内存: **1GB DDR3**（4GB 版是 LPDDR4，两者 DTB 相同但 DDR 初始化不同）。
- 网口: 原生 GMAC (RTL8211E) + PCIe (RTL8111H, r8169)。
- 没有 eMMC、没有 SPI NOR、没有 HDMI；只能从 microSD 启动，调试只能靠 3 针串口（1500000 8N1）或网络。
- LED: PWR(红, 常亮=通电)、SYS(绿, GPIO0_B5, BSP DTB 里默认 heartbeat)、LAN/WAN。

## 关键发现（为什么这么折腾）

1. **主line U-Boot 对 R4S 硬编码了 LPDDR4 的 DDR 参数**
   （`rk3399-nanopi-r4s-u-boot.dtsi` include `rk3399-sdram-lpddr4-100.dtsi`），
   在 1G(DDR3) 上 TPL 阶段 `DRAM init failed`，OpenWrt 官方也明确"1G 版 snapshot 起不来"。
2. **1G 板只能用 rkbin DDR 固件**（`rk3399_ddr_800MHz_v1.24.bin` + miniloader，自动识别 DDR3/LPDDR4）。
   原卡 iStoreOS 的 idbloader 就是这种。
3. **主line 内核 6.18 + 主line DTB 在 1G 板上起不来**（SYS 灯完全没反应）。换成 FriendlyWrt 25.12
   的 BSP 内核 6.6.134 + BSP DTB `rk3399-nanopi4-revXX` 后才成功启动（SYS 灯亮）。
4. **看门狗**：BSP DTB 里 `watchdog@ff848000` (rockchip,rk3399-wdt) 默认开启，NixOS 默认不喂，
   开机几十秒后被复位（"起来又灭"）。修法：`systemd.settings.Manager.RuntimeWatchdogSec = "10s"`。
5. **r8169 会崩**（当前头号嫌疑，未最终确认）：BSP 6.6 内核 + r8169 有已知死机/冻结问题；
   桥接/提前加载 r8169 后系统从"稳定"变成"崩"，现改为只用 eth0 + 黑名单 r8169。

## 能启动的引导栈（当前方案）

- bootloader: 复用原卡 iStoreOS 的 OpenWrt U-Boot 2022.07（卡备份的前 32MiB，`sd-bootloader-32MiB.bin`）。
- 启动方式: `boot.scr`（vendor U-Boot 直接 `booti` 内核+ramdisk+dtb），不走 extlinux。
- 内核: BSP 6.6.134+（从 FriendlyWrt 25.12 的 `kernel` 分区抽的 `bsp-Image`）。
- initramfs: FriendlyWrt 的 cpio ramdisk（`bsp-ramdisk.gz`）。
- DTB: BSP `rk3399-nanopi-r4s`（`bsp-r4s.dtb`，从 `resource` 分区 offset 431104 抽的）。
- root: NixOS ext4（`/dev/mmcblk1p2`），`init=` 指向 systemd。

## 镜像文件（都在本目录）

| 文件 | 说明 |
|---|---|
| `nixos-r4s-sd.img` | NixOS sd 镜像（vendor U-Boot 已拼入，FAT /boot + ext4 root），由 make-image.sh 生成 |
| `nixos-r4s-sd-bsp.img` | **当前要刷的**：上面那张 + BSP 内核/DTB/ramdisk + boot.scr（eth0 静态 .5、r8169 黑名单） |
| `nixos-r4s-sd-rkbin.img` | 早期实验：rkbin + mainline U-Boot 2026.04（废弃） |
| `nixos-r4s-sd-bootscr.img` | 早期实验：mainline 内核 + boot.scr（废弃） |
| `sd-bootloader-32MiB.bin` | 原卡前 32MiB 备份（引导器，唯一的"后悔药"） |

每版 sha256 用 `sha256sum nixos-r4s-sd-bsp.img` 看；刷写命令：
`sudo dd if=nixos-r4s-sd-bsp.img of=/dev/sdX bs=4M status=progress conv=fsync && sync`。

## 配置/脚本

- `r4s.nix` —— NixOS 系统配置（内核仍是主line，但实际跑的是 BSP；含：FAT /boot、BSP 模块 tmpfiles 软链、
  看门狗喂食、journald persistent、`oops=panic panic=10`、eth0 静态 192.168.1.5、r8169 黑名单）。
- `image.nix` —— 供沙箱构建：eval R4S 配置并产出 sdImage。
- `ext4-uboot.nix` —— root 文件系统生成器（去掉 U-Boot 不认的 orphan_file/metadata_csum_seed，后来发现其实无害）。
- `boot-bsp.cmd` → `boot.scr` —— U-Boot 启动脚本（load BSP 内核/ramdisk/DTB 然后 booti）。
- `make-image.sh` —— 把 vendor U-Boot 拼进裸镜像、两个分区都标 bootable。
- `nix-ns-chroot.sh` —— 在 x86 本机用 qemu-user + 私有 store 交叉构建 aarch64（免 root）。

## 构建方法（无 root、无 binfmt 系统改动）

```bash
cd /home/hzluo/Workspace/bot/r4s-nixos
./nix-ns-chroot.sh build --impure --max-jobs 6 --file /work/image.nix --out-link /work/result
```

产出后：`./make-image.sh <result 里的 .img>` 拼引导器 → 再把 BSP 内核/DTB/ramdisk/boot.scr 塞进 FAT → `nixos-r4s-sd-bsp.img`。

## 构建日志对应关系

- `build.log` / `build2-5.log` —— 早期主line 镜像的构建。
- `build-bsp.log` —— 第一次 BSP 引导栈 + 模块(extraModulePackages, 失败)。
- `build-bsp2.log` —— 看门狗喂食 + journald persistent（成功）。
- `build-bsp3.log` —— systemd-networkd 桥接 + r8169 提前加载（成功，但上机崩）。
- `build-bsp4.log` —— 当前：eth0 静态 .5 + r8169 黑名单（构建中/已完成）。

## 未决 / 下一步

1. 确认当前 `nixos-r4s-sd-bsp.img`（eth0 + r8169 黑名单）能不能稳定 + ping 通。
   - 注意：这版**只用原生口 WAN**，网线要插在 WAN 口。
2. 若 eth0 通了 → 恢复第二个口（PCIe）：排查 r8169 崩溃（试 vendor r8168？降内核？）。
3. 若还崩 → 需要串口日志（3 针 UART, 1500000 8N1），journal 在硬复位下留不下来。
4. 稳定后：把 `r4s.nix` 改成真正的路由模式（WAN/LAN 分离 + NAT + DHCP）。
