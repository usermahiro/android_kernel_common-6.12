#!/usr/bin/env bash
#
# Rey's GKI Kernel Builder Bazel

set -euo pipefail

WORKDIR="$(pwd)"
KERNEL_NAME="${KERNEL_NAME:-Kinosaki}"

# Identity
KBUILD_BUILD_USER="rey"
KBUILD_BUILD_HOST="ivy"
TIMEZONE="Asia/Jakarta"

# Build Defaults
KERNEL_DEFCONFIG="gki_defconfig"
BAZEL_TARGET="${BAZEL_TARGET:-//common:kernel_aarch64}"   # plain GKI target
ANYKERNEL_REPO="https://github.com/rinnsakaguchi/AnyKernel3"
ANYKERNEL_BRANCH="master"

BUILDER_REPO="${BUILDER_REPO:-https://github.com/Cartethyiaaa/builder}"
BUILDER_BRANCH="${BUILDER_BRANCH:-master}"

BUILD_START=$(date +%s)

# still reported nicely.
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[0m'
info() { echo -e "${B}[INFO]${W} $*"; }
success() { echo -e "${G}[OK]${W} $*"; }
warn() { echo -e "${Y}[WARN]${W} $*"; }
die() { echo -e "${R}[ERR]${W} $*" >&2; exit 1; }
trap 'rm -rf "${TOOLKIT_DIR:-}"' EXIT
trap 'die "Failed at line $LINENO [$BASH_COMMAND]"' ERR

exec > >(tee "$WORKDIR/build.log") 2>&1

# Timezone
sudo timedatectl set-timezone "$TIMEZONE" 2>/dev/null || export TZ="$TIMEZONE"

# Fetch Builder Toolkit
TOOLKIT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/builder-toolkit.XXXXXX")"
info "Fetching builder toolkit from $BUILDER_REPO ($BUILDER_BRANCH)..."
git clone -q --depth=1 -b "$BUILDER_BRANCH" "$BUILDER_REPO" "$TOOLKIT_DIR" \
  || die "Failed to fetch builder toolkit from $BUILDER_REPO ($BUILDER_BRANCH) — check network/branch name"

[[ -f "$TOOLKIT_DIR/functions.sh" ]] || die "functions.sh not found in builder toolkit — check $BUILDER_REPO layout"
source "$TOOLKIT_DIR/functions.sh"

KERNEL_PATCHES="$TOOLKIT_DIR/patch"
PY_DIR="$TOOLKIT_DIR/py"
success "Toolkit ready ($TOOLKIT_DIR)"

# Validate Required Env
for var in VARIANT CONFIGHZ TCPCONG LTOBUILD; do
  [[ -n "${!var:-}" ]] || die "Required env var \$$var is not set"
done

if [[ -n "${KSRC:-}" ]]; then
  : # explicit override, use as-is
elif [[ -x "$WORKDIR/tools/bazel" ]]; then
  KSRC="$WORKDIR"
elif [[ -f "$WORKDIR/BUILD.bazel" && -x "$WORKDIR/../tools/bazel" ]]; then
  KSRC="$(cd "$WORKDIR/.." && pwd)"
elif [[ -f "$WORKDIR/BUILD.bazel" ]]; then
  die "Running from inside common/ but no tools/bazel found in the parent dir ($WORKDIR/..) — this looks like a bare 'common' checkout without the Kleaf workspace (prebuilts/, build/kernel/kleaf). Point KSRC at a full workspace, e.g.: KSRC=/path/to/workspace ./build.sh"
else
  die "Could not locate a Kleaf workspace. Run this from inside your workspace root or common/, or set KSRC explicitly: KSRC=/path/to/workspace ./build.sh"
fi

COMMON="$KSRC/common"
[[ -x "$KSRC/tools/bazel" ]] || die "tools/bazel not found at $KSRC — is this a real Kleaf workspace?"
[[ -d "$COMMON" ]] || die "common/ not found under $KSRC"

info "Using existing source at $KSRC (no clone/sync)"
KERNEL_REPO="$(git -C "$COMMON" config --get remote.origin.url 2>/dev/null || echo 'local')"

# Kernel Info
cd "$COMMON"
LINUX_VERSION=$(make kernelversion 2>/dev/null || grep -m1 '^VERSION\|^PATCHLEVEL\|^SUBLEVEL' Makefile | awk '{print $3}' | paste -sd.)
KVER="$LINUX_VERSION"
LINUX_MAJOR="${LINUX_VERSION%%.*}"
if git -C "$KSRC" rev-parse --short HEAD >/dev/null 2>&1; then
  k_lastcommit=$(git -C "$KSRC" rev-parse --short HEAD)
  LASTCOMMITS=$(git -C "$KSRC" log -5 --pretty=format:"- %h %s (%an)" | sed ':a;N;$!ba;s/\n/\\n/g')
else
  k_lastcommit="local"
  LASTCOMMITS="(not a git checkout — building from local working tree)"
fi

info "Kernel version : $LINUX_VERSION"
info "Last commit    : $k_lastcommit"

# Locate defconfig
DEFCONFIG_FILE=$(find "$COMMON/arch/arm64/configs" -name "$KERNEL_DEFCONFIG" -print -quit)
[[ -f "$DEFCONFIG_FILE" ]] || die "Defconfig '$KERNEL_DEFCONFIG' not found under $COMMON/arch/arm64/configs"
DEFCONFIG="$DEFCONFIG_FILE"

# Variant Setup
info "Setting up variant: $VARIANT"

# Wipe any old KSU config lines
sed -i '/CONFIG_KSU/d' "$DEFCONFIG"
sed -i '/CONFIG_KSU_SUSFS/d' "$DEFCONFIG"

if [[ "$VARIANT" == "KSU" || "$VARIANT" == "SUSFS" ]]; then
  ( cd "$COMMON" && curl -LSs "https://raw.githubusercontent.com/pershoot/KernelSU-Next/dev-susfs/kernel/setup.sh" \
    | bash -s dev-susfs )

  info "Patching All Managers support..."
  if [[ -d "$COMMON/KernelSU-Next" ]]; then
    patch -p1 -d "$COMMON/KernelSU-Next" < "$KERNEL_PATCHES/ksu-manager.patch" || die "ksu-manager patch failed"
  elif [[ -d "$COMMON/drivers/kernelsu" ]]; then
    patch -p1 -d "$COMMON/drivers/kernelsu" < "$KERNEL_PATCHES/ksu-manager.patch" || die "ksu-manager patch failed"
  else
    die "KernelSU directory not found after setup"
  fi
fi

case "$VARIANT" in
  VNL)
    echo "ENABLE_SUSFS=false" >> "${GITHUB_ENV:-/dev/null}"
    ;;
  KSU)
    echo "CONFIG_KSU=y" >> "$DEFCONFIG"
    echo "# CONFIG_KSU_SUSFS is not set" >> "$DEFCONFIG"
    echo "ENABLE_SUSFS=false" >> "${GITHUB_ENV:-/dev/null}"
    ;;
  SUSFS)
    SUS_DIR="$TOOLKIT_DIR/.susfs4ksu"
    git clone -q --depth=1 https://gitlab.com/simonpunk/susfs4ksu/ \
      -b gki-android16-6.12 "$SUS_DIR" || die "susfs4ksu clone failed"
    cp -r "$SUS_DIR/kernel_patches/fs" "$COMMON/"
    cp -r "$SUS_DIR/kernel_patches/include" "$COMMON/"
    ( cd "$COMMON" && patch -p1 < "$SUS_DIR/kernel_patches/50_add_susfs_in_gki-android16-6.12.patch" ) \
      || die "SuSFS patch failed"
    rm -rf "$SUS_DIR"

    echo "CONFIG_KSU=y" >> "$DEFCONFIG"
    echo "CONFIG_KSU_SUSFS=y" >> "$DEFCONFIG"

    # Disable uname spoof to fix build
    KSU_SU_FILE=$(find "$COMMON/drivers/" -name "supercalls.c" -print -quit)
    if [[ -f "$KSU_SU_FILE" ]]; then
      sed -i 's|#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME|#if 0 /* disabled */|' \
        "$KSU_SU_FILE" || true
    fi
    echo "ENABLE_SUSFS=true" >> "${GITHUB_ENV:-/dev/null}"
    ;;
  *)
    die "Unknown VARIANT: $VARIANT (valid: VNL | KSU | SUSFS)"
    ;;
esac

# Defconfig
info "Tuning defconfig..."

# HZ
sed -i '/CONFIG_HZ_/d; /CONFIG_HZ=/d' "$DEFCONFIG"
echo "CONFIG_HZ_${CONFIGHZ}=y" >> "$DEFCONFIG"
echo "CONFIG_HZ=${CONFIGHZ}" >> "$DEFCONFIG"

# LTO.
case "${LTOBUILD,,}" in
  thin) BAZEL_LTO_FLAG="--lto=thin" ;;
  none) BAZEL_LTO_FLAG="--lto=none" ;;
  full|*) BAZEL_LTO_FLAG="--lto=full" ;;
esac
info "LTO: ${LTOBUILD,,} (${BAZEL_LTO_FLAG})"

# TCP Congestion
case "$TCPCONG" in
  westwood) use_westwood ;;
  bbrplus)  use_bbrplus ;;
  bbr)      use_bbr ;;
  *) die "Unknown TCP congestion: $TCPCONG (valid: bbr | bbrplus | westwood)" ;;
esac

# Localversion
SUFFIX="$k_lastcommit"
"$COMMON/scripts/config" --file "$DEFCONFIG_FILE" --set-str CONFIG_LOCALVERSION "-${KERNEL_NAME}"
"$COMMON/scripts/config" --file "$DEFCONFIG_FILE" --disable CONFIG_LOCALVERSION_AUTO
sed -i 's/echo "+"/# echo "+"/g' "$COMMON/scripts/setlocalversion"

# Build Environment
export KBUILD_BUILD_USER
export KBUILD_BUILD_HOST
export KBUILD_BUILD_TIMESTAMP="$(date)"

DIST_DIR="$WORKDIR/out/dist"

# Defconfig-only
if [[ "${TODO:-}" == "defconfig" ]]; then
  info "Generating config only..."
  cd "$KSRC"
  ./tools/bazel run "${BAZEL_TARGET}_config" -- --dist_dir="$DIST_DIR" || die "config generation failed"
  info "Uploading defconfig..."
  upload_file "$DIST_DIR/.config"
  exit 0
fi

# Kick off AnyKernel3 clone in the background while the kernel compiles
info "Cloning AnyKernel3 from $(simplify_gh_url "$ANYKERNEL_REPO") (background)..."
git clone -q --depth=1 "$ANYKERNEL_REPO" -b "$ANYKERNEL_BRANCH" "$WORKDIR/anykernel" &
AK3_CLONE_PID=$!

# Build Kernel (Bazel/Kleaf)
info "Building kernel via Bazel target ${BAZEL_TARGET}_dist ..."
cd "$KSRC"
COMPILER_STRING="clang (Kleaf-managed toolchain — see out/dist/compile_commands.json or build.log for exact version)"

./tools/bazel run "${BAZEL_TARGET}_dist" -- \
  "$BAZEL_LTO_FLAG" \
  --dist_dir="$DIST_DIR" \
  --jobs="$(nproc --all)" \
  || die "bazel build failed"

BUILD_END=$(date +%s)
BUILD_ELAPSED=$(( BUILD_END - BUILD_START ))
BUILD_MIN=$(( BUILD_ELAPSED / 60 ))
BUILD_SEC=$(( BUILD_ELAPSED % 60 ))
success "Kernel built in ${BUILD_MIN}m ${BUILD_SEC}s"

# Validate Output — dist dir layout differs from the old make $OUTDIR layout
KERNEL_IMAGE="$DIST_DIR/Image"
MODULE_SYMVERS="$DIST_DIR/Module.symvers"
[[ -f "$KERNEL_IMAGE" ]] || die "Kernel Image not found at $KERNEL_IMAGE (check ${BAZEL_TARGET}_dist output list in BUILD.bazel)"

IMAGE_SIZE=$(du -sh "$KERNEL_IMAGE" | cut -f1)
info "Image size: $IMAGE_SIZE"

# Try to pull the real compiler string out of the dist dir if Kleaf wrote one
if [[ -f "$DIST_DIR/vmlinux.symvers" || -f "$DIST_DIR/compile_commands.json" ]]; then
  _cc=$(grep -m1 -o 'clang version [0-9.]*' "$DIST_DIR"/*.json 2>/dev/null | head -n1)
  [[ -n "$_cc" ]] && COMPILER_STRING="$_cc"
fi

# KMI Check — android16-6.12 is a 6.x branch, so this stays on the .stg path
if [[ "$LINUX_MAJOR" -eq 6 ]]; then
  KMI_CHECK_SCRIPT="$PY_DIR/kmi-check-6.x.py"
  KMI_ABI="$COMMON/android/abi_gki_aarch64.stg"
else
  KMI_CHECK_SCRIPT="$PY_DIR/kmi-check-5.x.py"
  KMI_ABI="$COMMON/android/abi_gki_aarch64.xml"
fi

if [[ -f "$KMI_ABI" && -f "$MODULE_SYMVERS" ]]; then
  "$KMI_CHECK_SCRIPT" "$KMI_ABI" "$MODULE_SYMVERS" || \
    warn "KMI mismatch detected — vendor modules may fail to load"
else
  warn "Skipping KMI check — ABI ref or Module.symvers missing in dist dir (Kleaf ABI monitoring may need 'bazel test ${BAZEL_TARGET}_abi' instead)"
fi

# Package AnyKernel3
BUILD_DATE=$(TZ=Asia/Jakarta date +"%Y%m%d")
AK3_ZIP_NAME="AK3-${KERNEL_NAME}-${KVER}-${VARIANT}-${BUILD_DATE}.zip"

wait "$AK3_CLONE_PID" || die "AnyKernel3 clone failed"
cd "$WORKDIR/anykernel"

# Copy Kernel Image
if [[ -f "$DIST_DIR/Image.lz4" ]]; then
  cp "$DIST_DIR/Image.lz4" .
else
  cp "$KERNEL_IMAGE" .
fi

# Package ZIP
info "Zipping AnyKernel3 package..."
zip -r9 "$WORKDIR/$AK3_ZIP_NAME" ./* -x "*.git*"
cd "$WORKDIR"

ZIP_FINAL_SIZE=$(du -sh "$WORKDIR/$AK3_ZIP_NAME" | cut -f1)
success "Package: $AK3_ZIP_NAME ($ZIP_FINAL_SIZE)"

echo "BASE_NAME=${KERNEL_NAME}-${VARIANT}" >> "${GITHUB_ENV:-/dev/null}"

# Move to Artifacts
ARTIFACT_DIR="$WORKDIR/artifacts"
ZIP_PATH="$ARTIFACT_DIR/$AK3_ZIP_NAME"
mkdir -p "$ARTIFACT_DIR"
mv "$WORKDIR/$AK3_ZIP_NAME" "$ARTIFACT_DIR/"

# Telegram Notification
text_tg=$(cat << EOF
📱 *Kernel Version*: \`${LINUX_VERSION}\`
📅 *Build Date*: \`${KBUILD_BUILD_TIMESTAMP}\`
⚙️ *Variant*: \`${VARIANT}\`
🚀 *LTO*: \`${LTOBUILD}\`
🛠 *Compiler*: \`${COMPILER_STRING}\`
⏱ *Build Time*: \`${BUILD_MIN}m ${BUILD_SEC}s\`
📦 *Package Size*: \`${ZIP_FINAL_SIZE}\`
🔖 *Last Commit*: $( [[ "$KERNEL_REPO" == local ]] && echo "\`${k_lastcommit}\`" || echo "[${k_lastcommit}](${KERNEL_REPO}/commit/${k_lastcommit})" )
📜 *Recent Changes*:
\`\`\`
${LASTCOMMITS}
\`\`\`
EOF
)

if [[ "${BUILD_TYPE:-}" != "release" ]]; then
  info "Sending test build to Telegram..."
  upload_file "$ZIP_PATH" "$text_tg"
fi

# Cleanup
info "Cleaning up build artifacts..."
rm -rf "$WORKDIR/anykernel" "$WORKDIR/out" "$TOOLKIT_DIR"

success "Done! Total time: ${BUILD_MIN}m ${BUILD_SEC}s"
exit 0
