#!/usr/bin/env bash
# OnePlus 15 (SM8850) GKI kernel: 6.12.58 + KernelSU + SUSFS v2.2.0 + BBG + TTL + IP_SET + BBR default
# Scheme A only: NoMount built in, SUSFS OPEN_REDIRECT off (scheme B / OverlayFS was dropped)
set -euo pipefail

: "${SCHEME:=A}"
: "${SRC_OWNER:=OnePlusOSS}"
: "${KSU_REF:=main}"
: "${SUSFS_REF:=gki-android16-6.12}"
: "${BBG_REF:=}"
: "${NOMOUNT_REF:=}"
: "${KERNEL_RELEASE:=}"
: "${BUILD_TIMESTAMP:=}"
: "${TC_DIR:=}"            # toolchain dir (CI caches it); empty = inside work/
: "${USE_CCACHE:=auto}"    # auto = use ccache when it is installed, 0 = never
: "${AUTOFDO:=1}"          # 1 = compile with the stock AutoFDO profile (what Kleaf does for GKI)

[ "$SCHEME" = A ] || { echo "::error::only scheme A (NoMount) is supported"; exit 1; }

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$REPO_DIR/work"
DIST="$REPO_DIR/dist"
SRC_BRANCH="oneplus/sm8850_b_16.0.0_oneplus_15"
MANIFEST_URL="https://raw.githubusercontent.com/OnePlusOSS/kernel_manifest/oneplus/sm8850/oneplus_15.xml"
CLO="https://git.codelinaro.org/clo/la"

mkdir -p "$WORK" "$DIST"
cd "$WORK"

group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }

retry() { local n=0; until "$@"; do n=$((n+1)); [ $n -ge 5 ] && return 1; echo "retry $n: $*"; sleep $((n*10)); done; }

# ---------------------------------------------------------------- source
group "Clone kernel source"
if ! retry git clone --depth=1 -b "$SRC_BRANCH" "https://github.com/$SRC_OWNER/android_kernel_common_oneplus_sm8850.git" common; then
  echo "::warning::Fork under $SRC_OWNER not found, falling back to OnePlusOSS"
  rm -rf common
  retry git clone --depth=1 -b "$SRC_BRANCH" https://github.com/OnePlusOSS/android_kernel_common_oneplus_sm8850.git common
fi
SRC_COMMIT="$(git -C common rev-parse HEAD)"
SRC_SUBJECT="$(git -C common log -1 --format=%s)"
SRC_EPOCH="$(git -C common log -1 --format=%ct)"
KVER="$(make -s -C common kernelversion)"
echo "Source: $SRC_COMMIT  $SRC_SUBJECT"
echo "Kernel version: $KVER"
[ "$KVER" = "6.12.58" ] || echo "::warning::Expected 6.12.58, got $KVER"
. common/build.config.constants   # CLANG_VERSION, RUSTC_VERSION
echo "CLANG_VERSION=$CLANG_VERSION RUSTC_VERSION=$RUSTC_VERSION"
endgroup

# ---------------------------------------------------------------- toolchains (same revisions as OnePlus manifest)
group "Download toolchains"
curl -fsSL --retry 5 "$MANIFEST_URL" -o manifest.xml
rev_of() { python3 - "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
name = sys.argv[1]
for p in ET.parse("manifest.xml").getroot().iter("project"):
    if p.get("name") == name:
        print(p.get("revision")); break
PY
}
CLANG_REV="$(rev_of kernelplatform/prebuilts-master/clang/host/linux-x86)"
RUST_REV="$(rev_of kernel_platform/prebuilts/rust)"
TOOLS_REV="$(rev_of kernel_platform/prebuilts/clang-tools)"
echo "clang rev=$CLANG_REV rust rev=$RUST_REV clang-tools rev=$TOOLS_REV"
[ -n "$CLANG_REV" ] && [ -n "$RUST_REV" ] && [ -n "$TOOLS_REV" ] || { echo "::error::could not read toolchain revisions from manifest"; exit 1; }

TC_DIR="${TC_DIR:-$WORK}"
mkdir -p "$TC_DIR"
fetch_subdir() { # project rev subdir dest
  local proj="$1" rev="$2" sub="$3" dest="$4" name
  name="$(basename "$proj")"
  # .rev marks a complete download of exactly this revision (restored from the Actions cache)
  if [ "$(cat "$dest/.rev" 2>/dev/null)" = "$rev $sub" ]; then echo "cached: $dest ($sub)"; return 0; fi
  rm -rf "$dest"; mkdir -p "$dest"
  retry curl -fL --retry 3 -o "$dest.tar.gz" "$CLO/$proj/-/archive/$rev/$name-$rev.tar.gz?path=$sub"
  tar -xzf "$dest.tar.gz" -C "$dest"
  rm -f "$dest.tar.gz"
  echo "$rev $sub" > "$dest/.rev"
}
fetch_subdir kernelplatform/prebuilts-master/clang/host/linux-x86 "$CLANG_REV" "clang-$CLANG_VERSION" "$TC_DIR/tc-clang"
fetch_subdir kernel_platform/prebuilts/rust "$RUST_REV" "linux-x86/${RUSTC_VERSION%.p*}" "$TC_DIR/tc-rust"
fetch_subdir kernel_platform/prebuilts/clang-tools "$TOOLS_REV" "linux-x86/bin" "$TC_DIR/tc-tools"

CLANG_BIN="$(dirname "$(find "$TC_DIR/tc-clang" -path '*/bin/clang' | head -n1)")"
RUST_BIN="$(dirname "$(find "$TC_DIR/tc-rust" -path '*/bin/rustc' | head -n1)")"
BINDGEN_BIN="$(dirname "$(find "$TC_DIR/tc-tools" -path '*/bin/bindgen' | head -n1)")"
RUST_ROOT="$(dirname "$RUST_BIN")"
chmod +x "$BINDGEN_BIN/bindgen" || true
export PATH="$CLANG_BIN:$RUST_BIN:$BINDGEN_BIN:$PATH"
export LIBCLANG_PATH="$(dirname "$CLANG_BIN")/lib"
clang --version | head -n1
rustc --version
bindgen --version || echo "::warning::bindgen did not run"
endgroup

# ---------------------------------------------------------------- SUSFS
group "Apply SUSFS ($SUSFS_REF)"
retry git clone --filter=blob:none https://gitlab.com/simonpunk/susfs4ksu.git susfs
git -C susfs checkout -q "$SUSFS_REF"
SUSFS_DESC="$(git -C susfs rev-parse --short HEAD), $(git -C susfs log -1 --format=%cs)"
echo "SUSFS: $SUSFS_DESC"
cp -v susfs/kernel_patches/fs/* common/fs/
cp -v susfs/kernel_patches/include/linux/* common/include/linux/
# Upstream bug: with ENABLE_LOG off, susfs.c defines no SUSFS_LOGI_RL/SUSFS_LOGE_RL -> add empty ones
if [ "$(grep -c 'define SUSFS_LOGI_RL' common/fs/susfs.c)" = 1 ]; then
  sed -i 's/^#define SUSFS_LOGE(fmt, \.\.\.)[[:space:]]*$/&\n#define SUSFS_LOGI_RL(fmt, ...)\n#define SUSFS_LOGE_RL(fmt, ...)/' common/fs/susfs.c
  [ "$(grep -c 'define SUSFS_LOGI_RL' common/fs/susfs.c)" = 2 ] || { echo "::error::could not add empty SUSFS_LOG*_RL macros"; exit 1; }
fi
SUSFS_PATCH="$(ls susfs/kernel_patches/50_add_susfs_in_gki-android16-6.12.patch)"
(cd common && patch -p1 --forward --no-backup-if-mismatch < "$WORK/$SUSFS_PATCH") || true
REJ="$(cd common && find . -name '*.rej' | sort)"
if [ "$REJ" = "./fs/proc/task_mmu.c.rej" ]; then
  # Known: OnePlus 6.12.58 task_mmu.c differs from upstream SUSFS target; port the SUS_MAP hunks
  echo "::warning::SUSFS task_mmu.c hunks rejected, applying OnePlus port (scripts/fix_task_mmu.py)"
  python3 -I "$REPO_DIR/scripts/fix_task_mmu.py" common/fs/proc/task_mmu.c
  rm -f common/fs/proc/task_mmu.c.rej
elif [ -n "$REJ" ]; then
  echo "::error::SUSFS kernel patch did not apply cleanly. Rejected hunks:"
  (cd common && for f in $REJ; do echo "== $f"; cat "$f"; done)
  exit 1
fi
endgroup

# ---------------------------------------------------------------- KernelSU
group "Add KernelSU ($KSU_REF)"
(cd common && curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s "$KSU_REF")
KSU_PATCH="$WORK/susfs/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"
ksu_patch_ok() { (cd common/KernelSU && patch -p1 --forward --dry-run -s < "$KSU_PATCH" >/dev/null); }
if ! ksu_patch_ok; then
  # Latest KernelSU moved past what SUSFS supports: fall back to the KernelSU commit SUSFS last synced with
  SYNC_REF="$(git -C susfs log -n 100 --format=%B | grep -oP 'tiann/KernelSU/commit/\K[0-9a-f]{40}' | head -n1 || true)"
  echo "::warning::SUSFS KernelSU patch does not apply on $KSU_REF, falling back to SUSFS sync point ${SYNC_REF:-<none>}"
  [ -n "$SYNC_REF" ] || { echo "::error::no KernelSU sync point found in SUSFS history"; exit 1; }
  git -C common/KernelSU checkout -q "$SYNC_REF"
  ksu_patch_ok || { echo "::error::SUSFS KernelSU patch does not apply even on $SYNC_REF"; exit 1; }
fi
(cd common/KernelSU && patch -p1 --forward --no-backup-if-mismatch < "$KSU_PATCH")
KSU_DESC="$(git -C common/KernelSU describe --tags --always) ($(git -C common/KernelSU rev-parse --short HEAD), $(git -C common/KernelSU log -1 --format=%cs))"
echo "KernelSU: $KSU_DESC"
# On 6.10+ kbuild, $(src) already contains $(srctree) and srctree is ".." for O=out,
# so KernelSU's "$(srctree)/$(src)" include dir is wrong (uapi/app_profile.h not found).
# Pin it to the absolute in-tree path.
if ! grep -q 'KSU_KERNEL_DIR := $(abspath $(srctree))/drivers/kernelsu' common/KernelSU/kernel/Kbuild; then
  sed -i 's|^ccflags-y += -I$(KSU_KERNEL_DIR) -I$(KSU_KERNEL_DIR)/include|KSU_KERNEL_DIR := $(abspath $(srctree))/drivers/kernelsu\n&|' common/KernelSU/kernel/Kbuild
  grep -q 'KSU_KERNEL_DIR := $(abspath $(srctree))/drivers/kernelsu' common/KernelSU/kernel/Kbuild || { echo "::error::could not fix KSU_KERNEL_DIR"; exit 1; }
fi
endgroup

# ---------------------------------------------------------------- NoMount (scheme A, built in)
NOMOUNT_DESC="not included"
if [ "$SCHEME" = A ]; then
  group "Add NoMount (built-in)"
  (cd common && curl -LSs "https://raw.githubusercontent.com/maxsteeel/nomount/master/kernel/setup.sh" | bash -s ${NOMOUNT_REF:+"$NOMOUNT_REF"})
  NOMOUNT_DESC="$(git -C common/NoMount describe --tags --always) (built-in)"
  echo "NoMount: $NOMOUNT_DESC"
  endgroup
fi

# ---------------------------------------------------------------- unicode bypass fix
# Blocks the zero-width-character trick that lets apps see /sdcard/Android/data/<pkg>
# of hidden apps (Duck Detector "Android/data ZWC / Ignorable CodePoint Bypass").
group "Apply unicode bypass fix"
UNI_PATCH="$REPO_DIR/patches/unicode_bypass_fix.patch"
if (cd common && patch -p1 -R --dry-run -s < "$UNI_PATCH" >/dev/null 2>&1); then
  echo "already applied"
else
  (cd common && patch -p1 --forward --no-backup-if-mismatch < "$UNI_PATCH") \
    || { echo "::error::unicode bypass fix did not apply to fs/unicode/utf8-norm.c"; exit 1; }
fi
endgroup

# ---------------------------------------------------------------- built-in modules
# fgetpriority (hide other app UIDs from getpriority/ioprio) and sg_unblock
# (never load oplus_secure_guard_new), compiled in instead of KernelSU modules.
group "Build in fgetpriority + vendor module block list"
python3 -I "$REPO_DIR/scripts/builtin_mods.py" common "$REPO_DIR" "${BLOCK_MODULES-oplus_secure_guard_new}"
endgroup

# ---------------------------------------------------------------- Baseband-guard
group "Add Baseband-guard"
(cd common && curl -LSs "https://raw.githubusercontent.com/vc-teahouse/Baseband-guard/main/setup.sh" | bash -s ${BBG_REF:+"$BBG_REF"})
endgroup

# ---------------------------------------------------------------- config
group "Configure"
cd common
cat "$REPO_DIR/configs/common.config" "$REPO_DIR/configs/scheme-$SCHEME.config" >> arch/arm64/configs/gki_defconfig

MAKE_ARGS=(O=out ARCH=arm64 LLVM=1 LLVM_IAS=1
  RUSTC=rustc HOSTRUSTC=rustc BINDGEN=bindgen
  RUST_LIB_SRC="$RUST_ROOT/lib/rustlib/src/rust/library")

# Same flags as Google's Kleaf GKI build (common/BUILD.bazel kernel_aarch64):
# KCFLAGS from build.config.common and the AutoFDO profile shipped in the source.
# Without the profile, CONFIG_AUTOFDO_CLANG=y only adds debug info and the kernel
# misses the profile-guided layout/inlining the stock kernel has.
KCFLAGS_EXTRA="-D__ANDROID_COMMON_KERNEL__"
AFDO_PROFILE="$PWD/gki/aarch64/afdo/kernel.afdo"
AFDO_DESC="off"
if [ "$AUTOFDO" = 1 ] && [ -s "$AFDO_PROFILE" ]; then
  MAKE_ARGS+=(CLANG_AUTOFDO_PROFILE="$AFDO_PROFILE")
  AFDO_DESC="gki/aarch64/afdo/kernel.afdo (sha256 $(sha256sum "$AFDO_PROFILE" | cut -c1-12))"
elif [ "$AUTOFDO" = 1 ]; then
  echo "::warning::gki/aarch64/afdo/kernel.afdo not found, building without AutoFDO profile"
fi
echo "AutoFDO profile: $AFDO_DESC"

# ccache: big win when only KernelSU/SUSFS changed (most objects are reused)
CCACHE_DESC="off"
if [ "$USE_CCACHE" != 0 ] && command -v ccache >/dev/null; then
  # CC only: rust/Makefile uses -Clinker=$(HOSTCC), which breaks on "ccache clang"
  MAKE_ARGS+=(CC="ccache clang")
  export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
  export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"
  export CCACHE_COMPILERCHECK="string:$CLANG_REV"
  # fresh git checkouts have brand-new mtimes; let direct mode work anyway
  export CCACHE_SLOPPINESS="file_stat_matches,include_file_ctime,include_file_mtime,pch_defines,time_macros,locale"
  [ -s "$AFDO_PROFILE" ] && export CCACHE_EXTRAFILES="$AFDO_PROFILE"
  ccache -z >/dev/null
  CCACHE_DESC="on ($CCACHE_DIR)"
elif [ "$USE_CCACHE" != 0 ]; then
  echo "ccache not installed, building without it"
fi

make "${MAKE_ARGS[@]}" gki_defconfig

# Add baseband_guard to the LSM list without dropping the stock entries
CUR_LSM="$(sed -n 's/^CONFIG_LSM="\(.*\)"$/\1/p' out/.config)"
case ",$CUR_LSM," in *,baseband_guard,*) ;; *)
  scripts/config --file out/.config --set-str LSM "${CUR_LSM:+$CUR_LSM,}baseband_guard" ;;
esac

# Version string
if [ -n "$KERNEL_RELEASE" ]; then
  case "$KERNEL_RELEASE" in "$KVER"*) ;; *) echo "::error::kernel_release must start with $KVER"; exit 1 ;; esac
  SUFFIX="${KERNEL_RELEASE#"$KVER"}"
  scripts/config --file out/.config --set-str LOCALVERSION "$SUFFIX" -d LOCALVERSION_AUTO
  export LOCALVERSION=""   # empty but set -> no scm suffix, no '+'
fi
make "${MAKE_ARGS[@]}" olddefconfig

# Verify that every option we need actually survived Kconfig
fail=0
need_y() { grep -q "^CONFIG_$1=y$" out/.config || { echo "::error::CONFIG_$1 is not =y"; fail=1; }; }
need_n() { ! grep -q "^CONFIG_$1=y$" out/.config || { echo "::error::CONFIG_$1 should be off"; fail=1; }; }
for o in KSU KSU_SUSFS KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_KSTAT KSU_SUSFS_SPOOF_UNAME \
         KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS BBG TCP_CONG_BBR DEFAULT_BBR \
         NETFILTER_XT_TARGET_HL IP_NF_TARGET_TTL IP6_NF_TARGET_HL \
         IP_SET IP_SET_HASH_IP IP_SET_HASH_NET IP_SET_HASH_IPPORT IP_SET_BITMAP_IP NETFILTER_XT_SET \
         OVERLAY_FS CFI_CLANG SHADOW_CALL_STACK; do need_y "$o"; done
need_n KSU_SUSFS_ENABLE_LOG
need_n KSU_SUSFS_OPEN_REDIRECT; need_y NOMOUNT
grep -q '^CONFIG_DEFAULT_TCP_CONG="bbr"$' out/.config || { echo "::error::default TCP congestion is not bbr"; fail=1; }
grep -q 'baseband_guard' <(grep '^CONFIG_LSM=' out/.config) || { echo "::error::baseband_guard missing from CONFIG_LSM"; fail=1; }
[ $fail -eq 0 ] || exit 1
grep -E '^CONFIG_(LSM|LOCALVERSION|LOCALVERSION_AUTO|KSU_SUSFS_OPEN_REDIRECT|DEFAULT_TCP_CONG)=' out/.config || true

# Commit all changes so the version never gets a "-dirty" suffix
echo "/out/" >> .git/info/exclude
# glibc 2.42+ returns const char * from strstr/strchr; host libbpf builds with -Werror
sed -i -E 's/= (strstr|strchr)\(/= (char *)\1(/' tools/lib/bpf/libbpf.c
git add -A >/dev/null 2>&1 || true
git -c user.name=build-user -c user.email=build-user@build-host commit -qm "local build changes" || true
endgroup

# ---------------------------------------------------------------- build
group "Build Image"
export KBUILD_BUILD_USER=kleaf   # stock banner: kleaf@build-host
export KBUILD_BUILD_HOST=build-host
export SOURCE_DATE_EPOCH="$SRC_EPOCH"
if [ -n "$BUILD_TIMESTAMP" ]; then export KBUILD_BUILD_TIMESTAMP="$BUILD_TIMESTAMP"; fi
# Kleaf builds GKI with gendwarfksyms --stable (honours ANDROID_KABI_* rules).
# Without it the symbol CRCs differ from stock and no vendor module loads.
export KBUILD_GENDWARFKSYMS_STABLE=1
make "${MAKE_ARGS[@]}" -j"$(nproc --all)" KCFLAGS="$KCFLAGS_EXTRA -Wno-error" Image 2>&1 | tee "$WORK/build.log"
if [ "$CCACHE_DESC" != off ]; then ccache -s | grep -iE 'hits|misses|cache size' || true; fi
test -f out/arch/arm64/boot/Image
KREL="$(make -s "${MAKE_ARGS[@]}" kernelrelease)"
echo "kernelrelease: $KREL"
case "$KREL" in *dirty*|*+) echo "::warning::kernelrelease looks modified: $KREL" ;; esac
endgroup

if [ -n "${STOCK_BOOT:-}" ] && [ -f "$STOCK_BOOT" ]; then
  group "Check symbol CRCs against stock kernel"
  python3 "$REPO_DIR/scripts/check_crc.py" out/vmlinux.symvers gki/aarch64/symbols "$STOCK_BOOT"
  endgroup
else
  echo "::warning::No stock boot.img - symbol CRCs not checked against stock (boot is NOT verified)"
fi

# ---------------------------------------------------------------- package
group "Package AnyKernel3"
cd "$WORK"
retry git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git ak3
rm -rf ak3/.git ak3/.github ak3/README.md ak3/modules ak3/patch ak3/ramdisk
cp "$REPO_DIR/ak3/anykernel.sh" ak3/anykernel.sh
cp common/out/arch/arm64/boot/Image ak3/Image
NAME="OP15_${KREL}_scheme${SCHEME}_$(date -u +%Y%m%d)"
(cd ak3 && zip -qr9 "$DIST/AnyKernel3_$NAME.zip" .)
cp common/out/arch/arm64/boot/Image "$DIST/Image_$NAME"
cp common/out/.config "$DIST/kernel_scheme$SCHEME.config"
endgroup

# ---------------------------------------------------------------- boot.img (repack stock boot with the new kernel)
BOOT_DESC="not built (no stock boot.img provided)"
if [ -n "${STOCK_BOOT:-}" ] && [ -f "$STOCK_BOOT" ]; then
  group "Repack boot.img"
  mkdir -p "$WORK/mb" "$WORK/bootwork"
  if [ ! -x "$WORK/mb/magiskboot" ]; then
    gh release download -R topjohnwu/Magisk -p 'Magisk-v*.apk' -D "$WORK/mb" --clobber
    unzip -p "$WORK"/mb/Magisk-v*.apk lib/x86_64/libmagiskboot.so > "$WORK/mb/magiskboot"
    chmod +x "$WORK/mb/magiskboot"
  fi
  MB="$WORK/mb/magiskboot"
  cd "$WORK/bootwork"
  cp "$STOCK_BOOT" stock.img
  "$MB" unpack -h stock.img 2>&1 | tee unpack.log
  [ -f kernel ] || { echo "::error::stock boot.img has no kernel (wrong image? init_boot/vendor_boot do not work)"; exit 1; }
  grep -E 'HEADER_VER|OS_VERSION|OS_PATCH_LEVEL|KERNEL_FMT|cmdline' unpack.log || true
  cp "$WORK/common/out/arch/arm64/boot/Image" kernel
  "$MB" repack stock.img new.img
  cp new.img "$DIST/boot_$NAME.img"
  BOOT_DESC="repacked from stock boot.img (sha256 $(sha256sum stock.img | cut -c1-16)...)"
  cd "$WORK"
  endgroup
else
  echo "::warning::No stock boot.img, skipping boot.img (AnyKernel3 zip and Image are still built)"
fi

group "Build info"
cat > "$DIST/build-info_scheme$SCHEME.txt" <<EOF
scheme          : A (NoMount, SUSFS OPEN_REDIRECT off)
kernelrelease   : $KREL
source          : $SRC_OWNER/android_kernel_common_oneplus_sm8850 @ $SRC_COMMIT
source commit   : $SRC_SUBJECT
KernelSU        : tiann/KernelSU $KSU_REF ($KSU_DESC)
SUSFS           : simonpunk/susfs4ksu $SUSFS_REF ($SUSFS_DESC)
NoMount         : $NOMOUNT_DESC
OverlayFS       : CONFIG_OVERLAY_FS=y (built-in)
Baseband-guard  : ${BBG_REF:-main}
Built in        : unicode bypass fix, fgetpriority
Blocked modules : ${BLOCK_MODULES-oplus_secure_guard_new}
clang           : $(clang --version | head -n1)
rustc           : $(rustc --version)
AutoFDO profile : $AFDO_DESC
KCFLAGS         : $KCFLAGS_EXTRA -Wno-error
boot.img        : $BOOT_DESC
Image sha256    : $(sha256sum "$DIST/Image_$NAME" | cut -d' ' -f1)
EOF
cat "$DIST/build-info_scheme$SCHEME.txt"
endgroup
