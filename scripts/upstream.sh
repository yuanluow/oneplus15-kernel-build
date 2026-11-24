#!/usr/bin/env bash
# Print the current state of every upstream the kernel is built from, one "name: value" per line.
# The scheduled workflow compares this with upstream.txt of the latest release and only builds
# when something changed. Also usable by hand: ./scripts/upstream.sh
set -euo pipefail

SRC_OWNER="${SRC_OWNER:-OnePlusOSS}"
SRC_BRANCH="oneplus/sm8850_b_16.0.0_oneplus_15"
SUSFS_REF="${SUSFS_REF:-gki-android16-6.12}"
KSU_REF="${KSU_REF:-main}"

head_of() { # url ref -> commit (empty if missing)
  git ls-remote "$1" "$2" 2>/dev/null | awk 'NR==1 {print $1}'
}
latest_tag() { # url -> newest tag by version order
  git ls-remote --tags --refs "$1" 2>/dev/null | sed 's|.*refs/tags/||' | sort -V | tail -n1
}

OP="https://github.com/OnePlusOSS/android_kernel_common_oneplus_sm8850.git"
echo "oneplus_source: $(head_of "$OP" "refs/heads/$SRC_BRANCH")"
if [ "$SRC_OWNER" != OnePlusOSS ]; then
  echo "fork_source: $(head_of "https://github.com/$SRC_OWNER/android_kernel_common_oneplus_sm8850.git" "refs/heads/$SRC_BRANCH")"
fi
# A new OnePlus 15 branch (e.g. a new Android/OxygenOS base) shows up here
echo "oneplus15_branches: $(git ls-remote --heads "$OP" 2>/dev/null | sed -n 's|.*refs/heads/||p' | grep -E 'oneplus_15$' | sort | tr '\n' ' ' | sed 's/ $//')"
echo "kernel_manifest: $(head_of https://github.com/OnePlusOSS/kernel_manifest.git refs/heads/oneplus/sm8850)"
echo "kernelsu: $(head_of https://github.com/tiann/KernelSU.git "refs/heads/$KSU_REF")"
echo "susfs: $(head_of https://gitlab.com/simonpunk/susfs4ksu.git "refs/heads/$SUSFS_REF")"
echo "nomount: $(latest_tag https://github.com/maxsteeel/nomount.git)"
echo "baseband_guard: $(head_of https://github.com/vc-teahouse/Baseband-guard.git refs/heads/main)"
