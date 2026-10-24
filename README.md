# NixOS Router

模块化 NixOS 旁路由配置。系统更新和镜像构建使用独立入口，共享硬件、网络与服务模块。原生运行独立 DNS、Mihomo、Zashboard、Sub-Store 与 Rust Router Console，不依赖容器。

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
| `modules/services/` | 独立可开关的 DNS、代理、面板、订阅管理与组播服务 |
| `profiles/` | 组合模块形成网络角色 |
| `packages/` | 软件打包与前端兼容补丁说明 |
| `images/` | 分区与完整镜像装配，不参与日常系统配置 |
| `scripts/legacy/` | 早期实验脚本，仅供历史参考，迁移后不作为执行入口 |

## 准备

需要 Linux 或 macOS、Git、启用 `nix-command flakes` 的 Nix、just 和 GNU coreutils。构建 ARM64 软件需要 ARM64 Linux 构建机、Nix 远程 builder 或已配置的 binfmt/QEMU；`just` 不自动修改宿主机仿真设置。

Flake 锁定当前已使用的 NixOS 24.05 revision，升级 nixpkgs 单独验证；这是兼容性基线，并非当前受支持的安全更新分支。重编译和完整验证放在有充足内存的 ARM64 builder 上；轻量配置可在 R4S 上直接 switch，避免并发构建造成内存压力。

R4S 的已验证 BSP 保存在 `hardware/nanopi-r4s-ddr3/bsp-assets.tar.xz`，使用 `xz -9e` 压缩，通过 Git LFS 下载。解包需要支持 xz 的 tar 和 xz 工具。包含内核、修改版 initramfs、DTB、内核模块与原卡 bootloader。不要用未经修改的 FriendlyWrt initramfs 替代。

```text
assets/r4s/
  bsp-Image
  bsp-ramdisk.gz
  bsp-r4s.dtb
  bootloader-32MiB.bin
  modules/6.6.134+/
```

clone 后在仓库根目录执行（需要 Git LFS）：

```bash
git lfs install
git lfs pull
just assets-prepare
just assets-check
```

解包目录也可以放在其他位置：`export ROUTER_ASSETS=/absolute/path/to/r4s-assets`。解包内容不进 Git；just 会使用 `--impure` 显式读取该路径。压缩包通过 LFS 管理，普通 Git blob 只包含指针。资产会导入 Nix store，所以构建空间需充足。新设备应先修改 `hosts/r4s-home/default.nix` 中的 SSH 公钥、地址、网口和 MAC。

## 常用命令

macOS 默认磁盘不区分大小写，不能直接解包 Linux 内核模块（例如
`xt_DSCP.ko` 和 `xt_dscp.ko`）。因此使用区分大小写的 APFS 稀疏磁盘映像存放资产。
这里的“资产卷”只是保存 BSP 内核、模块和 bootloader 的虚拟磁盘，不是容器，也不会给物理磁盘重新分区。

Mac 上启用 nix-darwin Linux builder、安装 Git LFS 等上述依赖后，在仓库根目录直接执行：

```bash
just image
```

`just image` 和 `just build` 会自动创建或挂载
`~/Document/r4s-build-assets.sparseimage`，使用 `/Volumes/R4SBuildAssets/r4s`
作为资产目录；资产缺失时拉取 LFS 压缩包并解包，已存在时只校验、不覆盖。
映像容量上限为 2 GiB，宿主机文件按实际使用增长。已有映像会复用，重启 Mac 后也会自动重新挂载。
构建自动传入 `--builders @/etc/nix/machines --max-jobs 0`，但不会自动安装或启用 Linux builder。
Linux 默认使用仓库内 `assets/r4s`，不创建资产卷。

可用 `just assets-mount` 单独挂载、`just assets-prepare` 单独准备资产。
显式设置 `ROUTER_ASSETS` 为其他目录时，不再管理默认资产卷；调用者需确保目录所在文件系统区分大小写。

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

## GitHub Actions 镜像构建

工作流为 `.github/workflows/image.yml`（Actions → **Build R4S image**）。
仅通过 **Run workflow** 选择分支后手动触发；push 和 PR 均不自动构建。
手动入口需要该 workflow 先进入默认分支。使用 GitHub 原生 `ubuntu-24.04-arm`
runner，不依赖 Mac、在线 R4S、容器或额外的私有缓存密钥；仓库/套餐必须支持该 runner。

CI 自动下载 Git LFS BSP 资产，使用 `flake.lock` 锁定的 Nixpkgs 提供 just，
执行 `just ci-image`（准备并校验资产、求值、构建镜像）。本地也可用同一命令复现。
GitHub LFS 配额或 runner 不可用时，任务会失败，不会跳过资产校验。

完成后在对应运行的 **Artifacts** 下载 `r4s-home-<commit>`，保留 14 天。
解开 GitHub 的下载包后包含 `.img.gz`、压缩包校验 `SHA256SUMS`、原始镜像校验
`IMAGE.sha256` 和构建信息 `BUILD.txt`：

```bash
sha256sum -c SHA256SUMS
gzip -dk r4s-home-<commit>.img.gz
sha256sum -c IMAGE.sha256
```

CI 使用 `gzip -9 -n` 压缩镜像，只上传压缩文件与校验信息，不上传原始 `.img`。
gzip 通常比 xz 体积更大；此格式选择主要方便解压，不保证比旧产物更小。

这是 `r4s-home` 的设备镜像，包含仓库中的固定 IP、MAC、公钥和可信 LAN 配置，
不是适合任意设备的通用固件。使用前检查 `hosts/r4s-home/default.nix`。
CI 不刷写、不部署、不发布 Release；构建成功不等于实机启动验证通过。

## 路由器控制台

独立控制台为 `http://192.168.1.5:9080`，以可选插件显示系统指标、DNS 实际解析、Mihomo API、Zashboard、订阅更新、Sub-Store 和 udpxy 状态。控制台只读；HTTP 接口正常不等于代理出口可用。DNS 由独立 dnsmasq 提供。

代码和通用 NixOS 模块位于 [router-console](https://github.com/hizolaw/router-console)，本仓库通过 flake 锁定其版本，应用工具链使用自己的 nixpkgs，不升级路由系统的 24.05 基线。具体监听地址、插件和服务入口在 `hosts/r4s-home/default.nix`。

首次启动生成 `/var/lib/router-console/access.token`（root-only），通过 systemd credential 传给普通权限的控制台进程，后续切换和重启不覆盖。SSH 登录路由器后运行 `just console-token` 或 `sudo cat /var/lib/router-console/access.token` 获取令牌；令牌不进 Git。`just console-status` 查看服务。

当前模块通过只读运行时环境文件读取 Mihomo API 凭据，缺少凭据只会让该插件显示未知，不影响控制台启动。不引入代理服务依赖，也不管理应用 Profile。

新增控制台的日常部署只需在独立 ARM64 builder 上 `just assets-check`、`just check`、`just build`，传输构建 closure 后在目标机 switch；无需构建或刷写固件。Mac mini 可复用已有 nix-darwin Linux builder 和 `/Volumes/R4SBuildAssets/r4s`。现有 GitHub CI 仍只用于手动构建刷机固件。

## 服务与配置归属

R4S 启用原生 udpxy，状态页为 `http://192.168.1.5:4022/status`。
例如组播源 `udp://239.1.2.3:1234` 对应播放地址
`http://192.168.1.5:4022/udp/239.1.2.3:1234`（示例地址，不代表实际频道）。
物理 WAN 为 eth0，但当前桥接在 br0，因此组播接收接口配置为 br0。
不改变网桥、路由或 mihomo 配置；上游必须允许 IGMP 并提供对应组播。
服务无身份认证，仅限可信 LAN。若以后开启防火墙，需另行放行 LAN HTTP 与所需组播流量。
独立选项为 `router.udpxy.{enable,listenAddress,multicastInterface,port,maxClients}`；
在主机配置设置 `router.udpxy.enable = false` 即可关闭。`just status` 包含该服务。

代理面板：`http://192.168.1.5:8080`（Zashboard）；mixed 代理端口 7890。Mihomo API 只监听 `127.0.0.1:9090`，面板通过同源反代访问。手机 IPv4 网关与 DNS 都设为 `192.168.1.5`。

- dnsmasq 独立监听 LAN/loopback 的 UDP、TCP 53，上游为直连 DNS；不依赖 Mihomo、面板或订阅服务，不启用 DHCP。当前抑制 AAAA，未接管 IPv6 默认路由。
- Mihomo 使用真实 IP 与域名嗅探，内部 DNS 仅监听 loopback 1053，不劫持 LAN DNS。TUN 使用独占表 2033、优先级 10000–10010，停止后只清理自身路由；关闭严格路由及自动重定向，核心退出后流量回到现有默认网关。核心运行但节点失效时，故障回退组尝试 DIRECT；受阻站点仍受直连网络本身限制。
- Sub-Store 独立运行，不需要代理核心在线。页面为 `http://192.168.1.5:17893`，完整管理链接通过 `just sub-store-url` 获取；链接内的 API 前缀属于凭据。订阅在 Sub-Store 中管理，`router` 集合供更新器使用。
- 每日 04:00（最多随机延迟 5 分钟）更新节点：只从本机 Sub-Store 获取、验证并原子替换 provider，通过 API 刷新节点；失败保留旧节点。核心关闭时仅保存，不自动启动核心。不会 PATCH 或启动时重写用户的分流、DNS 和选择。

```bash
just subscription-update   # 手动更新并查看安全状态
just subscription-status
just mihomo-secret         # 面板 API 令牌，仅在本机显示
just sub-store-url         # 带凭据的管理链接，不要公开
just status
```

Nix 管软件、服务和缺失文件的初始模板。运行配置与节点在 `/var/lib/mihomo-router/`，订阅数据在 `/var/lib/sub-store/`，控制台在 `/var/lib/router-console/`；secret、订阅及运行 Profile 不进 Git。已有配置不会在 switch 或启动时被模板覆盖。更改已有策略应显式编辑运行配置并先验证；回滚 NixOS 不会回滚应用数据。

从旧 MetaCubeXD 迁移必须先备份 `/var/lib/metacubexd`。`mihomo-migrate stage --backup /root/backup.tar.gz` 显式导入节点和规则，使用新网络策略；启动新服务后运行 `mihomo-migrate connect-sub-store --backup /root/backup.tar.gz` 导入缺失订阅和集合。迁移不自动运行，不修改旧数据，不复制旧 Fake-IP 缓存。首次切换后客户端可能需要刷新旧 DNS 缓存。旧模块保留供回退，当前部署不启用 MetaCubeXD 或 UA 中继。

模块可独立关闭：`router.dns.enable`、`router.mihomo.enable`、`router.subStore.enable`、`router.udpxy.enable`。Mihomo 的 `dashboardPackage = null` 可不部署面板。主机为控制台插件配置对应启用条件；订阅状态通过独立只读状态文件共享，不向控制台暴露节点或订阅凭据。当前服务仅适合可信 LAN，未配置公网入口。

新增硬件见 [hardware-porting.md](docs/hardware-porting.md)，R4S 历史见 [NOTES.md](hardware/nanopi-r4s-ddr3/NOTES.md)。历史中的绝对路径、旧命令与中间结论不代表当前配置。
