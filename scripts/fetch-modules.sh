#!/usr/bin/env bash
#
# Fetch the kernel modules that belong to the prebuilt kernel Image and stage
# them into the recovery ramdisk.
#
# Companion to scripts/fetch-kernel.sh.  The tarball is produced by
# S0SL/android_kernel_xiaomi_sm8350 (`ci/package-modules.sh`,
# MAKE_TARGET="Image modules"); it must come from the *same commit and the same
# build* as the Image, because CONFIG_LOCALVERSION_AUTO=y puts the commit hash
# into vermagic -- a module from another build can never be loaded.
#
# See docs/RAMDISK-MODULES.md (and docs/kernel-prep/README.md for the
# kernel-side half, which is prepared but not pushed).
#
# Usage:
#   ./scripts/fetch-modules.sh [<url>] [--stage-into <dir>] [--image <path>]
#
# Defaults:
#   <url>           $MODULES_URL, else the recovery-test pre-release asset
#   --stage-into    recovery/root/lib/modules  (empty = do not stage)
#   --image         prebuilt/Image
#
# Staging deliberately copies **no** modules.load / modules.load.recovery:
# first-stage init prefers modules.load.recovery in recovery mode and LOG(FATAL)s
# if any listed module fails to load, which would break the OrangeFox-installer
# path (recovery running on the ROM's kernel).  TWRP's own loader tolerates
# failures and falls back to the ROM's /vendor/lib/modules, so one artifact
# works both standalone and installed.  See docs/RAMDISK-MODULES.md §3.1.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
URL="${MODULES_URL:-https://github.com/S0SL/android_kernel_xiaomi_sm8350/releases/download/boot-img-LOS23.2-20260930-bakasu/kernel-modules.tar.gz}"
STAGE="$ROOT/recovery/root/lib/modules"
IMAGE="$ROOT/prebuilt/Image"
DEST="$ROOT/prebuilt/modules"

while [ $# -gt 0 ]; do
	case "$1" in
		--stage-into) STAGE="$2"; shift 2 ;;
		--image) IMAGE="$2"; shift 2 ;;
		--dest) DEST="$2"; shift 2 ;;
		--no-stage) STAGE=""; shift ;;
		-h|--help) sed -n '2,40p' "$0"; exit 0 ;;
		http*) URL="$1"; shift ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/root"

echo "== fetching kernel modules =="
echo "   url   : $URL"
curl -fsSL --retry 3 --retry-delay 5 -o "$TMP/modules.tar.gz" "$URL"

tar -xzf "$TMP/modules.tar.gz" -C "$TMP/root"

# The tarball is either a flat *.ko set or a modules_install tree
# (lib/modules/<release>/...).  Find the directory that holds the modules.
KODIR="$(dirname "$(find "$TMP/root" -maxdepth 3 -name '*.ko' | head -1)")"
[ -n "$KODIR" ] && [ -d "$KODIR" ] || { echo "ERROR: no *.ko in the tarball" >&2; exit 1; }
KVER="$(basename "$KODIR")"
COUNT="$(find "$KODIR" -maxdepth 1 -name '*.ko' | wc -l)"
echo "== $COUNT modules, kernel release '$KVER' =="

# The modules the recovery cannot work without.
MISSING=0
for want in fts_touch_spi.ko xiaomi_touch.ko msm_drm.ko; do
	if [ -f "$KODIR/$want" ]; then
		echo "   ok       $want"
	else
		echo "   MISSING  $want"
		MISSING=1
	fi
done
[ "$MISSING" = 0 ] || { echo "ERROR: the recovery's touch/display modules are not in this tarball" >&2; exit 1; }

# vermagic must match the Image we ship (same build => same release string).
if [ -f "$IMAGE" ]; then
	IMG_VER="$(strings "$IMAGE" | grep -m1 '^Linux version ' | awk '{print $3}')"
	MOD_VER="$(strings "$KODIR/fts_touch_spi.ko" | grep -m1 '^vermagic=' | cut -d= -f2 | awk '{print $1}')"
	echo "   Image  version: $IMG_VER"
	echo "   module vermagic: $MOD_VER"
	if [ -n "$IMG_VER" ] && [ -n "$MOD_VER" ] && [ "$IMG_VER" != "$MOD_VER" ]; then
		echo "ERROR: vermagic mismatch -- these modules cannot be loaded into that Image" >&2
		echo "       (modules must be built in the same run as the Image)" >&2
		exit 1
	fi
else
	echo "   (skipping the vermagic check: $IMAGE does not exist yet)"
fi

# Keep a copy in the tree for the build, and stage the runtime set.
mkdir -p "$DEST"
cp -v "$KODIR"/*.ko "$DEST/"
for meta in modules.dep modules.alias modules.softdep modules.order; do
	[ -f "$KODIR/$meta" ] && cp -v "$KODIR/$meta" "$DEST/"
done

if [ -n "$STAGE" ]; then
	mkdir -p "$STAGE"
	# flat basenames: this is what /lib/modules in the ramdisk gets
	cp -v "$DEST"/*.ko "$STAGE/"
	for meta in modules.dep modules.alias modules.softdep; do
		[ -f "$DEST/$meta" ] && cp -v "$DEST/$meta" "$STAGE/"
	done
	# TWRP reads its own generated list; make sure we never ship init's.
	rm -f "$STAGE/modules.load" "$STAGE/modules.load.recovery" "$STAGE/modules.load.twrp"
	echo "== staged $(find "$STAGE" -maxdepth 1 -name '*.ko' | wc -l) modules into ${STAGE#$ROOT/} =="
	echo "   (deliberately no modules.load / modules.load.recovery -- see the header)"
fi

echo "== done =="
