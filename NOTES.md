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
   开机几十秒后被复位（"SYS 亮一会又灭"）。FriendlyWrt 是**开着看门狗 + userspace 喂**（procd），
   所以能一直闪。把 watchdog 节点 `status="disabled"`（build-bsp5）**反而更糟**：如果 U-Boot/ATF
   已经把它启动，内核不认它 → 没人喂 → 照样复位。正确姿势是**保持 enabled + systemd 喂**。
5. **r8169 疑崩（未最终确认）**：BSP 6.6 内核 + r8169 有已知死机/冻结嫌疑。诊断版先黑名单
   r8169、只用原生 GMAC(eth0)，把它从变量里排除。

## 能启动的引导栈（当前方案）

- bootloader: 复用原卡 iStoreOS 的 OpenWrt U-Boot 2022.07（卡备份的前 32MiB，`sd-bootloader-32MiB.bin`）。
- 启动方式: `boot.scr`（vendor U-Boot 直接 `booti` 内核+ramdisk+dtb），不走 extlinux。
- 内核: BSP 6.6.134+（从 FriendlyWrt 25.12 的 `kernel` 分区抽的 `bsp-Image`）。
- initramfs: FriendlyWrt 的 cpio ramdisk（`bsp-ramdisk.gz`）。
- DTB: BSP `rk3399-nanopi-r4s`（`bsp-r4s.dtb` 叠加 `disable-watchdog.dtbo` → `bsp-r4s-nowdt.dtb`，
  看门狗已关）。
- root: NixOS ext4（`/dev/mmcblk1p2`），`init=` 指向 systemd。

## 镜像文件（都在本目录）

| 文件 | 说明 |
|---|---|
| `nixos-r4s-sd.img` | NixOS sd 镜像（vendor U-Boot 已拼入，FAT /boot + ext4 root），由 make-image.sh 生成 |
| `nixos-r4s-sd-bsp.img` | 上一版：无看门狗 DTB + br-lan 桥接 eth0+eth1（**上机会灭，废弃**） |
| `nixos-r4s-sd-diag.img` | **当前诊断版**：看门狗 enabled+systemd 喂、eth0 单口、r8169 黑名单、ramoops/pstore 抓崩溃日志 |
| `nixos-r4s-sd-rkbin.img` | 早期实验：rkbin + mainline U-Boot 2026.04（废弃） |
| `nixos-r4s-sd-bootscr.img` | 早期实验：mainline 内核 + boot.scr（废弃） |
| `sd-bootloader-32MiB.bin` | 原卡前 32MiB 备份（引导器，唯一的"后悔药"） |

每版 sha256 用 `sha256sum nixos-r4s-sd-bsp.img` 看；刷写命令：
`sudo dd if=nixos-r4s-sd-bsp.img of=/dev/sdX bs=4M status=progress conv=fsync && sync`。

## 配置/脚本

- `r4s.nix` —— NixOS 系统配置（内核仍是主line，但实际跑的是 BSP；含：FAT /boot、BSP 模块 tmpfiles 软链、
  看门狗喂食（兜底）、journald persistent、`oops=panic panic=10`、br-lan 桥接 eth0+eth1 静态 192.168.1.5）。
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
- `build-bsp4.log` —— 实验：eth0 静态 .5 + r8169 黑名单。
- `build-bsp5.log` —— 关看门狗 DTB + net.ifnames=0 + 双口桥接 + r4s-diag（上机仍灭）。
- `build-bsp6.log` —— **当前诊断版**：看门狗 enabled + eth0 单口 + r8169 黑名单 + ramoops/pstore。

## 未决 / 下一步

1. 刷 `nixos-r4s-sd-diag.img`（看门狗 enabled+喂、eth0 单口、r8169 黑名单、ramoops），网线插
   **WAN 口（原生 GMAC/eth0）**。预期：SYS 一直闪不再灭、`ping 192.168.1.5` 通。
2. 若还灭 → 插卡回笔记本挂 `/dev/sda1` 读 `/boot/r4s-diag.txt` 和 `/boot/pstore/`，把内容发我；
   pstore 会存下上次崩溃的 console/panic 日志，不用串口也能定位。
4. 稳定后：把 `r4s.nix` 改成真正的路由模式（WAN/LAN 分离 + NAT + DHCP）。

## 关键进展：崩溃发生在极早期（activation 之前）

读回卡后确认：ext4 根分区里**只有 /nix，没有 /etc、/var**，FAT 里也没有
`r4s-diag.txt`。说明系统在 **NixOS activation 之前**就死了（systemd 还没建
/etc、/var，更没到 multi-user）。LED 亮=内核已起，随后灭=内核级 crash/reset。

为抓日志，改了两个点：
- r4s.nix 加 `r4s-pstore`（multi-user 前 dump /sys/fs/pstore），但对这么早的
  崩溃没用（根本到不了 multi-user）。
- **initramfs 层 dump**：改 FriendlyWrt ramdisk 的 `/init`，在 `switch_root` 前
  就把 `/sys/fs/pstore/*` 挂 FAT(`/dev/mmcblk1p1`) 拷到 `/boot/pstore/`。这样
  无论崩得多早，下次开机（自动重启或手动断电重开）都会把上次崩溃日志落盘。

复现：`ref-fw/bsp-ramdisk-diag.gz`（原 `bsp-ramdisk.gz` + /init 里加 pstore dump）。

## 已确认：看门狗复位循环（5-10s 一次）

用户反馈：SYS 灭掉后**会自己再亮、循环**，上电到灭约 **5-10s**。结合 pstore
为空（无 panic）→ 结论是 **U-Boot 启动的 RK3399 看门狗**在极早期复位，systemd
还没喂到就超时了。

修法：在 initramfs 的 `/init` 里，`mount devtmpfs` 后立刻后台循环
`printf '1' > /dev/watchdog`（每 1s 喂一次），把 U-Boot 到 systemd 之间的空档
补上；systemd 侧 `RuntimeWatchdogSec` 继续在 switch_root 后接管。

镜像 `nixos-r4s-sd-diag.img` sha256 `1b93ae9ba19cdb5b034287fdbf4a7d4507f56d60a084672bdf2f0839fbde011e`。

## 追加：initramfs 喂狗没止住，加双保险 + 诊断

initramfs 喂狗后仍复位。此版：
- bootargs 加 `watchdog.handle_boot_enabled=1`（让内核在 dw_wdt probe 时自动喂）；
- initramfs 喂 /dev/watchdog 或 /dev/watchdog0，并把 `/dev/watchdog*`、
  `/sys/class/watchdog/*`、`dmesg` 落盘到 `/boot/boot-diag.txt`，pstore 照旧。

镜像 `nixos-r4s-sd-diag.img` sha256 `347df12ff96b2427270f054fd799cf13873f2c78d86862b9ef3f50c9d44b3777`。

## 抓到了：dw_wdt "No valid TOPs array specified"

`boot-diag.txt` 关键行：
- `/dev/watchdog`、`/dev/watchdog0` 都在，`dw_wdt ff848000.watchdog` probe 成功；
- **`dw_wdt: No valid TOPs array specified`** —— BSP DTB 没 `snps,watchdog-tops`，
  dw_wdt 无法设超时（WDIOC_SETTIMEOUT 失败），所以 systemd 的 RuntimeWatchdogSec
  不可靠；
- `watchdog: watchdog0: watchdog did not stop!` —— 这只狗一旦被 U-Boot 启动就停不掉。

修法：去掉 `RuntimeWatchdogSec`，改成自写的 `watchdog-feed` 服务——直接
`exec 3>/dev/watchdog` 后每秒 `printf '1' >&3` 喂，不碰超时；配合
`watchdog.handle_boot_enabled=1` + initramfs 喂狗，全程无缝喂。

镜像 `nixos-r4s-sd-diag.img` sha256 `4870c994d08e6613eb0025b5b19670177c6d6ec17a31ca826fc6d5bbcf9bed98`。

## 喂狗没止住：崩在 systemd 极早期（activation 之前）

读回卡：ext4 根仍然只有 /nix（无 /etc、/var），无 journal、无 panic。说明
watchdog 喂上之后，systemd 还是在 **activation 之前**就挂了/被复位。加诊断：
- r4s.nix 加 `r4s-early-log`：sysinit 前把 dmesg / failed units / mounts /
  cgroup 写到 `/boot/early-log.txt`；
- bootargs 加 `systemd.log_target=kmsg systemd.log_level=debug`，让 systemd
  日志进内核 log，能被 dmesg/ramoops 看到。

另：make-image.sh 的 `cp --reflink=auto` + dd splice 会把 FAT 分区（sector
65536+）清零，改成 `--reflink=never`。

镜像 `nixos-r4s-sd-diag.img` sha256 `596ea1bacdc451da2079c3b0f59dd125a94006a7390bddf6ec9c0cb8ed67af67`。

## 加：把 systemd 早期输出重定向到 /boot/systemd.log

`early-log.txt` 没生成 → systemd 在 sysinit 之前就死了（连 early-log 服务都没
跑）。为了看到它到底怎么死的，改 initramfs 的 /init：
- switch_root 前把 FAT 挂到 `${rootmnt}/boot`（新根里的 /boot）；
- `exec run-init ... >${rootmnt}/boot/systemd.log 2>&1`，把 systemd 的 stdout/
  stderr 落到 FAT。这样"run-init 失败"或"systemd 启动即崩"都能留下痕迹。

镜像 `nixos-r4s-sd-diag.img` sha256 `f4e66e2ef575bfa453424cd33039fab8845af2a5203747467c85224c5f94a149`。

## 抓到根因方向：FriendlyWrt initramfs 会 auto-resize 根分区

读卡发现 sda2 根上没有任何 `/boot`、`/etc`（我加在 exec 前的 `mkdir /boot` 都没
落盘），说明 initramfs 没走到最后，卡在根挂载之后的 auto-resize。
FriendlyWrt 的 `/scripts/local` 里 `local_mount_root` 会：umount 根 →
`parted resizepart` + `resize2fs -f`（因为 `/etc/fs.resized` 标记在 NixOS 根上
永远建不出来，所以每次开机都跑），在大卡上容易卡死/慢。

修法：改 `scripts/local` 跳过 resize，直接 `mount -o remount,rw`。

镜像 `nixos-r4s-sd-diag.img` sha256 `bf98eb010de8eeb01aa38cab14bc44d773957440d8b885d298ae70b0c65d8287`。

## 真凶：NixOS 根没有 /dev，exec 的 `<${rootmnt}/dev/console` 重定向失败

`boot-marker.txt` 显示三个标记都到了（after-mountroot / before-init-check /
before-exec），根也挂载成功（EXT4 ro→rw）。但 exec 前 `mkdir /boot` 没落盘 →
exec 那行没执行成功。

原因：initramfs 的 `/scripts/init-bottom/udev` 里 `mount --move /dev
${rootmnt}/dev` 因为 NixOS 根只有 /nix（没有 /dev 目录）而失败，导致
`${rootmnt}/dev/console` 不存在，`exec run-init ... <${rootmnt}/dev/console`
重定向失败 → initramfs panic。

修法：
- udev 脚本里 `mkdir -p ${rootmnt}/dev` 再 move；
- exec 那行 stdin 改成 `</dev/null`（不依赖新根的 /dev/console）。

镜像 `nixos-r4s-sd-diag.img` sha256 `77f6ca9a9298ff06ef26b4042b2a7abb3127acb8ccb6a79a2c22b389886ee375`。

## systemd 起来了，卡在 machine-id 之后 / activation 之前

读卡确认 systemd 已挂载 /proc /sys /dev /run，写了 /etc/machine-id，但
/etc/os-release、/var 还没有 → 崩在 generator / 早期 unit / sysinit 之前。
加 systemd generator `r4s-dmesg`：开机最早期把 dmesg（含 systemd kmsg 输出）
和 mount 表落到 FAT 的 /boot/gen-dmesg.txt。

镜像 `nixos-r4s-sd-diag.img` sha256 `b343029ead68d597422a614dd39c67e432d9036d1ff984148af52231c950ed7e`。

## 换 NixOS 24.05（systemd 255.9 + glibc 2.39 + bash stage2 init）

绕开 systemd 260 与 BSP 6.6 内核的兼容问题，改用 NixOS 24.05：
- init 是 bash 脚本（NixOS stage 2），先跑 activation 再 exec systemd，兼容性更好；
- 修复 24.05 构建：`boot.bcache.enable=false`（bcache-tools 的 udev 规则引用 /bin/sh 会卡构建）；
- 移除 26.05 专属的 sdImage.rootFilesystemCreator、fileSystems."/boot/firmware"。

镜像 `nixos-r4s-sd-diag.img` sha256 `79b99d99ee04206d227897cba19ac9538d1c4b369fc817027cf8ce6441ce9444`。

## 24.05 成功启动到 multi-user；修 watchdog-feed ordering + 去掉 eth0 MAC

journal 确认 systemd 255.9 起来到 multi-user（r4s-diag 跑起来了）。但
watchdog-feed.service 因 ordering cycle 被删（没喂狗）、eth0 有 40-eth0.link
unpredictable name 警告。修：wantedBy 改 multi-user、去掉 eth0 macAddress。
另 24.05 sd-image 的 FAT 是空的，需手动 mkfs.vfat 后再 mcopy BSP 文件。

镜像 `nixos-r4s-sd-diag.img` sha256 `9d27fb437fff0c3148feb21fedd2874645d9790836d9fc299a9cd505001fcdeb`。

## ✅ 成功：NixOS 24.05 跑起来了

ping 通、SSH 通（root@192.168.1.5）。确认：
- 内核 BSP 6.6.134+，systemd 255.9（NixOS 24.05）；
- eth0 UP 192.168.1.5/24，root 分区已扩容到 59G；
- watchdog-feed.service active（看门狗有喂，不再复位）；
- 唯一 failed 是 r4s-diag.service（首启 /boot 曾被 remount-ro，无碍）。

结论：1G DDR3 的 R4S 走「rkbin DDR + OpenWrt U-Boot + BSP 内核 + FriendlyWrt
initramfs + NixOS 24.05(systemd 255.9)」可稳定启动。systemd 260(26.05) 才是
不兼容的源头。

## 清理成正式可用版

去掉 r4s-diag / r4s-pstore / r4s-early-log / r4s-dmesg generator / ramoops /
oops=panic 等诊断；initramfs 只留「喂狗 + 跳过 resize + 补 /dev + 原始 exec」。
新增 assemble.sh 一键拼引导器 + 格式化 FAT + 塞 BSP 文件。产出
nixos-r4s-sd.img。

正式镜像 sha256 `bbc179167bcd6d8aadc5d25ac189aedacd0957fb11451bb3eede20a4f7776e90`。
