# 一加 15 内核云编译（方案 A / B）

底座：一加官方 6.12.58 源码（`oneplus/sm8850_b_16.0.0_oneplus_15`，16.0.10.601 同步）
组件：KernelSU 官方最新 main + SUSFS 最新（`gki-android16-6.12` 分支）+ Baseband-guard + TTL + IP_SET + BBR 默认开启
保持原厂：编译优化、ZRAM、CFI、SCS；只替换 boot 里的内核，不动 vendor_dlkm / system_dlkm。

| | 方案 A：NoMount（隐蔽优先） | 方案 B：OverlayFS（稳定优先） |
|---|---|---|
| 编进内核 | `CONFIG_NOMOUNT=y`（NoMount 最新 tag） | `CONFIG_OVERLAY_FS=y`（原厂本来就是 y） |
| SUSFS OPEN_REDIRECT | 关（避免和 NoMount 重叠） | 开 |
| SUSFS sus_mount | 编进去，可以少用 | 编进去，用来隐藏 overlay 挂载 |
| 风险 | VFS 层改动，稳定性风险最高 | 最成熟，挂载表痕迹靠 sus_mount 盖 |

## KernelSU 和 SUSFS 的版本

- 默认拉 KernelSU 官方 `main` 最新提交，SUSFS 拉 `gki-android16-6.12` 分支最新提交
- SUSFS 的 KernelSU 补丁只跟到 SUSFS 作者同步过的那个 KernelSU 提交。如果最新 main 已经改得补丁打不上，脚本会自动退回到 SUSFS 最后同步的那个提交，日志里有黄色 `::warning::` 提示
- 实际用了哪个版本，看产物里的 `build-info.txt`
- 想回到 SUSFS v2.2.0：`susfs_ref` 填 `f37930f374ef88de990d6abea0c67d0ea28c1edc`，`ksu_ref` 填 `953b403ab5ea2c1d866f72f6a7e67ce9224b8932`

## 源码从哪来

编译时优先拉你自己账号下 fork 的 `android_kernel_common_oneplus_sm8850`，找不到才回退到 OnePlusOSS。
一加更新源码后，到你的 fork 页面点 **Sync fork** 即可。

工具链（clang r536225、rustc 1.82.0、bindgen）按一加 `kernel_manifest` 里 `oneplus_15.xml` 锁定的版本从 CodeLinaro 下载，和官方构建一致。

## 准备原厂 boot.img（生成 boot.img 需要）

boot.img 是拿原厂 boot.img 用 magiskboot 只换内核重新打包的，头部、cmdline、安全补丁日期都保持原厂，和 Magisk 修补的方式一样。所以需要先给一份原厂 boot.img：

1. 拿到和手机当前固件版本一致的 boot.img（从全量包 payload.bin 里解出来，或者有 root 时 `dd if=/dev/block/by-name/boot_a of=/sdcard/boot.img`，当前槽位是 b 就用 boot_b）
2. 仓库页面 → **Releases** → **Draft a new release**，tag 填 `stock-boot`，把文件命名为 `boot.img` 上传，发布
3. 以后升级固件，就把这个 release 里的 boot.img 换成新版本的

也可以在运行时用 `stock_boot_url` 直接填一个下载链接。没有原厂 boot.img 时照样编译，只是不出 boot.img。

## 怎么编

1. 仓库页面 → **Actions** → **Build OnePlus 15 kernel** → **Run workflow**
2. `scheme` 选 `both`（两套都编）、`A` 或 `B`
3. `release` 默认勾选：编完自动发布到 **Releases**
4. 可选：`kernel_release` 填手机原厂 `uname -r` 的结果，`build_timestamp` 填原厂 `uname -v` 里的时间，用来伪装版本号
5. 等 1～2 小时，到 **Releases** 下载

每个方案发布的文件：

| 文件 | 用途 |
|---|---|
| `boot_*.img` | `fastboot flash boot boot_*.img` 直接刷 |
| `AnyKernel3_*.zip` | 管理器或第三方 Recovery 卡刷 |
| `Image_*` | 单独的内核文件，自己打包用 |
| `build-info_*.txt` / `kernel_*.config` | 版本信息和完整内核配置 |

文件名里带 `schemeA` / `schemeB` 区分。Actions 运行页底部的 Artifacts 里也有同样的文件。

## 本地编译（WSL，云端之外的另一种方式）

云端 Actions 和本地 WSL 两种方式并存，用哪个都行，底座和组件完全一样。本地适合想自己改源码、或不想占用 Actions 时长。

**1. 装 WSL 和依赖**（Ubuntu 22.04 / 24.04）

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  bc bison flex cpio zip unzip lz4 zstd python3 git curl rsync \
  libssl-dev libelf-dev libdw-dev libncurses-dev dwarves patch ca-certificates make gcc
```

`libdw-dev` 不能漏（编译主机工具 gendwarfksyms 需要它的 `dwarf.h`）。

**2. 把仓库放到 WSL 的 Linux 目录**（不要放 `/mnt/c`，否则软链接和权限会出问题）

```bash
cd ~ && git clone https://github.com/yuanluow/oneplus15-kernel-build.git op15 && cd op15
chmod +x scripts/wsl-build.sh
```

**3. 编译**

```bash
# 只编方案 A（NoMount）:
SCHEME=A ./scripts/wsl-build.sh

# 编方案 B，并伪装成原厂版本号、顺便打进 boot.img:
SCHEME=B \
KERNEL_RELEASE='6.12.58-android16-6-g925a103d123c-ab15898589-4k' \
BUILD_TIMESTAMP='Mon Jul 20 17:37:05 UTC 2026' \
STOCK_BOOT=~/boot_stock.img \
./scripts/wsl-build.sh
```

常用环境变量：`SCHEME`(A/B，必填)、`STOCK_BOOT`(原厂 boot.img 路径，给了才出 boot.img)、`KERNEL_RELEASE`/`BUILD_TIMESTAMP`(伪装版本号)、`SRC_OWNER`(用你 fork 的源码就填你的用户名)、`SUSFS_REF`(回退 v2.2.0 填 `f37930f374ef88de990d6abea0c67d0ea28c1edc`)、`JOBS`(并行度)。

产物同样在 `dist/`：`AnyKernel3_*.zip`、`boot_*.img`、`Image_*`、`build-info.txt`。第一次会下约 1.5GB 工具链、占约 25GB 磁盘。重复跑脚本会复用已下载的工具链和源码（要全新来就删掉 `work/`）。

## 刷机

1. **先备份原厂 boot.img**，准备好 `fastboot flash boot boot.img` 刷回
2. 二选一：`fastboot flash boot boot_*.img`，或者用 KernelSU 管理器 / 第三方 Recovery 刷 AnyKernel3 zip
3. 第一次刷完不装模块，先确认：
   - 能开机，`uname -r` 正常
   - `cat /proc/sys/net/ipv4/tcp_congestion_control` 显示 `bbr`
   - `iptables -t mangle -A POSTROUTING -j TTL --ttl-set 64` 不报错
   - `ipset create test hash:ip` 不报错（测完 `ipset destroy test`）
   - 方案 A：`zcat /proc/config.gz | grep NOMOUNT` 显示 `=y`
4. 装 SUSFS 用户态模块（sidex15 `ksu_module_susfs`）
5. KernelSU v3 仍然需要一个元模块来挂载其他模块（挂载逻辑在用户态，没法编进内核）：
   - 方案 A：装 NoMount 元模块，它会直接用内核里编好的 NoMount，不再加载自己的 LKM
   - 方案 B：装 KernelSU 的 OverlayFS 元模块
6. 再逐个加其他模块；打开 Chase 等 App 挂几分钟确认不重启，崩了看 `/sys/fs/pstore`

## 说明

这套流程没有实际在一加 15 上编过、刷过。第一次运行如果失败，看 Actions 日志里红色的 `::error::` 行，最常见的是补丁冲突和 Kconfig 选项名不对。
