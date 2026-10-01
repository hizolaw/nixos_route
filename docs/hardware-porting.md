# 增加硬件

1. 在 `hardware/<board>/default.nix` 定义内核、启动加载器、根盘和启动盘挂载。网口驱动属于此层，LAN/WAN 角色属于 host。
2. 在 `hosts/<name>/default.nix` 导入硬件模块及 `profiles/side-router.nix`，填写接口、地址、网关、公钥和 `system.stateVersion`。不要复制 R4S 的 MAC。
3. 在 flake 的 `nixosConfigurations` 添加正确 `system` 的 `nixosSystem`。通用 x86 不传 R4S `routerAssets`。
4. 若需镜像，在 `images/` 增加该硬件的入口，再通过 `extendModules` 导出 package。UEFI 安装镜像和 ARM SD 镜像不是同一格式。
5. 分别验证运行配置、服务架构、镜像分区、实际启动、更新及回滚。

当前 profile 是旁路由，禁用防火墙以保持现有 LAN 行为。主路由需要新 profile，明确 WAN/LAN、NAT、DHCP、DNS 和防火墙，不要复用这一安全策略。

IPv6 完整接管还涉及 RA、转发及上游前缀，需单独设计，不能通过单独开启 DNS AAAA 实现。
