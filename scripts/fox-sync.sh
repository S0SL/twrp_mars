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
SYNC_DIR="$SYNC_TOOLS/sync"

# ---------------------------------------------------------------------------
# Work around an upstream path bug in orangefox_sync.sh.
#
# update_environment() sets
#     PATCH_VENDOR_TWRP="$BASE_DIR/patch-vendor-twrp-$FOX_DEF_BRANCH.diff"
# but the file actually lives in $BASE_DIR/patches/.  init_script() only checks
# $PATCH_FILE, so the missing file is not fatal: the script just prints
#     ./orangefox_sync.sh: line 248: ... patch-vendor-twrp-fox_14.1.diff: No such file or directory
#     -- Error! Failed to patch the twrp-14 vendor/twrp !
# and carries on with vendor/twrp UNPATCHED.  Observed in CI run 37761738123
# at 10:31:19Z.
#
# That patch matters: among other things it adds
#     include bootable/recovery/orangefox_soong.mk
# to vendor/twrp/config/BoardConfigSoong.mk, i.e. it is what pulls OrangeFox's
# Soong configuration into the build, and it also registers `tw_no_haptics`.
#
# Fix: put the file where the script looks for it.  Nothing upstream is edited.
# ---------------------------------------------------------------------------
BRANCH="14.1"
SRC_PATCH="$SYNC_DIR/patches/patch-vendor-twrp-fox_${BRANCH}.diff"
DST_PATCH="$SYNC_DIR/patch-vendor-twrp-fox_${BRANCH}.diff"
if [ -f "$SRC_PATCH" ]; then
	cp -f "$SRC_PATCH" "$DST_PATCH"
	echo "-- pre-placed $DST_PATCH (upstream path workaround)"
else
	echo "WARNING: $SRC_PATCH not found - vendor/twrp will stay unpatched" >&2
fi

# orangefox_sync.sh aborts on the first failure and does NOT run a test build.
( cd "$SYNC_DIR" && ./orangefox_sync.sh --branch "$BRANCH" --path "$FOX_DIR" )

# ---------------------------------------------------------------------------
# Post-sync verification.  The upstream script treats a failed patch as a
# warning, so check what the build actually depends on and fail fast instead of
# burning a 30 minute build on a broken tree.
# ---------------------------------------------------------------------------
echo
echo "== verifying the sync =="
RC=0
check_file() {
	if [ -e "$2" ]; then
		echo "  ok    $1"
	else
		echo "  FAIL  $1 missing: $2" >&2
		RC=1
	fi
}
check_file "OrangeFox recovery sources" "$FOX_DIR/bootable/recovery/orangefox.mk"
check_file "OrangeFox vendor tree"       "$FOX_DIR/vendor/recovery/OrangeFox_A14.sh"
check_file "vendor/twrp"                 "$FOX_DIR/vendor/twrp/config/common.mk"
check_file "qcom common"                 "$FOX_DIR/device/qcom/common"
check_file "twrp-common"                 "$FOX_DIR/device/qcom/twrp-common"
check_file "se_omapi"                    "$FOX_DIR/external/se_omapi"

if grep -q 'orangefox_soong.mk' "$FOX_DIR/vendor/twrp/config/BoardConfigSoong.mk" 2>/dev/null; then
	echo "  ok    vendor/twrp patched (orangefox_soong.mk is included)"
else
	echo "  FAIL  vendor/twrp was NOT patched: config/BoardConfigSoong.mk does not" >&2
	echo "        include bootable/recovery/orangefox_soong.mk" >&2
	RC=1
fi

if [ "$RC" != 0 ]; then
	echo "-- the OrangeFox tree is incomplete; refusing to continue" >&2
	exit 1
fi

echo
echo "== sync finished =="
echo "   manifest : $FOX_DIR/.repo/manifests"
echo "   recovery : $(git -C "$FOX_DIR/bootable/recovery" log -1 --format='%h %ad' --date=short)"
echo "   vendor   : $(git -C "$FOX_DIR/vendor/recovery" log -1 --format='%h %ad' --date=short)"
du -sh "$FOX_DIR" 2>/dev/null || true
