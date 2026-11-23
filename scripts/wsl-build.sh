#!/usr/bin/env bash
# =============================================================================
# OnePlus 15 (SM8850) GKI 内核 本地 WSL 编译脚本
#   6.12.58 + KernelSU(官方 main) + SUSFS + BBG + TTL + IP_SET + 默认 BBR
#   方案 A = NoMount 编进内核(SUSFS OPEN_REDIRECT 关)
#   方案 B = OverlayFS 内置     (SUSFS OPEN_REDIRECT 开)
#
# 和云端 GitHub Actions 用的是同一套逻辑。
#
# ---- 需要的系统(建议 Ubuntu 22.04 / 24.04 的 WSL)----
# 一次性安装依赖:
#   sudo apt-get update
#   sudo apt-get install -y --no-install-recommends \
#     bc bison flex cpio zip unzip lz4 zstd python3 git curl rsync \
#     libssl-dev libelf-dev libdw-dev libncurses-dev dwarves patch ca-certificates \
#     make gcc
#   # 打包 boot.img 的 magiskboot 脚本会自动下载,无需手动装。
#
# ---- 用法 ----
#   chmod +x scripts/wsl-build.sh
#   # 只编方案 A:
#   SCHEME=A ./scripts/wsl-build.sh
#   # 编方案 B,并把结果打进原厂 boot.img:
#   SCHEME=B STOCK_BOOT=~/boot_stock.img ./scripts/wsl-build.sh
#   # A、B 两套一次编完(各用独立源码目录,产物都进 dist/):
#   SCHEME=both STOCK_BOOT=~/boot_stock.img ./scripts/wsl-build.sh
#   # 伪装成原厂版本号(强烈建议,过版本号检测):
#   SCHEME=A \
#   KERNEL_RELEASE='6.12.58-android16-6-g925a103d123c-ab15898589-4k' \
#   BUILD_TIMESTAMP='Mon Jul 20 17:37:05 UTC 2026' \
#   STOCK_BOOT=~/boot_stock.img \
#   ./scripts/wsl-build.sh
#
# ---- 产物 ----
#   dist/ 目录下:
#     AnyKernel3_*.zip   卡刷包(管理器/Recovery 刷)
#     boot_*.img         新 boot.img(给了 STOCK_BOOT 才有,fastboot flash boot)
#     Image_*            单独内核文件
#     kernel.config      完整内核配置
#     build-info.txt     版本信息
#
# ⚠ 重要:
#   * 必须在 WSL 的 Linux 文件系统里跑(比如 ~/op15),不要放在 /mnt/c 下,
#     否则软链接、权限和速度都会出问题。
#   * 第一次会下载约 1.5GB 工具链 + 克隆源码,占用约 25GB 磁盘,留足空间。
# =============================================================================
set -euo pipefail

# -------- 参数(都可以用环境变量覆盖)--------
: "${SCHEME:?必须指定 SCHEME=A、B 或 both}"
: "${SRC_OWNER:=OnePlusOSS}"                 # 改成你的 GitHub 用户名可用你 fork 的源码
: "${KSU_REF:=main}"                          # KernelSU 版本(main=最新)
: "${SUSFS_REF:=gki-android16-6.12}"          # SUSFS 分支/提交(v2.2.0=f37930f374ef88de990d6abea0c67d0ea28c1edc)
: "${BBG_REF:=}"                              # Baseband-guard(空=main)
: "${NOMOUNT_REF:=}"                          # NoMount tag(空=最新 tag),仅方案 A 用
: "${KERNEL_RELEASE:=}"                       # 伪装的 uname -r(空=不伪装)
: "${BUILD_TIMESTAMP:=}"                      # 伪装的 uname -v 里的时间
: "${STOCK_BOOT:=}"                           # 原厂 boot.img 路径(空=不打包 boot.img)
: "${JOBS:=$(nproc)}"                         # 并行度

case "$SCHEME" in A|B|both) ;; *) echo "SCHEME 只能是 A、B 或 both"; exit 1 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# SCHEME=both: 依次编 A 和 B(各用独立源码目录,互不干扰),产物都进同一个 dist/
if [ "$SCHEME" = both ]; then
  echo "==> 依次编译方案 A 和 B"
  SCHEME=A "$0"
  SCHEME=B "$0"
  echo "==> A、B 两套都编完,产物在 $REPO_DIR/dist"
  ls -la "$REPO_DIR/dist"
  exit 0
fi

SRC_BRANCH="oneplus/sm8850_b_16.0.0_oneplus_15"
MANIFEST_URL="https://raw.githubusercontent.com/OnePlusOSS/kernel_manifest/oneplus/sm8850/oneplus_15.xml"
CLO="https://git.codelinaro.org/clo/la"

# 每个方案用独立的 work 目录,A 的 NoMount / 关 OPEN_REDIRECT 不会和 B 冲突
WORK="$REPO_DIR/work/scheme-$SCHEME"
DIST="$REPO_DIR/dist"
# 所有方案共享的下载缓存:工具链/SUSFS/AnyKernel3/magiskboot 只下一次,
# 编 both 或重复跑都复用,不会重复下 1GB 工具链
CACHE="$REPO_DIR/work/_cache"
mkdir -p "$WORK" "$DIST" "$CACHE"

# 如果在 /mnt/ 下(Windows 盘)直接拒绝,避免软链接/权限坑
case "$REPO_DIR" in /mnt/*) echo "❌ 请把仓库放到 WSL 的 Linux 目录(如 ~/op15),不要放在 /mnt/c 下。"; exit 1 ;; esac

group() { echo; echo "========== $* =========="; }
retry() { local n=0; until "$@"; do n=$((n+1)); [ $n -ge 5 ] && return 1; echo "重试 $n: $*"; sleep $((n*5)); done; }

# 下载(默认 curl)。大文件慢主要是服务器端限速,换下载器也快不了。
# 真正省时间的是下方的共享缓存:同一个文件只下一次。
dl() { # url outfile
  local url="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  retry curl -fL --retry 3 -o "$out" "$url"
}

# ---------------------------------------------------------------- 源码
group "克隆内核源码"
if [ ! -d "$WORK/common/.git" ]; then
  rm -rf "$WORK/common"
  if ! retry git clone --depth=1 -b "$SRC_BRANCH" "https://github.com/$SRC_OWNER/android_kernel_common_oneplus_sm8850.git" "$WORK/common"; then
    echo "找不到 $SRC_OWNER 的 fork,改用 OnePlusOSS 官方源"
    rm -rf "$WORK/common"
    retry git clone --depth=1 -b "$SRC_BRANCH" "https://github.com/OnePlusOSS/android_kernel_common_oneplus_sm8850.git" "$WORK/common"
  fi
else
  echo "已存在 work/common,跳过克隆(要重新来请删掉 work/ 目录)"
fi
cd "$WORK/common"
SRC_COMMIT="$(git rev-parse HEAD)"
SRC_SUBJECT="$(git log -1 --format=%s)"
SRC_EPOCH="$(git log -1 --format=%ct)"
KVER="$(make -s kernelversion)"
echo "源码: $SRC_COMMIT"
echo "内核版本: $KVER"
[ "$KVER" = "6.12.58" ] || echo "⚠ 期望 6.12.58,实际 $KVER"
. build.config.constants   # CLANG_VERSION / RUSTC_VERSION
echo "CLANG_VERSION=$CLANG_VERSION RUSTC_VERSION=$RUSTC_VERSION"
cd "$WORK"

# ---------------------------------------------------------------- 工具链(共享缓存)
group "下载工具链(和一加官方同版本,存到共享缓存)"
dl "$MANIFEST_URL" "$CACHE/manifest.xml"
rev_of() { MANIFEST="$CACHE/manifest.xml" python3 - "$1" <<'PY'
import sys, os, xml.etree.ElementTree as ET
name = sys.argv[1]
for p in ET.parse(os.environ["MANIFEST"]).getroot().iter("project"):
    if p.get("name") == name:
        print(p.get("revision")); break
PY
}
CLANG_REV="$(rev_of kernelplatform/prebuilts-master/clang/host/linux-x86)"
RUST_REV="$(rev_of kernel_platform/prebuilts/rust)"
TOOLS_REV="$(rev_of kernel_platform/prebuilts/clang-tools)"
[ -n "$CLANG_REV" ] && [ -n "$RUST_REV" ] && [ -n "$TOOLS_REV" ] || { echo "❌ manifest 里没读到工具链版本"; exit 1; }

fetch_subdir() { # project rev subdir dest
  local proj="$1" rev="$2" sub="$3" dest="$4" name
  name="$(basename "$proj")"
  [ -d "$dest" ] && { echo "已缓存 $dest,跳过下载"; return 0; }
  dl "$CLO/$proj/-/archive/$rev/$name-$rev.tar.gz?path=$sub" "$dest.tar.gz"
  mkdir -p "$dest"
  tar -xzf "$dest.tar.gz" -C "$dest"
  rm -f "$dest.tar.gz"
}
fetch_subdir kernelplatform/prebuilts-master/clang/host/linux-x86 "$CLANG_REV" "clang-$CLANG_VERSION" "$CACHE/tc-clang"
fetch_subdir kernel_platform/prebuilts/rust "$RUST_REV" "linux-x86/${RUSTC_VERSION%.p*}" "$CACHE/tc-rust"
fetch_subdir kernel_platform/prebuilts/clang-tools "$TOOLS_REV" "linux-x86/bin" "$CACHE/tc-tools"

CLANG_BIN="$(dirname "$(find "$CACHE/tc-clang" -path '*/bin/clang' | head -n1)")"
RUST_BIN="$(dirname "$(find "$CACHE/tc-rust" -path '*/bin/rustc' | head -n1)")"
BINDGEN_BIN="$(dirname "$(find "$CACHE/tc-tools" -path '*/bin/bindgen' | head -n1)")"
RUST_ROOT="$(dirname "$RUST_BIN")"
chmod +x "$BINDGEN_BIN/bindgen" || true
export PATH="$CLANG_BIN:$RUST_BIN:$BINDGEN_BIN:$PATH"
export LIBCLANG_PATH="$(dirname "$CLANG_BIN")/lib"
clang --version | head -n1
rustc --version

# ---------------------------------------------------------------- SUSFS(补丁源用共享缓存)
group "打 SUSFS 补丁 ($SUSFS_REF)"
[ -d "$CACHE/susfs" ] || retry git clone https://gitlab.com/simonpunk/susfs4ksu.git "$CACHE/susfs"
git -C "$CACHE/susfs" fetch -q --all 2>/dev/null || true
git -C "$CACHE/susfs" checkout -q "$SUSFS_REF"
SUSFS_DESC="$(git -C "$CACHE/susfs" rev-parse --short HEAD), $(git -C "$CACHE/susfs" log -1 --format=%cs)"
cp -v "$CACHE"/susfs/kernel_patches/fs/* common/fs/
cp -v "$CACHE"/susfs/kernel_patches/include/linux/* common/include/linux/
# 上游 bug:关日志时 susfs.c 没定义 SUSFS_LOGI_RL/SUSFS_LOGE_RL,补两个空宏
if [ "$(grep -c 'define SUSFS_LOGI_RL' common/fs/susfs.c)" = 1 ]; then
  sed -i 's/^#define SUSFS_LOGE(fmt, \.\.\.)[[:space:]]*$/&\n#define SUSFS_LOGI_RL(fmt, ...)\n#define SUSFS_LOGE_RL(fmt, ...)/' common/fs/susfs.c
  [ "$(grep -c 'define SUSFS_LOGI_RL' common/fs/susfs.c)" = 2 ] || { echo "❌ 补 SUSFS_LOG*_RL 空宏失败"; exit 1; }
fi
SUSFS_PATCH="$CACHE/susfs/kernel_patches/50_add_susfs_in_gki-android16-6.12.patch"
# 幂等:如果已经打过就跳过(重复跑脚本时)
if grep -q 'CONFIG_KSU_SUSFS' common/fs/open.c 2>/dev/null; then
  echo "SUSFS 似乎已打过,跳过"
else
  (cd common && patch -p1 --forward --no-backup-if-mismatch < "$SUSFS_PATCH") || true
  REJ="$(cd common && find . -name '*.rej' | sort)"
  if [ "$REJ" = "./fs/proc/task_mmu.c.rej" ]; then
    echo "⚠ task_mmu.c 补丁冲突(已知),用 fix_task_mmu.py 移植"
    python3 -I "$REPO_DIR/scripts/fix_task_mmu.py" common/fs/proc/task_mmu.c
    rm -f common/fs/proc/task_mmu.c.rej
  elif [ -n "$REJ" ]; then
    echo "❌ SUSFS 补丁有冲突:"; (cd common && for f in $REJ; do echo "== $f"; cat "$f"; done)
    exit 1
  fi
fi

# ---------------------------------------------------------------- KernelSU
group "加 KernelSU ($KSU_REF)"
if [ ! -d common/KernelSU ]; then
  (cd common && curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s "$KSU_REF")
fi
KSU_PATCH="$CACHE/susfs/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"
if ! grep -q 'KSU_SUSFS' common/KernelSU/kernel/Kconfig 2>/dev/null; then
  ksu_ok() { (cd common/KernelSU && patch -p1 --forward --dry-run -s < "$KSU_PATCH" >/dev/null); }
  if ! ksu_ok; then
    SYNC_REF="$(git -C "$CACHE/susfs" log -n 100 --format=%B | grep -oP 'tiann/KernelSU/commit/\K[0-9a-f]{40}' | head -n1 || true)"
    echo "⚠ 最新 KernelSU 补丁打不上,回退到 SUSFS 同步点 ${SYNC_REF:-<无>}"
    [ -n "$SYNC_REF" ] || { echo "❌ SUSFS 历史里找不到 KernelSU 同步点"; exit 1; }
    git -C common/KernelSU checkout -q "$SYNC_REF"
    ksu_ok || { echo "❌ 在 $SYNC_REF 上补丁也打不上"; exit 1; }
  fi
  (cd common/KernelSU && patch -p1 --forward --no-backup-if-mismatch < "$KSU_PATCH")
fi
KSU_DESC="$(git -C common/KernelSU describe --tags --always) ($(git -C common/KernelSU log -1 --format=%cs))"
echo "KernelSU: $KSU_DESC"
# 6.10+ 的 kbuild 里 $(src) 已带 $(srctree),O=out 时 srctree 是 "..",
# KernelSU 拼出来的 include 路径是错的(找不到 uapi/app_profile.h),改成绝对路径
if ! grep -q 'KSU_KERNEL_DIR := $(abspath $(srctree))/drivers/kernelsu' common/KernelSU/kernel/Kbuild; then
  sed -i 's|^ccflags-y += -I$(KSU_KERNEL_DIR) -I$(KSU_KERNEL_DIR)/include|KSU_KERNEL_DIR := $(abspath $(srctree))/drivers/kernelsu\n&|' common/KernelSU/kernel/Kbuild
  grep -q 'KSU_KERNEL_DIR := $(abspath $(srctree))/drivers/kernelsu' common/KernelSU/kernel/Kbuild || { echo "❌ 修 KSU_KERNEL_DIR 失败"; exit 1; }
fi

# ---------------------------------------------------------------- NoMount(方案 A)
NOMOUNT_DESC="未包含"
if [ "$SCHEME" = A ] && [ ! -d common/NoMount ]; then
  group "加 NoMount(编进内核)"
  (cd common && curl -LSs "https://raw.githubusercontent.com/maxsteeel/nomount/master/kernel/setup.sh" | bash -s ${NOMOUNT_REF:+"$NOMOUNT_REF"})
  NOMOUNT_DESC="$(git -C common/NoMount describe --tags --always) (built-in)"
elif [ "$SCHEME" = A ]; then
  NOMOUNT_DESC="$(git -C common/NoMount describe --tags --always) (built-in)"
fi

# ---------------------------------------------------------------- Baseband-guard
if [ ! -d common/Baseband-guard ]; then
  group "加 Baseband-guard"
  (cd common && curl -LSs "https://raw.githubusercontent.com/vc-teahouse/Baseband-guard/main/setup.sh" | bash -s ${BBG_REF:+"$BBG_REF"})
fi

# ---------------------------------------------------------------- 配置
group "生成配置"
cd common
# 幂等:先确保 defconfig 没被重复追加
if ! grep -q 'oneplus15-kernel-build' arch/arm64/configs/gki_defconfig; then
  cat "$REPO_DIR/configs/common.config" "$REPO_DIR/configs/scheme-$SCHEME.config" >> arch/arm64/configs/gki_defconfig
fi

MAKE_ARGS=(O=out ARCH=arm64 LLVM=1 LLVM_IAS=1
  RUSTC=rustc HOSTRUSTC=rustc BINDGEN=bindgen
  RUST_LIB_SRC="$RUST_ROOT/lib/rustlib/src/rust/library")

make "${MAKE_ARGS[@]}" gki_defconfig

# baseband_guard 接到 CONFIG_LSM 末尾(保留原厂的所有项)
CUR_LSM="$(sed -n 's/^CONFIG_LSM="\(.*\)"$/\1/p' out/.config)"
case ",$CUR_LSM," in *,baseband_guard,*) ;; *)
  scripts/config --file out/.config --set-str LSM "${CUR_LSM:+$CUR_LSM,}baseband_guard" ;;
esac

# 版本号伪装
if [ -n "$KERNEL_RELEASE" ]; then
  case "$KERNEL_RELEASE" in "$KVER"*) ;; *) echo "❌ KERNEL_RELEASE 必须以 $KVER 开头"; exit 1 ;; esac
  SUFFIX="${KERNEL_RELEASE#"$KVER"}"
  scripts/config --file out/.config --set-str LOCALVERSION "$SUFFIX" -d LOCALVERSION_AUTO
  export LOCALVERSION=""
fi
make "${MAKE_ARGS[@]}" olddefconfig

# 校验关键选项都在
fail=0
need_y() { grep -q "^CONFIG_$1=y$" out/.config || { echo "❌ CONFIG_$1 不是 =y"; fail=1; }; }
need_n() { ! grep -q "^CONFIG_$1=y$" out/.config || { echo "❌ CONFIG_$1 应该关闭"; fail=1; }; }
for o in KSU KSU_SUSFS KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_KSTAT KSU_SUSFS_SPOOF_UNAME \
         BBG TCP_CONG_BBR DEFAULT_BBR NETFILTER_XT_TARGET_HL IP_NF_TARGET_TTL IP6_NF_TARGET_HL \
         IP_SET IP_SET_HASH_IP IP_SET_HASH_NET IP_SET_HASH_IPPORT IP_SET_BITMAP_IP NETFILTER_XT_SET \
         OVERLAY_FS CFI_CLANG SHADOW_CALL_STACK; do need_y "$o"; done
if [ "$SCHEME" = A ]; then need_n KSU_SUSFS_OPEN_REDIRECT; need_y NOMOUNT; else need_y KSU_SUSFS_OPEN_REDIRECT; fi
grep -q '^CONFIG_DEFAULT_TCP_CONG="bbr"$' out/.config || { echo "❌ 默认 TCP 拥塞不是 bbr"; fail=1; }
[ $fail -eq 0 ] || { echo "配置校验失败,停止"; exit 1; }

# 提交改动,避免版本号带 -dirty
echo "/out/" >> .git/info/exclude
# 新版 glibc(2.42+,如 Ubuntu 25.10)里 strstr/strchr 返回 const char *,
# 内核自带 libbpf 开了 -Werror 会编不过(resolve_btfids),加显式转换
sed -i -E 's/= (strstr|strchr)\(/= (char *)\1(/' tools/lib/bpf/libbpf.c
git add -A >/dev/null 2>&1 || true
git -c user.name=kleaf -c user.email=kleaf@build-host commit -qm "local build" || true

# ---------------------------------------------------------------- 编译
group "编译内核(约 20~60 分钟,看 CPU)"
export KBUILD_BUILD_USER=kleaf
export KBUILD_BUILD_HOST=build-host
export SOURCE_DATE_EPOCH="$SRC_EPOCH"
[ -n "$BUILD_TIMESTAMP" ] && export KBUILD_BUILD_TIMESTAMP="$BUILD_TIMESTAMP"
# Google 官方(kleaf)用 gendwarfksyms --stable 算符号 CRC(会处理 ANDROID_KABI_* 标记)。
# 不开的话 CRC 和原厂对不上,厂商驱动模块全部加载失败,开机卡第一屏。
export KBUILD_GENDWARFKSYMS_STABLE=1
# 以前没开 --stable 编过的旧产物,CRC 不会自动重算,必须清掉重编
if [ -d out ] && [ ! -f out/.gendwarfksyms_stable ]; then
  echo "检测到旧的编译产物(未开 --stable),清理后重新编译"
  make "${MAKE_ARGS[@]}" clean >/dev/null
fi
make "${MAKE_ARGS[@]}" -j"$JOBS" KCFLAGS="-Wno-error" Image
touch out/.gendwarfksyms_stable
test -f out/arch/arm64/boot/Image
KREL="$(make -s "${MAKE_ARGS[@]}" kernelrelease)"
echo "kernelrelease: $KREL"

# 和原厂内核对比符号 CRC,对不上说明刷了也开不了机
if [ -n "$STOCK_BOOT" ] && [ -f "$STOCK_BOOT" ]; then
  group "校验符号 CRC(和原厂对比)"
  python3 "$REPO_DIR/scripts/check_crc.py" out/vmlinux.symvers gki/aarch64/symbols "$STOCK_BOOT" \
    || { echo "❌ 符号 CRC 和原厂不一致,这个内核刷进去会卡第一屏,不要刷"; exit 1; }
else
  echo "⚠️ 没给 STOCK_BOOT,没法校验 CRC,不能保证能开机"
fi

# ---------------------------------------------------------------- 打包
group "打包"
cd "$WORK"
AK3="$CACHE/ak3"
[ -d "$AK3" ] || retry git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git "$AK3"
rm -rf "$AK3"/.git "$AK3"/.github "$AK3"/README.md "$AK3"/modules "$AK3"/patch "$AK3"/ramdisk
cp "$REPO_DIR/ak3/anykernel.sh" "$AK3/anykernel.sh"
cp common/out/arch/arm64/boot/Image "$AK3/Image"
NAME="OP15_${KREL}_scheme${SCHEME}_$(date -u +%Y%m%d)"
(cd "$AK3" && zip -qr9 "$DIST/AnyKernel3_$NAME.zip" .)
cp common/out/arch/arm64/boot/Image "$DIST/Image_$NAME"
cp common/out/.config "$DIST/kernel_scheme$SCHEME.config"

# boot.img(可选)
BOOT_DESC="未生成(没给 STOCK_BOOT)"
if [ -n "$STOCK_BOOT" ] && [ -f "$STOCK_BOOT" ]; then
  group "重新打包 boot.img"
  mkdir -p "$CACHE/mb" "$WORK/bootwork"
  if [ ! -x "$CACHE/mb/magiskboot" ]; then
    # Magisk 的 Release 文件名带版本号(Magisk-v31.1.apk),先从 API 查出真实下载地址
    MAGISK_URL="$(curl -fsSL https://api.github.com/repos/topjohnwu/Magisk/releases/latest \
      | grep -o '"browser_download_url": *"[^"]*/Magisk-v[^"]*\.apk"' | head -n1 | sed 's/.*"\(https[^"]*\)"$/\1/')"
    [ -n "$MAGISK_URL" ] || { echo "❌ 查不到 Magisk 最新版的下载地址"; exit 1; }
    dl "$MAGISK_URL" "$CACHE/mb/magisk.apk"
    unzip -o "$CACHE/mb/magisk.apk" 'lib/x86_64/libmagiskboot.so' -d "$CACHE/mb" >/dev/null
    cp "$CACHE/mb/lib/x86_64/libmagiskboot.so" "$CACHE/mb/magiskboot"
    chmod +x "$CACHE/mb/magiskboot"
  fi
  MB="$CACHE/mb/magiskboot"
  cd "$WORK/bootwork"; rm -f kernel ramdisk.cpio* *.img
  cp "$STOCK_BOOT" stock.img
  "$MB" unpack stock.img
  [ -f kernel ] || { echo "❌ 这个 boot.img 里没有 kernel(是不是传错成 init_boot/vendor_boot 了?)"; exit 1; }
  cp "$WORK/common/out/arch/arm64/boot/Image" kernel
  "$MB" repack stock.img "$DIST/boot_$NAME.img"
  BOOT_DESC="由原厂 boot.img 重新打包"
  cd "$WORK"
fi

cat > "$DIST/build-info_scheme$SCHEME.txt" <<EOF
scheme          : $SCHEME ($([ "$SCHEME" = A ] && echo "NoMount 内置, SUSFS OPEN_REDIRECT 关" || echo "OverlayFS 内置, SUSFS OPEN_REDIRECT 开"))
kernelrelease   : $KREL
source          : $SRC_OWNER @ $SRC_COMMIT
                  $SRC_SUBJECT
KernelSU        : $KSU_DESC
SUSFS           : $SUSFS_REF ($SUSFS_DESC)
NoMount         : $NOMOUNT_DESC
Baseband-guard  : ${BBG_REF:-main}
boot.img        : $BOOT_DESC
clang           : $(clang --version | head -n1)
Image sha256    : $(sha256sum "$DIST/Image_$NAME" | cut -d' ' -f1)
EOF

group "完成"
echo "产物在 $DIST :"
ls -la "$DIST"
echo
echo "刷机前务必备份原厂 boot.img。先不装模块,确认能开机、uname 正常、BBR 生效,再逐个加模块。"
