# x86_64 移植入口（未实机验证）

新建独立 host，使用 `system = "x86_64-linux"`，导入安装机生成的
`hardware-configuration.nix` 和 `profiles/side-router.nix`。
根据机器选择 UEFI/systemd-boot 或 BIOS/GRUB，保留真实磁盘 UUID；填写
实际网口名（如 enp1s0/enp2s0）。不导入 R4S 模块，不需要 R4S BSP 资产。

当前只提供接入规范，不提供通用磁盘布局或已验证的 x86 镜像。
