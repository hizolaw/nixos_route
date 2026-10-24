# R4S 重构验证记录

2026-10-01：在 Mac mini 的 nix-darwin Linux builder 上验证，仓库版本
`b7464b8`（配置构建与 `8118c1f` 相同，新增 macOS 解包检查和文档）。

- GitHub clone 和 Git LFS 下载成功。
- BSP 在区分大小写的 APFS 卷解包，固件和模块目录校验通过。
- 系统、镜像求值通过；ARM64 系统和完整 SD 镜像均构建成功。
- 镜像分区：MBR，FAT 从 sector 65536 开始，大小 1048576 sectors；
  ext4 从 sector 1114112 开始，大小 5578592 sectors；sector 为 512 字节。
- 两个分区 bootable 标志均存在。
- bootloader 的 32KiB–32MiB 区域与已验证资产逐字节一致。
- 从 FAT 提取的 Image、ramdisk.gz、DTB 与资产 SHA-256 一致。
- boot.scr 指向镜像内的 NixOS init；对应文件存在且为可执行文件。
- ext4 `e2fsck -fn` 五阶段检查通过。
- Mac 构建产物与本地复制的 SHA-256 一致：

```text
ada8f45e7aabcf8436eb3bf3ff7d3b3673b13b77d5fc5d1873107573804e8788
```

Mac 产物：
`/Users/hzluo/Document/nixos-router-build/result-image/sd-image/nixos-sd-image-24.05.20241230.b134951-aarch64-linux.img`

本地验证副本：`out/verification/r4s-refactor.img`（不入 Git）。

尚未刷卡或实机启动；未更新线上 R4S 的系统 generation。下一步使用备用
SD 卡验证启动、SSH、网桥、看门狗、WebUI、订阅及手机代理；构建和静态
检查不等同于实机验证。新镜像不包含线上订阅或 secret。

## 2026-10-25：Router Console 日常系统部署

新增独立的 Rust 控制台；没有执行固件构建、刷卡或重启路由器。现有镜像 CI 未修改。

### 求值与构建

- `router-console` input 固定为 `188fed2b92aad6ddbf7928eeb7ec4f0fbb036afd`。
- 应用提供 `packages.{x86_64-linux,aarch64-linux}.default`、`apps`、开发环境和 `nixosModules.default`。
- 应用 flake 两种架构求值、模块禁用、自定义 token 路径断言通过；x86_64 Nix 包与模块检查构建成功，11 项 Rust 测试通过。
- 使用 Mac mini 的 nix-darwin Linux builder，独立工作目录 `/Users/hzluo/Document/r4s-console-20261025`，未覆盖原有工作目录及未提交修改。
- 在 Mac 上执行 `just assets-check`、`just check`、`just build` 成功。`just check` 包括镜像求值，但没有运行 `just image`。
- ARM64 应用构建、Rust 测试、模块配置检查通过，系统结果为 `/nix/store/13h1kf70aibhcnybs8g45y6xmysaf7vj-nixos-system-r4s-24.05.20241230.b134951`。
- 缓存下载不稳定时，从开发机向 Mac mini 传输了已校验的依赖与工具链；R4S 未承担求值或编译。

### 激活与运行验证

- closure 从 Mac mini 传到在线 R4S，先执行 `dry-activate`，并比较新旧 systemd 单元内容：仅新增 `router-console.service`、`router-console-token.service`，无删除或修改的现有单元。
- 在目标机使用预构建系统更新 system profile，执行 `switch-to-configuration switch` 成功。通过仓库配置的 bootloader 安装接口更新 `boot.scr`。
- 旧系统路径、generation 列表和 `boot.scr` 保存在路由器 `/root/router-console-deploy-20261025/`，未删除原备份或镜像。
- 控制台 `http://192.168.1.5:9080` 返回 200；未认证状态 API 返回 401，带令牌访问成功。
- 系统、DNS 实际解析、Mihomo API、现有代理面板和 udpxy 共 5 个插件完成探测。HTTP 成功只表示接口可达，未验证代理出口。
- Chromium 实际连接 LAN 页面、令牌登录、桌面和 390px 手机布局通过；5 张卡片、无横向溢出、无页面脚本错误。
- 服务以 DynamicUser 运行，初期 cgroup 内存约 5 MiB，3 个任务。令牌目录 root:root 0700，文件 root:root 0600；重新运行初始化服务并重启控制台后，令牌未改变。
- 原有 MetaCubeXD、udpxy、看门狗保持运行；未修改网桥、默认路由、DNS 配置或应用 Profile。

### 未验证与后续范围

此次验证的是在线 switch 和控制台运行，不是重启或刷机验收。没有重新启动设备，因此不能据此宣称新 generation 已通过实机启动验证。

当前 DNS 仍由 Mihomo 提供，独立 DNS、Zashboard/Sub-Store 替换和订阅更新迁移仍属后续工作。


## 2026-10-25：独立 DNS 与 Mihomo / Sub-Store 重构

### 求值、构建与代码检查

- 系统仍固定 NixOS 24.05，BSP、网桥、默认网关和看门狗不变；现代应用包单独取自 router-console 的固定 nixpkgs。
- router-console 固定为 `a311e9d741b17a62515bf29f361ebb218d837228`，新增订阅状态插件；ARM64 应用和模块检查在 Mac Linux builder 构建成功。
- Mac mini 独立工作目录执行 `just assets-check`、`just check`、`just build` 成功；镜像只求值，没有构建固件。
- DNS 与代理模块在 aarch64-linux / x86_64-linux 的启用、禁用、替换包和非默认端口求值通过；16 项 Python 测试通过，包含真实 Mihomo 1.19.27 provider 热刷新。
- 生成的清理和 Sub-Store shell 脚本通过 bash -n；git diff --check 通过。
- 最终系统：`/nix/store/lrzq4vnd4pllldvj95gjvn0s7c4l54cy-nixos-system-r4s-24.05.20241230.b134951`。

### 状态迁移与在线激活

- `/root/mihomo-refactor-20261025/` 保存旧 MetaCubeXD 数据归档、旧系统路径和 boot.scr；迁移不修改旧数据。
- switch 前显式 stage 迁移 22 个旧节点和 3879 条规则；保留直连/拒绝规则，将旧代理策略映射到故障回退组，CN IP 使用固定本地规则文件，未复制 Fake-IP 缓存。
- 经预构建 closure 执行 switch，boot.scr 由既有安装接口更新；没有重启或刷卡。首次切换时 nginx 因网络地址初始化短暂重试，已增加静态网络配置的启动顺序。
- 根据用户要求同步本机 Sub-Store 的 3 个订阅、2 个集合及处理设置，保留路由器旧订阅；修改前另在 `/root/r4s-state-backups/` 创建私有备份。
- 两个旧远程订阅直接请求均返回 404。运行集合 router 暂使用本机有效本地订阅，导出、配置验证、原子替换与 provider 热刷新成功，共 63 节点；远程源仍需后续更新有效地址。
- 通过 R4S mixed 端口访问 Google / gstatic generate_204 均返回 204；自动选择组延迟探测成功。

### 故障验证与边界

- 同时停止 Mihomo、Sub-Store、nginx，dnsmasq PID 保持不变；专用表 2033 和优先级 10000–10010 清理，策略路由只剩系统默认项。
- 隔离 network namespace 模拟下游客户端，经 R4S 转发直连百度 HTTPS 返回 200；临时 veth、SNAT 和 namespace 随测试清理。
- 实际 LAN Mac 客户端通过 R4S 的 UDP / TCP DNS 解析成功。模拟 namespace 的 UDP 成功，但该额外接口上的 TCP 被拒绝，原因未进一步定位，不作为 LAN TCP 验证依据。
- 对核心发送 SIGKILL，在自动重启等待期间确认专用策略已清理、DNS 仍解析；之后核心自动恢复。
- DNS 状态探测改用 www.baidu.com：公网直接请求上游 DNS 的 example.com UDP 本身超时，而其他域名正常；避免把单个域名上游问题误报为整个 DNS 不可用。
- 看门狗 PID 484、udpxy PID 726 保持；既有手工 rtp2httpd 不变。

验证覆盖在线 switch 和运行恢复，尚未验证新 generation 重新上电启动，也没有验证所有订阅节点或所有站点。订阅/状态文件与凭据均不入 Git。
