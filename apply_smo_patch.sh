#!/usr/bin/env bash
# apply_smo_patch.sh
# - Clone linux.git at a given tag (default: v5.1-rc4)
# - Download or use a local mbox for "Making slab-allocated objects movable" series
# - Apply with git am (3-way), try enabling CONFIG_DCACHE_SMO if present
# - Build kernel

set -euo pipefail

# --- defaults ---
TAG="${TAG:-v5.1-rc4}"
JOBS="${JOBS:-$(nproc || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}"
LINUX_DIR="${LINUX_DIR:-$PWD/linux-smo}"
GIT_REMOTE="${GIT_REMOTE:-https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git}"
MBOX_URL="${MBOX_URL:-}"     # e.g. https://lore.kernel.org/lkml/20190603042637.2018-15-tobin@kernel.org/t.mbox.gz
MBOX_FILE="${MBOX_FILE:-}"   # e.g. /path/to/thread.mbox or .mbox.gz
DO_BUILD="${DO_BUILD:-1}"    # set to 0 to skip build
CONFIG_TRY_ENABLE="${CONFIG_TRY_ENABLE:-1}" # set to 0 to skip CONFIG_DCACHE_SMO attempt

usage() {
  cat <<USAGE
Usage:
  [env] ./apply_smo_patch.sh

Env vars:
  TAG=v5.1-rc4                # base tag to checkout
  LINUX_DIR=\$PWD/linux-smo    # work dir for the kernel tree
  GIT_REMOTE=<linux.git url>   # git remote for kernel source
  MBOX_URL=<http(s)://...>     # mbox URL of the patch series (preferred)
  MBOX_FILE=/path/thread.mbox  # local mbox file ('.mbox' or '.mbox.gz')
  JOBS=<n>                     # build -j<n>
  DO_BUILD=1|0                 # build after patching (default 1)
  CONFIG_TRY_ENABLE=1|0        # try enabling CONFIG_DCACHE_SMO (default 1)

Examples:
  MBOX_URL="https://lore.kernel.org/lkml/<thread>/t.mbox.gz" ./apply_smo_patch.sh
  MBOX_FILE="/tmp/smo_series.mbox.gz" TAG=v5.1-rc4 ./apply_smo_patch.sh
USAGE
}

# print usage if no URL/file provided
if [[ -z "${MBOX_URL}" && -z "${MBOX_FILE}" ]]; then
  usage
  echo
  echo "ERROR: Provide MBOX_URL or MBOX_FILE."
  exit 1
fi

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }

need_cmd git
need_cmd tar || true
need_cmd gzip || true
need_cmd xz || true
need_cmd sed
need_cmd awk
need_cmd grep
# curl or wget
if command -v curl >/dev/null 2>&1; then DL="curl -fsSL"
elif command -v wget >/dev/null 2>&1; then DL="wget -qO-"
else echo "Missing: curl or wget"; exit 1; fi

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

echo "==> Work dir: $LINUX_DIR"
mkdir -p "$LINUX_DIR"

if [[ ! -d "$LINUX_DIR/.git" ]]; then
  echo "==> Cloning linux.git..."
  if [[ "${SHALLOW_CLONE:-1}" == "1" ]]; then
    git clone --depth=1 --branch "$TAG" "$GIT_REMOTE" "$LINUX_DIR"
  else
    git clone --branch "$TAG" "$GIT_REMOTE" "$LINUX_DIR"
  fi
else
  echo "==> Existing repo found; resetting to $TAG"
  (cd "$LINUX_DIR" && git fetch --tags "$GIT_REMOTE" && git reset --hard "$TAG")
  (cd "$LINUX_DIR" && git fetch --unshallow >/dev/null 2>&1 || true)
fi

# obtain mbox into $tmpdir/series.mbox
mbox="$tmpdir/series.mbox"
if [[ -n "$MBOX_URL" ]]; then
  echo "==> Downloading mbox from: $MBOX_URL"
  $DL "$MBOX_URL" > "$mbox" || { echo "Download failed"; exit 1; }
elif [[ -n "$MBOX_FILE" ]]; then
  echo "==> Using local mbox: $MBOX_FILE"
  cp "$MBOX_FILE" "$mbox"
fi


# Detect gzip by magic & decompress regardless of suffix
if gzip -t "$mbox" >/dev/null 2>&1; then
  # stream-decompress to a plain mbox (suffix-agnostic)
  gzip -cd "$mbox" > "${mbox}.plain" || { echo "Failed to decompress mbox"; exit 1; }
  mv "${mbox}.plain" "$mbox"
fi


echo "==> Verifying mbox content..."
head -n 20 "$mbox" | sed -e 's/^/> /'

echo "==> Applying patch series with git am (3-way)..."
cd "$LINUX_DIR"
git am --abort >/dev/null 2>&1 || true
if ! git am -3 --empty=drop "$mbox"; then
  echo
  echo "!! git am failed (conflicts). You can resolve manually, then run:"
  echo "   git am --continue   # or 'git am --abort' to rollback"
  exit 2
fi

# Try to enable CONFIG_DCACHE_SMO if present
if [[ "$CONFIG_TRY_ENABLE" == "1" ]]; then
  echo "==> Trying to enable CONFIG_DCACHE_SMO (if added by the series)..."
  if grep -R --line-number -E '^\s*config\s+DCACHE_SMO\b' . >/dev/null 2>&1; then
    # Create a baseline config if none
    if [[ ! -f .config ]]; then
      echo "---- generating defconfig"
      make olddefconfig >/dev/null 2>&1 || make defconfig
    fi
    # Append, then normalize
    if ! grep -q '^CONFIG_DCACHE_SMO=' .config 2>/dev/null; then
      echo 'CONFIG_DCACHE_SMO=y' >> .config
    fi
    yes "" | make olddefconfig >/dev/null
    echo "---- CONFIG_DCACHE_SMO enabled."
  else
    echo "---- Kconfig symbol DCACHE_SMO not found. Skipping."
  fi
fi

if [[ "$DO_BUILD" == "1" ]]; then
  echo "==> Building kernel (this can take a while)..."
  # Ensure we have a config
  if [[ ! -f .config ]]; then
    make defconfig
  fi
  make -j"$JOBS"
  echo "==> Build finished."
else
  echo "==> Skipping build as requested (DO_BUILD=0)."
fi

echo
echo "All done!"
echo "Repo: $LINUX_DIR"
echo "Current HEAD:"
git --no-pager log --oneline -n1

