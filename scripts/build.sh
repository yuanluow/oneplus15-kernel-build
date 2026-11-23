#!/usr/bin/env bash
# OnePlus 15 (SM8850) GKI kernel: 6.12.58 + KernelSU + SUSFS v2.2.0 + BBG + TTL + IP_SET + BBR default
# SCHEME=A -> for NoMount (SUSFS OPEN_REDIRECT off)
# SCHEME=B -> for OverlayFS (SUSFS OPEN_REDIRECT on)
set -euo pipefail

: "${SCHEME:?SCHEME must be A or B}"
: "${SRC_OWNER:=OnePlusOSS}"
: "${KSU_REF:=main}"
: "${SUSFS_REF:=gki-android16-6.12}"
: "${BBG_REF:=}"
: "${NOMOUNT_REF:=}"
: "${KERNEL_RELEASE:=}"
: "${BUILD_TIMESTAMP:=}"

case "$SCHEME" in A|B) ;; *) echo "::error::SCHEME must be A or B"; exit 1 ;; esac

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

fetch_subdir() { # project rev subdir dest
  local proj="$1" rev="$2" sub="$3" dest="$4" name
  name="$(basename "$proj")"
  mkdir -p "$dest"
  retry curl -fL --retry 3 -o "$dest.tar.gz" "$CLO/$proj/-/archive/$rev/$name-$rev.tar.gz?path=$sub"
  tar -xzf "$dest.tar.gz" -C "$dest"
  rm -f "$dest.tar.gz"
}
fetch_subdir kernelplatform/prebuilts-master/clang/host/linux-x86 "$CLANG_REV" "clang-$CLANG_VERSION" tc-clang
fetch_subdir kernel_platform/prebuilts/rust "$RUST_REV" "linux-x86/${RUSTC_VERSION%.p*}" tc-rust
fetch_subdir kernel_platform/prebuilts/clang-tools "$TOOLS_REV" "linux-x86/bin" tc-tools

CLANG_BIN="$(dirname "$(find "$WORK/tc-clang" -path '*/bin/clang' | head -n1)")"
RUST_BIN="$(dirname "$(find "$WORK/tc-rust" -path '*/bin/rustc' | head -n1)")"
BINDGEN_BIN="$(dirname "$(find "$WORK/tc-tools" -path '*/bin/bindgen' | head -n1)")"
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
retry git clone https://gitlab.com/simonpunk/susfs4ksu.git susfs
git -C susfs checkout -q "$SUSFS_REF"
SUSFS_DESC="$(git -C susfs rev-parse --short HEAD), $(git -C susfs log -1 --format=%cs)"
echo "SUSFS: $SUSFS_DESC"
cp -v susfs/kernel_patches/fs/* common/fs/
cp -v susfs/kernel_patches/include/linux/* common/include/linux/
SUSFS_PATCH="$(ls susfs/kernel_patches/50_add_susfs_in_gki-android16-6.12.patch)"
if ! (cd common && patch -p1 --forward --no-backup-if-mismatch < "$WORK/$SUSFS_PATCH"); then
  echo "::error::SUSFS kernel patch did not apply cleanly. Rejected hunks:"
  find common -name '*.rej' -print -exec cat {} \;
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
if [ "$SCHEME" = A ]; then
  need_n KSU_SUSFS_OPEN_REDIRECT; need_y NOMOUNT
else
  need_y KSU_SUSFS_OPEN_REDIRECT
fi
grep -q '^CONFIG_DEFAULT_TCP_CONG="bbr"$' out/.config || { echo "::error::default TCP congestion is not bbr"; fail=1; }
grep -q 'baseband_guard' <(grep '^CONFIG_LSM=' out/.config) || { echo "::error::baseband_guard missing from CONFIG_LSM"; fail=1; }
[ $fail -eq 0 ] || exit 1
grep -E '^CONFIG_(LSM|LOCALVERSION|LOCALVERSION_AUTO|KSU_SUSFS_OPEN_REDIRECT|DEFAULT_TCP_CONG)=' out/.config || true

# Commit all changes so the version never gets a "-dirty" suffix
echo "/out/" >> .git/info/exclude
git add -A >/dev/null 2>&1 || true
git -c user.name=build-user -c user.email=build-user@build-host commit -qm "local build changes" || true
endgroup

# ---------------------------------------------------------------- build
group "Build Image"
export KBUILD_BUILD_USER=build-user
export KBUILD_BUILD_HOST=build-host
export SOURCE_DATE_EPOCH="$SRC_EPOCH"
if [ -n "$BUILD_TIMESTAMP" ]; then export KBUILD_BUILD_TIMESTAMP="$BUILD_TIMESTAMP"; fi
make "${MAKE_ARGS[@]}" -j"$(nproc --all)" KCFLAGS="-Wno-error" Image 2>&1 | tee "$WORK/build.log"
test -f out/arch/arm64/boot/Image
KREL="$(make -s "${MAKE_ARGS[@]}" kernelrelease)"
echo "kernelrelease: $KREL"
case "$KREL" in *dirty*|*+) echo "::warning::kernelrelease looks modified: $KREL" ;; esac
endgroup

# ---------------------------------------------------------------- package
group "Package AnyKernel3"
cd "$WORK"
retry git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git ak3
rm -rf ak3/.git ak3/.github ak3/README.md ak3/modules ak3/patch ak3/ramdisk
cp "$REPO_DIR/ak3/anykernel.sh" ak3/anykernel.sh
cp common/out/arch/arm64/boot/Image ak3/Image
NAME="OP15_${KREL}_scheme${SCHEME}_$(date -u +%Y%m%d)"
(cd ak3 && zip -qr9 "$DIST/AnyKernel3_$NAME.zip" .)
cp common/out/arch/arm64/boot/Image "$DIST/Image"
cp common/out/.config "$DIST/kernel.config"
cat > "$DIST/build-info.txt" <<EOF
scheme          : $SCHEME ($([ "$SCHEME" = A ] && echo "NoMount, SUSFS OPEN_REDIRECT off" || echo "OverlayFS, SUSFS OPEN_REDIRECT on"))
kernelrelease   : $KREL
source          : $SRC_OWNER/android_kernel_common_oneplus_sm8850 @ $SRC_COMMIT
source commit   : $SRC_SUBJECT
KernelSU        : tiann/KernelSU $KSU_REF ($KSU_DESC)
SUSFS           : simonpunk/susfs4ksu $SUSFS_REF ($SUSFS_DESC)
NoMount         : $NOMOUNT_DESC
OverlayFS       : CONFIG_OVERLAY_FS=y (built-in)
Baseband-guard  : ${BBG_REF:-main}
clang           : $(clang --version | head -n1)
rustc           : $(rustc --version)
Image sha256    : $(sha256sum "$DIST/Image" | cut -d' ' -f1)
EOF
cat "$DIST/build-info.txt"
endgroup
