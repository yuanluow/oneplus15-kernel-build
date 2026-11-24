# 一加 15 内核编译（方案 A：NoMount）

底座：一加官方 6.12.58 源码（`oneplus/sm8850_b_16.0.0_oneplus_15`，16.0.10.601 同步）
组件：KernelSU 官方最新 main + SUSFS 最新（`gki-android16-6.12` 分支）+ **NoMount 内置** + Baseband-guard + TTL + IP_SET + BBR 默认开启 + Unicode 绕过修复（`patches/unicode_bypass_fix.patch`，挡住零宽字符探测 `/sdcard/Android/data` 里被隐藏的应用）
内置模块：**fgetpriority**（应用无法通过 getpriority/setpriority/ioprio 探测其他应用的 UID，配合 HMA 用）、**屏蔽 `oplus_secure_guard_new`**（等同 sg_unblock，内核直接拒绝加载它，解除它对 /data/adb 等目录二进制的执行拦截）。刷了本内核就**卸载 fgetpriority 和 sg_unblock 这两个 KSU 模块**。要屏蔽别的厂商模块，用环境变量 `BLOCK_MODULES=模块1,模块2`（本地编译）。
保持原厂：编译优化、ZRAM、CFI、SCS；只替换 boot 里的内核，不动 vendor_dlkm / system_dlkm。

## 性能

**手机上的运行性能**：和原厂内核用同一种优化方式编译。

- **AutoFDO**：原厂 GKI 是 Google 用 Kleaf 编的，会带上源码里的 `gki/aarch64/afdo/kernel.afdo`。这个文件是按真机负载采样得到的配置文件，编译器用它调整热点函数的内联和代码布局，冷代码拆到单独的段。之前的版本没带，只开了 `CONFIG_AUTOFDO_CLANG`，现在默认带上（`AUTOFDO=0` 可关）。KCFLAGS 也和官方一样加上 `-D__ANDROID_COMMON_KERNEL__`
- **其余内核配置和原厂逐项一致**（从原厂 boot.img 里提取 `ikconfig` 对比过），包括 `-O2`、LTO 关、HZ=250、ZRAM lzo-rle、CFI、SCS。只多了 KernelSU/SUSFS/NoMount/BBG/TTL/IP_SET，以及默认 TCP 拥塞控制 BBR（原厂是 cubic）
- **刻意不改的**：HZ、LTO、`-O3`、调度器之类。厂商驱动模块（vendor_dlkm）是按原厂配置编的，HZ 改了 jiffies 换算就错；原厂没开 LTO，开了之后目标文件变成 bitcode，符号 CRC 的计算方式跟着变，很可能和原厂对不上，那样所有厂商模块都会加载失败，卡第一屏。这些"超频式"改动在 GKI 上收益很小、风险是不开机，所以不做

> 带 AutoFDO 编出来的内核符号 CRC 已和原厂核对一致，但还没在真机上长期使用。`boot/` 里那个真机验证过的版本是不带 AutoFDO 编的，求稳就刷那个。

**编译速度**：

- 云端：clang/rust 工具链（约 5.5GB，按 manifest 里的版本做缓存键）、pahole 1.30 和 **ccache** 都存进 Actions 缓存。第一次和以前一样慢，之后不用再从 CodeLinaro 下工具链；只更新了 KernelSU/SUSFS 时绝大部分目标文件直接命中 ccache
- 本地：装了 `ccache` 就自动用（缓存在 `work/_cache/ccache`，上限 10GB，`USE_CCACHE=0` 关）

方案 A：`CONFIG_NOMOUNT=y`（NoMount 最新 tag），SUSFS OPEN_REDIRECT 关（避免和 NoMount 重叠），SUSFS sus_mount 编进去但可以少用。原来的方案 B（OverlayFS）已经移除，只保留 A。

## 真机验证过的版本

仓库 [`boot/`](boot/) 目录里放着**已经在真机上运行成功**的 boot.img（不在 Releases 里）：

| 机型 | 固件 | 文件 |
|---|---|---|
| 一加 15 CPH2747（欧版） | **OxygenOS 16 `CPH2747_16.0.10.601(EX01)`**，安全补丁 2026-09-01 | `boot/boot_OP15_schemeA_CPH2747_16.0.10.601_EX01.img` |

这个文件和手机 `boot_a` 分区逐字节一致（sha256 见 `boot/SHA256SUMS`），详细版本见 `boot/README.md` 和 `boot/build-info_schemeA.txt`。它是用 16.0.10.601 的原厂 boot.img 打包的，**只能刷在 16.0.10.601(EX01) 上**。

Releases 里的是自动编译的版本，没有经过真机测试。

## 自动编译（每 3 天）

`.github/workflows/build.yml` 每 3 天（UTC 20:00）自动跑一次：

1. **检查上游**（`scripts/upstream.sh`）：一加源码分支、你的 fork、`kernel_manifest`（工具链）、KernelSU main、SUSFS、NoMount 最新 tag、Baseband-guard，和上一次 Release 里的 `upstream.txt` 比较
2. **有更新才编译**，没有更新就跳过（Actions 页面的 Summary 里有对比表）
3. 编完自动发布到 **Releases**，说明里列出哪些组件更新了
4. 一加源码出现新的一加 15 分支（新底包）时会给出黄色警告，但不会自动换分支，需要你确认后改 `SRC_BRANCH`

**同步 fork**：编译优先用你账号下 fork 的 `android_kernel_common_oneplus_sm8850`。fork 落后时 Actions 会提示；想全自动同步，建一个只对这个 fork 有 Contents 读写权限的 fine-grained token，存成仓库 Secret `SYNC_TOKEN`。不想用 token 就去 fork 页面点 **Sync fork**。

**换固件后**：在仓库 Settings → Secrets and variables → Actions → **Variables** 里设置 `KERNEL_RELEASE`（新固件的 `uname -r`）和 `BUILD_TIMESTAMP`（`uname -v` 里的时间），并把 `stock-boot` Release 里的 boot.img 换成新固件的。不设置就用 16.0.10.601 的值。

注意：仓库 60 天没有任何提交，GitHub 会自动暂停定时任务，到 Actions 页面点一下 Enable 即可恢复。

## 手动云编译

1. 仓库页面 → **Actions** → **Build OnePlus 15 kernel** → **Run workflow**
2. `release` 默认勾选：编完自动发布到 **Releases**（手动运行不管上游有没有更新都会编）
3. 可选：`kernel_release` / `build_timestamp` 填原厂 `uname -r` / `uname -v` 里的时间来伪装版本号；`ksu_ref`、`susfs_ref`、`nomount_ref`、`bbg_ref` 指定组件版本
4. 等 1～2 小时，到 **Releases** 下载

发布的文件：

| 文件 | 用途 |
|---|---|
| `boot_*.img` | `fastboot flash boot boot_*.img` 直接刷 |
| `AnyKernel3_*.zip` | 管理器或第三方 Recovery 卡刷 |
| `Image_*` | 单独的内核文件，自己打包用 |
| `build-info_schemeA.txt` / `kernel_schemeA.config` | 版本信息和完整内核配置 |
| `upstream.txt` | 这次编译时各上游的版本，下次定时检查用 |

## KernelSU 和 SUSFS 的版本

- 默认拉 KernelSU 官方 `main` 最新提交，SUSFS 拉 `gki-android16-6.12` 分支最新提交
- SUSFS 的 KernelSU 补丁只跟到 SUSFS 作者同步过的那个 KernelSU 提交。如果最新 main 已经改得补丁打不上，脚本会自动退回到 SUSFS 最后同步的那个提交，日志里有黄色 `::warning::` 提示
- 实际用了哪个版本，看产物里的 `build-info_schemeA.txt`
- 想回到 SUSFS v2.2.0：`susfs_ref` 填 `f37930f374ef88de990d6abea0c67d0ea28c1edc`，`ksu_ref` 填 `953b403ab5ea2c1d866f72f6a7e67ce9224b8932`

工具链（clang r536225、rustc 1.82.0、bindgen）按一加 `kernel_manifest` 里 `oneplus_15.xml` 锁定的版本从 CodeLinaro 下载，和官方构建一致。

## 准备原厂 boot.img（生成 boot.img 需要）

boot.img 是拿原厂 boot.img 用 magiskboot 只换内核重新打包的，头部、cmdline、安全补丁日期都保持原厂，和 Magisk 修补的方式一样。所以需要先给一份原厂 boot.img：

1. 拿到和手机当前固件版本一致的 boot.img（从全量包 payload.bin 里解出来，或者有 root 时 `dd if=/dev/block/by-name/boot_a of=/sdcard/boot.img`，当前槽位是 b 就用 boot_b）
2. 仓库页面 → **Releases** → **Draft a new release**，tag 填 `stock-boot`，把文件命名为 `boot.img` 上传，发布
3. 以后升级固件，就把这个 release 里的 boot.img 换成新版本的

也可以在手动运行时用 `stock_boot_url` 直接填一个下载链接。没有原厂 boot.img 时照样编译，只是不出 boot.img。

## 本地编译（WSL 或任何 Linux）

`scripts/wsl-build.sh` 是本地编译脚本，名字里有 wsl，但在任何 **x86_64 Linux** 上都能用（工具链是 x86_64 的预编译版，ARM 主机不行）。底座和组件和云端完全一样。

需要：约 25GB 空闲磁盘、16GB 以上内存（8GB 请把 `JOBS` 调小）、能访问 GitHub / GitLab / CodeLinaro。

### 1. 装依赖

**Ubuntu / Debian / Linux Mint / WSL（Ubuntu 22.04、24.04）**

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  bc bison flex cpio zip unzip lz4 zstd python3 git curl rsync \
  libssl-dev libelf-dev libdw-dev libncurses-dev dwarves patch ca-certificates make gcc ccache
```

**Fedora / RHEL / Rocky / AlmaLinux**（RHEL 系先 `sudo dnf install -y epel-release` 并启用 CRB）

```bash
sudo dnf install -y bc bison flex cpio zip unzip lz4 zstd python3 git curl rsync \
  openssl-devel elfutils-libelf-devel elfutils-devel ncurses-devel dwarves patch \
  ca-certificates make gcc which diffutils findutils ccache
```

**Arch Linux / Manjaro / EndeavourOS**

```bash
sudo pacman -Syu --needed bc bison flex cpio zip unzip lz4 zstd python git curl rsync \
  openssl libelf elfutils ncurses pahole patch ca-certificates make gcc which diffutils ccache
```

**openSUSE Tumbleweed / Leap**

```bash
sudo zypper install -y bc bison flex cpio zip unzip lz4 zstd python3 git curl rsync \
  libopenssl-devel libelf-devel libdw-devel ncurses-devel dwarves patch \
  ca-certificates make gcc which diffutils ccache
```

**其他发行版**：对照上面装同样的东西即可。必须有的是 `dwarf.h`（libdw / elfutils 开发包，编译主机工具 gendwarfksyms 要用）、`libelf`、`openssl` 开发头文件和 `pahole`。

**pahole 版本**：要 1.26 以上，太旧（比如 Ubuntu 24.04 自带的 1.25）会在最后报 `FAILED: load BTF from vmlinux`。`pahole --version` 看一下，旧的话自己编一个新的：

```bash
sudo apt-get install -y cmake zlib1g-dev   # Fedora: cmake zlib-devel；Arch: cmake zlib
git clone --depth 1 --recurse-submodules --shallow-submodules -b v1.30 https://github.com/acmel/dwarves.git /tmp/dwarves
cmake -S /tmp/dwarves -B /tmp/dwarves/build -D__LIB=lib -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_BUILD_TYPE=Release
sudo make -C /tmp/dwarves/build -j"$(nproc)" install && sudo ldconfig && hash -r
pahole --version
```

Arch、Fedora 40+、openSUSE Tumbleweed 自带的 pahole 已经够新。

### 2. 拿仓库

```bash
cd ~ && git clone https://github.com/yuanluow/oneplus15-kernel-build.git op15 && cd op15
chmod +x scripts/wsl-build.sh
```

WSL 下一定要放在 Linux 目录（比如 `~/op15`），不要放 `/mnt/c`，否则软链接和权限会出问题。普通 Linux 放在任何 ext4 / btrfs / xfs 目录都行。

### 3. 编译

```bash
# 最简单：只出 AnyKernel3 zip 和 Image
./scripts/wsl-build.sh

# 伪装成原厂版本号，并打进原厂 boot.img（和 boot/ 里验证过的那个一样的参数）
KERNEL_RELEASE='6.12.58-android16-6-g925a103d123c-ab15898589-4k' \
BUILD_TIMESTAMP='Mon Jul 20 17:37:05 UTC 2026' \
STOCK_BOOT=~/boot_stock.img \
./scripts/wsl-build.sh
```

常用环境变量：`STOCK_BOOT`(原厂 boot.img 路径，给了才出 boot.img)、`KERNEL_RELEASE`/`BUILD_TIMESTAMP`(伪装版本号)、`SRC_OWNER`(用你 fork 的源码就填你的用户名)、`SUSFS_REF`(回退 v2.2.0 填 `f37930f374ef88de990d6abea0c67d0ea28c1edc`)、`KSU_REF`、`NOMOUNT_REF`、`BBG_REF`、`JOBS`(并行度，默认全部核心)、`BLOCK_MODULES`、`AUTOFDO`(默认 1)、`USE_CCACHE`(默认装了就用)。

想先看看上游现在是什么版本：`./scripts/upstream.sh`。

产物在 `dist/`：`AnyKernel3_*.zip`、`boot_*.img`、`Image_*`、`build-info_schemeA.txt`、`kernel_schemeA.config`。第一次会下约 1.5GB 压缩包（解压后约 5.5GB）的工具链、占约 30GB 磁盘（含 ccache）；重复跑会复用已下载的工具链和源码（全新来就删掉 `work/`）。

### 关于下载慢

工具链（约 1GB）从 CodeLinaro 下，速度由对方服务器决定，几 MB/s 是它的限速，换多线程下载器也快不了，所以脚本就用默认 curl。能省时间的是**共享缓存**：工具链、SUSFS、AnyKernel3、magiskboot 都存到 `work/_cache`，**同一个文件只下一次**，之后重复编直接复用，所以慢的只有第一次。想全新重下就删掉 `work/_cache`。

## 刷机

1. **先备份原厂 boot.img**，准备好 `fastboot flash boot boot.img` 刷回
2. 二选一：`fastboot flash boot boot_*.img`，或者用 KernelSU 管理器 / 第三方 Recovery 刷 AnyKernel3 zip
3. 第一次刷完不装模块，先确认：
   - 能开机，`uname -r` 正常
   - `cat /proc/sys/net/ipv4/tcp_congestion_control` 显示 `bbr`
   - `iptables -t mangle -A POSTROUTING -j TTL --ttl-set 64` 不报错
   - `ipset create test hash:ip` 不报错（测完 `ipset destroy test`）
   - `zcat /proc/config.gz | grep NOMOUNT` 显示 `=y`
4. 装 SUSFS 用户态模块（sidex15 `ksu_module_susfs`）
5. KernelSU v3 仍然需要一个元模块来挂载其他模块（挂载逻辑在用户态，没法编进内核）：装 NoMount 元模块，它会直接用内核里编好的 NoMount，不再加载自己的 LKM
6. 再逐个加其他模块；打开 Chase 等 App 挂几分钟确认不重启，崩了看 `/sys/fs/pstore`
