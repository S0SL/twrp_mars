#!/usr/bin/env bash
#
# Sync the OrangeFox `fox_14.1` build system.
#
# IMPORTANT: `repo init -u https://gitlab.com/OrangeFox/sync.git -b fox_14.1`
# does NOT work.  OrangeFox/sync has exactly ONE branch (`master`):
#
#   $ git ls-remote --heads https://gitlab.com/OrangeFox/sync.git
#   53a303ec...  refs/heads/master
#
# fox_14.1 is a *legacy* branch: the supported procedure is to clone the sync
# tools and run orangefox_sync.sh --branch 14.1, which
#   1. repo init  --depth=1 -u https://github.com/nebrassy/platform_manifest_twrp_aosp.git -b twrp-14
#   2. repo sync  --force-sync -c -j<n> --no-clone-bundle --no-tags
#   3. patches build/make, system/vold, system/update_engine,
#      .repo/manifests/remove-minimal.xml and vendor/twrp
#   4. clones device/qcom/common, device/qcom/twrp-common, external/se_omapi
#   5. replaces bootable/recovery with OrangeFox/bootable/Recovery (fox_14.1)
#      and vendor/recovery with OrangeFox/vendor/recovery (main)
#
# Source: https://gitlab.com/OrangeFox/sync/-/blob/master/orangefox_sync.sh
#         https://gitlab.com/OrangeFox/sync/-/blob/master/README.md
#
# Usage:
#   ./scripts/fox-sync.sh [<absolute target dir>]
#
# Env:
#   FOX_DIR        same as $1 (default: $HOME/fox_14.1)
#   FOX_SYNC_REPO  default https://gitlab.com/OrangeFox/sync.git
#
set -euo pipefail

FOX_DIR="${1:-${FOX_DIR:-$HOME/fox_14.1}}"
FOX_SYNC_REPO="${FOX_SYNC_REPO:-https://gitlab.com/OrangeFox/sync.git}"

case "$FOX_DIR" in
	/*) ;;
	*) echo "ERROR: FOX_DIR must be an absolute path (got '$FOX_DIR')" >&2; exit 1 ;;
esac

echo "== OrangeFox fox_14.1 sync =="
echo "   target : $FOX_DIR"
echo "   sync   : $FOX_SYNC_REPO"

mkdir -p "$FOX_DIR"
SYNC_TOOLS="$(mktemp -d)"
# NOTE: the tools dir must survive the script, so no trap-based cleanup here.
git clone --depth 1 "$FOX_SYNC_REPO" "$SYNC_TOOLS/sync"

# orangefox_sync.sh aborts on the first failure and does NOT run a test build.
( cd "$SYNC_TOOLS/sync" && ./orangefox_sync.sh --branch 14.1 --path "$FOX_DIR" )

echo
echo "== sync finished =="
echo "   manifest : $FOX_DIR/.repo/manifests"
echo "   recovery : $(git -C "$FOX_DIR/bootable/recovery" log -1 --format='%h %ad' --date=short)"
echo "   vendor   : $(git -C "$FOX_DIR/vendor/recovery" log -1 --format='%h %ad' --date=short)"
du -sh "$FOX_DIR" 2>/dev/null || true
