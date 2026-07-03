#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${GITHUB_WORKSPACE:-$(pwd)}"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
GITHUB_ENV="${GITHUB_ENV:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

# Inputs
ANDROID_VER="${ANDROID_VER:?ANDROID_VER is required}"
KERNEL_VER="${KERNEL_VER:?KERNEL_VER is required}"
SUB_LEVEL="${SUB_LEVEL:?SUB_LEVEL is required}"
OS_PATCH="${OS_PATCH:?OS_PATCH is required}"
VARIANT="${VARIANT:-SUSFS}"
CONFIGHZ="${CONFIGHZ:-250}"
TCPCONG="${TCPCONG:-bbr}"
ADD_ZEROMOUNT="${ADD_ZEROMOUNT:-true}"
KERNEL_NAME="${KERNEL_NAME:-Kinosaki}"

KSU_VARIANT="KernelSU-Next"
KSU_DIR="KernelSU-Next"

# Colors / logging
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; W='\033[0m'
info() { echo -e "${B}[INFO]${W} $*"; }
success() { echo -e "${G}[OK]${W} $*"; }
warn() { echo -e "${Y}[WARN]${W} $*"; }
die() { echo -e "${R}[ERR]${W} $*" >&2; exit 1; }

dump_build_logs() {
  [[ -n "${KERNEL_ROOT:-}" && -d "${KERNEL_ROOT:-}" ]] || return 0
  for LOG in $(find "$KERNEL_ROOT" -name '*.log' -newer "$KERNEL_ROOT/common" -type f 2>/dev/null | head -5); do
    echo "::group::$(basename "$LOG")"
    tail -80 "$LOG"
    echo "::endgroup::"
  done
}
trap 'dump_build_logs; die "Failed at line $LINENO [$BASH_COMMAND]"' ERR

source "$SCRIPT_DIR/functions.sh"

info "Installing build dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq lld binutils zip

info "Cloning AnyKernel3..."
git clone -q --depth=1 https://github.com/rinnsakaguchi/AnyKernel3 -b master "$WORKDIR/AnyKernel3"

# Setup Build Environment
CONFIG="${ANDROID_VER}-${KERNEL_VER}-${SUB_LEVEL}"
KERNEL_ROOT="$WORKDIR/$CONFIG"
DEFCONFIG="$KERNEL_ROOT/common/arch/arm64/configs/gki_defconfig"
DEFCONFIG_FRAGMENT="$KERNEL_ROOT/common/arch/arm64/configs/builder_gki.fragment"
KERNEL_PATCHES="$SCRIPT_DIR/patch"
ANYKERNEL3="$WORKDIR/AnyKernel3"
mkdir -p "$KERNEL_ROOT"

{
  echo "ANDROID_VER=$ANDROID_VER"; echo "KERNEL_VER=$KERNEL_VER"; echo "OS_PATCH=$OS_PATCH"
  echo "CONFIG=$CONFIG"; echo "KERNEL_ROOT=$KERNEL_ROOT"
  echo "DEFCONFIG=$DEFCONFIG"; echo "DEFCONFIG_FRAGMENT=$DEFCONFIG_FRAGMENT"
  echo "KERNEL_PATCHES=$KERNEL_PATCHES"; echo "ANYKERNEL3=$ANYKERNEL3"
} >> "$GITHUB_ENV"

# Sync Kernel Source
info "Syncing kernel source ($CONFIG)..."
( cd "$KERNEL_ROOT"
  FORMATTED_BRANCH="${ANDROID_VER}-${KERNEL_VER}-${OS_PATCH}"

  repo init -u https://android.googlesource.com/kernel/manifest \
    -b "common-${FORMATTED_BRANCH}" --depth=1

  REMOTE_BRANCH=$(git ls-remote https://android.googlesource.com/kernel/common "${FORMATTED_BRANCH}")
  if grep -q deprecated <<< "$REMOTE_BRANCH"; then
    sed -i "s/\"${FORMATTED_BRANCH}\"/\"deprecated\/${FORMATTED_BRANCH}\"/g" .repo/manifests/default.xml
  fi

  repo --trace sync -c -j"$(nproc --all)" --fail-fast --no-tags --force-sync --no-clone-bundle
)
success "Kernel source synced"

# Extract Sublevel
SUBLEVEL="$SUB_LEVEL"
if [[ -f "$KERNEL_ROOT/common/Makefile" ]]; then
  EXTRACTED=$(grep '^SUBLEVEL = ' "$KERNEL_ROOT/common/Makefile" | awk '{print $3}')
  [[ -n "$EXTRACTED" ]] && SUBLEVEL="$EXTRACTED"
fi
ARTIFACT_BASE="${KERNEL_VER}.${SUBLEVEL}-${ANDROID_VER}-${OS_PATCH}-${VARIANT}"
FILE_NAME="$ARTIFACT_BASE"
{ echo "SUBLEVEL=$SUBLEVEL"; echo "ARTIFACT_BASE=$ARTIFACT_BASE"; echo "FILE_NAME=$FILE_NAME"; } >> "$GITHUB_ENV"
info "Sublevel: $SUBLEVEL | Artifact: $FILE_NAME"

# Setup KernelSU-Next
if [[ "$VARIANT" == "KSU" || "$VARIANT" == "SUSFS" ]]; then
  info "Setting up KernelSU-Next..."
  ( cd "$KERNEL_ROOT"
    curl -LSs "https://raw.githubusercontent.com/pershoot/KernelSU-Next/dev-susfs/kernel/setup.sh" | bash -s dev-susfs
    [ -d "$KERNEL_ROOT/$KSU_DIR" ] || die "$KSU_DIR not created by setup.sh"

    cd "$KERNEL_ROOT/common"
    SUPERCALLS="drivers/kernelsu/supercalls.c"
    if [ -f "$SUPERCALLS" ]; then
      if grep -q "vzalloc" "$SUPERCALLS" && ! head -5 "$SUPERCALLS" | grep -q "vmalloc.h"; then
        sed -i '1a #include <linux/vmalloc.h>' "$SUPERCALLS"
      fi
    fi
  )
fi

# Apply SUSFS Patch
if [[ "$VARIANT" == "SUSFS" ]]; then
  info "Applying SUSFS patch..."
  SUS_DIR="$RUNNER_TEMP/susfs4ksu"
  git clone -q --depth=1 https://gitlab.com/simonpunk/susfs4ksu/ \
    -b "gki-${ANDROID_VER}-${KERNEL_VER}" "$SUS_DIR"
  ( cd "$KERNEL_ROOT/common"
    cp -r "$SUS_DIR/kernel_patches/fs" .
    cp -r "$SUS_DIR/kernel_patches/include" .
    patch -p1 -F3 --no-backup-if-mismatch \
      < "$SUS_DIR/kernel_patches/50_add_susfs_in_gki-${ANDROID_VER}-${KERNEL_VER}.patch"
  )
  rm -rf "$SUS_DIR"
fi

# Apply ZeroMount Patch
if [[ "$ADD_ZEROMOUNT" == "true" && "$VARIANT" == "SUSFS" ]]; then
  PATCH="$KERNEL_PATCHES/60_zeromount-${ANDROID_VER}-${KERNEL_VER}.patch"
  if [ -s "$PATCH" ]; then
    info "Applying zeromount patch..."
    ( cd "$KERNEL_ROOT/$KSU_DIR" && patch -p1 -F3 --no-backup-if-mismatch < "$PATCH" )
  else
    warn "No zeromount patch found at $PATCH — skipping"
  fi
fi

# Configure Kernel
info "Tuning defconfig (VARIANT=$VARIANT HZ=$CONFIGHZ TCP=$TCPCONG)..."
( cd "$KERNEL_ROOT/common"
  sed -i '/CONFIG_KSU/d; /CONFIG_KSU_SUSFS/d' "$DEFCONFIG"
  case "$VARIANT" in
    KSU)   echo "CONFIG_KSU=y" >> "$DEFCONFIG"; echo "# CONFIG_KSU_SUSFS is not set" >> "$DEFCONFIG" ;;
    SUSFS) echo "CONFIG_KSU=y" >> "$DEFCONFIG"; echo "CONFIG_KSU_SUSFS=y" >> "$DEFCONFIG" ;;
  esac

  sed -i '/CONFIG_HZ_/d; /CONFIG_HZ=/d' "$DEFCONFIG"
  echo "CONFIG_HZ_${CONFIGHZ}=y" >> "$DEFCONFIG"
  echo "CONFIG_HZ=${CONFIGHZ}" >> "$DEFCONFIG"

  case "$TCPCONG" in
    westwood) use_westwood ;;
    bbr)      use_bbr ;;
    *) die "Unknown TCPCONG '$TCPCONG'" ;;
  esac
)

# Apply Module Check Bypass
if [[ "$KERNEL_VER" == "6.1" || "$KERNEL_VER" == "6.6" || "$KERNEL_VER" == "6.12" ]]; then
  TARGET_FILE="$KERNEL_ROOT/common/kernel/module/version.c"
else
  TARGET_FILE="$KERNEL_ROOT/common/kernel/module.c"
fi
sed -i '/bad_version:/{:a;n;/return 0;/{s/return 0;/return 1;/;b};ba}' "$TARGET_FILE"

# Build Kernel
info "Building kernel..."
BUILD_RC=0
LTO_MODE=thin
( cd "$KERNEL_ROOT"
  if [ -f common/tools/bpf/resolve_btfids/Makefile ]; then
    echo 'override KBUILD_HOSTLDFLAGS += --sysroot=/' >> common/tools/bpf/resolve_btfids/Makefile
    echo 'override LDFLAGS += --sysroot=/' >> common/tools/bpf/resolve_btfids/Makefile
  fi
  tools/bazel build --config=fast --lto=$LTO_MODE //common:kernel_aarch64
) || BUILD_RC=$?

if [ "$BUILD_RC" -ne 0 ]; then
  if find "$KERNEL_ROOT" -name "Image" -type f 2>/dev/null | grep -q .; then
    warn "Build exited $BUILD_RC but Image exists (likely depmod failure)"
  else
    dump_build_logs
    die "Build failed with exit code $BUILD_RC"
  fi
fi
success "Build complete"

# Prepare AnyKernel3
IMAGE_PATH="$KERNEL_ROOT/bazel-bin/common/kernel_aarch64/Image"
[[ -f "$IMAGE_PATH" ]] || die "Image not found at $IMAGE_PATH"
cp "$IMAGE_PATH" "$ANYKERNEL3/Image"

# Package AnyKernel3 zip
info "Packaging $FILE_NAME.zip..."
( cd "$ANYKERNEL3" && zip -r9 -q "$WORKDIR/${FILE_NAME}.zip" ./* -x "*.git*" )
success "Package: ${FILE_NAME}.zip"

# Scan Patch Rejects
REJECTS_DIR="$WORKDIR/patch-rejects"
mkdir -p "$REJECTS_DIR"
mapfile -t REJS < <(find "$KERNEL_ROOT" -type f -name '*.rej')
REJ_COUNT=${#REJS[@]}
echo "REJ_COUNT=$REJ_COUNT" >> "$GITHUB_ENV"
if [ "$REJ_COUNT" -gt 0 ]; then
  warn "$REJ_COUNT patch reject(s) found"
  for REJ in "${REJS[@]}"; do
    REL="${REJ#"$KERNEL_ROOT"/}"
    DEST="$REJECTS_DIR/$REL"
    mkdir -p "$(dirname "$DEST")"
    cp "$REJ" "$DEST"
    ORIG="${REJ%.rej}"
    [ -f "$ORIG" ] && cp "$ORIG" "$REJECTS_DIR/${REL%.rej}"
  done
fi

# Notify Telegram
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  info "Sending Telegram notification..."
  TEXT="📱 *${KERNEL_NAME}* — \`${KERNEL_VER}.${SUBLEVEL}\` (${VARIANT})
LTO: ${LTO_MODE} | HZ: ${CONFIGHZ} | TCP: ${TCPCONG}"
  upload_file "$WORKDIR/${FILE_NAME}.zip" "$TEXT"
fi

# Job Summary
{
  echo "## ${KSU_VARIANT} | ${KERNEL_VER}.${SUBLEVEL}"
  echo ""
  echo "| Field | Value |"
  echo "|-------|-------|"
  echo "| **Kernel** | ${KERNEL_VER}.${SUBLEVEL} |"
  echo "| **Variant** | ${VARIANT} |"
  echo "| **HZ** | ${CONFIGHZ} |"
  echo "| **TCP Congestion** | ${TCPCONG} |"
  echo "| **Patch Rejects** | ${REJ_COUNT} |"
} >> "$GITHUB_STEP_SUMMARY"

success "Done: ${FILE_NAME}.zip"
exit 0
