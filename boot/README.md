# 真机验证过的 boot.img（方案 A）

| 项目 | 内容 |
|---|---|
| 文件 | `boot_OP15_schemeA_CPH2747_16.0.10.601_EX01.img` |
| 机型 | 一加 15 欧版 CPH2747 |
| 运行成功的固件 | **OxygenOS 16 `CPH2747_16.0.10.601(EX01)`**（OTA `CPH2747_11.A.48_0480_202609111034`，安全补丁 2026-09-01） |
| 内核 `uname -r` | `6.12.58-android16-6-g925a103d123c-ab15898589-4k`（伪装成原厂） |
| 内核 `uname -v` | `#5 SMP PREEMPT Mon Jul 20 17:37:05 UTC 2026` |
| 验证方式 | 刷进 `boot_a` 后正常开机、日常使用（KernelSU、NoMount 方式挂载的模块、LSPosed、VoWiFi 正常）；手机上 `boot_a` 分区的 sha256 与本文件一致 |
| 编译方式 | 本地 WSL，`scripts/wsl-build.sh`，2026-11-23 |
| sha256 | 见 `SHA256SUMS` |

组件和版本见 `build-info_schemeA.txt`：KernelSU v3.3.1-55-g2a60b289、SUSFS gki-android16-6.12 (9b0b13f)、NoMount v2.3.1（内置）、Baseband-guard、Unicode 绕过修复、fgetpriority、屏蔽 `oplus_secure_guard_new`。

**只适用于 `CPH2747_16.0.10.601(EX01)`。** 这个 boot.img 是用这个版本的原厂 boot.img 重新打包的，其他固件版本请不要直接刷，用 Releases 里的 AnyKernel3 zip，或者拿自己固件的原厂 boot.img 重新编。

刷入：

```
fastboot flash boot boot_OP15_schemeA_CPH2747_16.0.10.601_EX01.img
```

刷之前先备份自己的原厂 boot.img。
