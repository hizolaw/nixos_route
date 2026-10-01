# NixOS Router

模块化 NixOS 旁路由配置。系统更新和镜像构建使用独立入口，共享硬件、网络与服务模块。原生运行 MetaCubeXD Server 与 mihomo，不依赖容器。

## 支持范围

当前设备是 NanoPi R4S **1GB DDR3**，使用 FriendlyElec BSP 6.6.134+。当前线上旧配置已验证可用；重构后的配置需要另行实机启动验收。其他 R4S 内存版本不能直接视为兼容。

x86_64 提供移植入口说明，尚未提供可刷写镜像或实机保证。当前网络角色为可信局域网内的旁路由，不含 WAN/LAN 主路由的 NAT、DHCP 和边界防火墙配置。

## 目录

| 路径 | 职责 |
| --- | --- |
| `hosts/r4s-home/` | IP、网口、MAC、公钥、主机名等设备参数 |
| `hardware/nanopi-r4s-ddr3/` | BSP、看门狗、启动安装、资产校验；原 NOTES.md 原样保留于此 |
| `modules/system/` | 基础系统、SSH 访问 |
| `modules/networking/` | 参数化旁路由网络 |
| `modules/services/` | 独立可开关的 MetaCubeXD 和订阅 UA 中继 |
| `profiles/` | 组合模块形成网络角色 |
| `packages/` | 软件打包与前端兼容补丁说明 |
| `images/` | 分区与完整镜像装配，不参与日常系统配置 |
| `scripts/legacy/` | 早期实验脚本，仅供历史参考，迁移后不作为执行入口 |

## 准备

需要 Linux、Git、启用 `nix-command flakes` 的 Nix、just 和 GNU coreutils。构建 ARM64 软件需要 ARM64 构建机、Nix 远程 builder 或已配置的 binfmt/QEMU；`just` 不自动修改宿主机仿真设置。

Flake 锁定当前已使用的 NixOS 24.05 revision，升级 nixpkgs 单独验证；这是兼容性基线，并非当前受支持的安全更新分支。1GB R4S 上完整求值/构建可能耗尽可用内存，建议在有充足内存的 ARM64 builder 上构建，再安排部署；不要在承担网络出口的设备上并发重构构建。

R4S 的专用 BSP 尚无完整自动下载链。新 checkout 需要从维护者备份取得以下文件，并通过校验。不要用未经修改的 FriendlyWrt initramfs 替代。

```text
assets/r4s/
  bsp-Image
  bsp-ramdisk.gz
  bsp-r4s.dtb
  bootloader-32MiB.bin
  modules/6.6.134+/
```

原工作区还保有 `ref-fw/` 和 `sd-bootloader-32MiB.bin` 时可执行：

```bash
just assets-prepare
just assets-check
```

资产也可以存放在其他位置：`export ROUTER_ASSETS=/absolute/path/to/r4s-assets`。它们不进 Git；just 会使用 `--impure` 显式读取该路径。资产会导入 Nix store，所以构建空间需充足。新设备应先修改 `hosts/r4s-home/default.nix` 中的 SSH 公钥、地址、网口和 MAC。

## 常用命令

```bash
just                   # 列出命令
just check             # 校验资产、评估系统与镜像、检查 diff
just build             # 只构建系统，输出 result-system
just image             # 构建完整 SD 镜像，输出 result-image/sd-image/*.img
```

镜像包含分区表、vendor bootloader、BSP 内核/DTB/initramfs 和指向该镜像系统的 boot.scr，不再需要手动运行 assemble.sh。刷写时自行确认目标设备；just 不自动选择或写入磁盘。

设备首次启动后，通过 SSH 进入，把本仓库及 BSP 资产放在设备上。日常在设备内运行：

```bash
just check
just boot              # 下次启动生效；适合涉及网络或引导的改动
just switch            # 立即应用；网络改动可能中断 SSH
just rollback          # 切回上一代系统
```

选择其他已添加主机：`just host=my-router build`。底层等价命令：

```bash
ROUTER_ASSETS=/absolute/path/to/assets nix build --impure .#nixosConfigurations.r4s-home.config.system.build.toplevel
sudo env ROUTER_ASSETS=/absolute/path/to/assets nixos-rebuild boot --impure --flake .#r4s-home
```

R4S 的引导安装接口会随 rebuild 更新 boot.scr；这不负责更换已有设备的 BSP 文件。系统回滚也不回滚 `/var/lib/metacubexd`，修改前应备份运行数据。旧命令 `-I nixos-config=./r4s.nix` 已由 Flake 入口替代。

## 服务与配置归属

默认 WebUI：`http://192.168.1.5:8080`，mihomo API 9090，mixed 7890。手机 IPv4 网关与 DNS 都设为 `192.168.1.5`。

Nix 管服务和软件版本；订阅地址、节点、分流和自动更新由 WebUI 管理，持久化在 `/var/lib/metacubexd/`。secret 在首次启动生成，不存储到仓库。

`router-local` 合并覆盖仅在缺失时创建，之后允许 WebUI 编辑。修改 Nix 的初始覆盖模板不会覆盖已有 Profile。覆盖提供 LAN 访问、TUN、DNS 监听；`ipv6: true` 保留内核能力，`dns.ipv6: false` 抑制 AAAA。此配置不接管手机的 IPv6 默认路由，也不保证绕过该 DNS 的应用不直连。

订阅中继为 `http://192.168.1.5:18080/https://provider.example/subscribe?...`，固定请求 UA。仅在服务商需要时使用。当前兼容策略关闭旁路由防火墙，WebUI 与中继只能部署在可信 LAN，不应暴露到公网。

模块选项包括 `router.metacubexd.{enable,port,apiPort,mixedPort,backendURL}`、`router.subscriptionRelay.{enable,listenAddress,port}` 和 `router.network.{interfaces,address,prefixLength,gateway,nameservers}`。

新增硬件见 [hardware-porting.md](docs/hardware-porting.md)，R4S 历史见 [NOTES.md](hardware/nanopi-r4s-ddr3/NOTES.md)。历史中的绝对路径、旧命令与中间结论不代表当前配置。
