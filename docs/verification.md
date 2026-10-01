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
