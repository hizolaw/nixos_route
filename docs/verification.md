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


## 2026-10-25：Zashboard 首次连接修复

用户报告页面出现旧 MetaCube。HTTP 获取与全新 Chromium 实测服务器实际提供 Zashboard；尚未复现用户浏览器中的旧页面，不能据此认定其原因。

浏览器确认的缺陷是首次设置默认连接浏览器本机的 127.0.0.1:9090，而控制器仅在路由器 loopback 监听。针对本部署的静态包修正为当前页面的 protocol/host/port，凭据仍为空、由用户输入；nginx 添加 Cache-Control: no-cache，使浏览器重新校验同源资源。修补保留上游固定版本，匹配失败会使构建失败，避免升级时静默失效。

Mac 上 assets-check、check、build 通过，在线 switch 仅重启 nginx。最终系统 `/nix/store/rhm7xs3ca3qf6hkc1s4lw0n9wj4a03ps-nixos-system-r4s-24.05.20241230.b134951`。真实 Chromium 验证首次地址/端口自动填写、输入令牌后连接、63 节点可见、390px 页面及刷新恢复；无页面脚本错误。该次没有重启设备。


## 2026-10-25：控制台一键连接两个管理面板

- router-console input 更新到 `702db66065f05f34bdb32adc3f4fe8d9642617c9`，新增通用可选 `url_env`。部署侧生成私有运行时入口，缺失或非法环境入口仅隐藏链接，不影响服务探测。
- `/run/router-console-links/` 为 root 0700，environment 为 root 0600。文件只包含由服务运行时令牌构造的入口，不修改 Profile、不写入 Nix store。Zashboard 从 setup fragment 带入后端地址与令牌；直接 overview fragment 会在首次路由重定向时丢参数，因此不作为自动连接入口。Sub-Store 带入 api 查询参数。
- 浏览器定位到 Sub-Store 静态脚本因默认 CORS 策略拒绝 LAN Origin 而返回 403，新增 allowedOrigins 选项，默认显式允许 publicURL，未使用通配来源。
- Rust 16 项测试、链接构造 2 项测试、Mac ARM64 应用/模块检查和 just assets-check/check/build 成功；DNS 与代理模块两种架构启用/禁用等求值见本次命令结果。
- 系统 `/nix/store/5ypw5rhd7apq3gnmgyvrn7jmh084lqa2-nixos-system-r4s-24.05.20241230.b134951` 已在线 switch；只重启 router-console、sub-store，新增运行时链接初始化单元。DNS、Mihomo、udpxy、watchdog PID 均保持。未重启设备。
- 全新 Chromium 登录控制台，真实点击 Zashboard / Sub-Store 两个“打开服务”入口，无需再次填令牌：前者显示 R4S / Proxies 与 63 节点，后者显示 4 个订阅和集合；未认证状态接口仍返回 401。Sub-Store 空白页已消失。
- Zashboard 自身检查 GitHub 最新版本的外部请求曾返回 403 并产生非阻断脚本错误；连接和节点页面成功。旧远程订阅仍有上游失效提示，未将它们冒充为更新成功。

## 2026-10-25：系统账户登录与会话部署

- router-console 固定为 `cf1fb7cb60d81fabb1a045bcc6dc1b1b7a393792`，主机使用 `authentication = "system"`、允许 `nixos` / `root`。不修改系统密码、SSH 认证或代理/订阅配置。
- Web 进程改为静态普通用户 router-console；独立 root PAM helper 仅监听私有 Unix socket，目录 root:router-console-auth 0750，socket 0660。helper 按显式允许列表执行宿主 pam_unix 的 authenticate/account；无 nullok，不接受空密码或旧 Bearer。
- 登录最多 2 个并发、全局每分钟 8 次失败，正文/字段有界；会话仅存随机令牌摘要、用户名和到期时间，最多 128 个，默认 12 小时。浏览器使用 HttpOnly/SameSite=Strict cookie，不把密码或会话写入 localStorage/sessionStorage；退出撤销，Web 重启清空。
- 23 项 Rust 测试、全目标 Clippy（警告视为错误）、格式检查、新前端 4 项 Playwright 测试通过。Nix module 在 x86_64-linux/aarch64-linux 求值通过，ARM 包与模块检查在 Mac Linux builder 构建成功。
- Mac 上 `just assets-check`、`just check`、`just build` 通过；系统 `/nix/store/r4fkj6iwkbc2w512fpgzd4bwap6qdd3h-nixos-system-r4s-24.05.20241230.b134951` 经 dry-activate 后在线 switch 成功。仅替换控制台、停止旧 token 初始化并新增 PAM helper，网络服务 PID 均保持。此前系统和 boot.scr 保存在 `/root/router-console-system-auth-20261025/`。
- R4S 创建临时无 home/nologin/非特权账户，在同一实际 PAM service、同一 helper 二进制和相同安全限制下，通过独立测试 socket/19081 页面实测：错密码拒绝、正确密码登录、刷新保持、跨源退出 403、正常退出后状态 401；cookie 标志及浏览器 storage 验证通过，无页面脚本错误。随后删除临时账户、凭据、服务、运行目录和监听端口。未读取或改动生产账户密码，也未以 mock 代替本段 PAM 实测。
- 生产 9080 显示用户名/密码表单，标准 autocomplete=username/current-password；`/api/auth` 返回 system，未登录状态接口 401。nixos 仍为 P、root 仍为 L，原状态不变。当前生产账户的正确密码由用户输入，未代用户读取或猜测。
- 当时 cgroup 内存约 Web 8.9 MiB、helper 0.6 MiB，无 failed units。此次仍为在线 switch 验证，没有重新上电启动验收。
