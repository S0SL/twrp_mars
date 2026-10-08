#!/usr/bin/env bash
#
# Build the Xiaomi Mi 11 Pro (mars) OrangeFox recovery on a plain Ubuntu
# machine -- the server counterpart of .github/workflows/build-recovery.yml.
#
# It runs the same steps without any CI plumbing (no caches, no artifact
# upload) and is written to be the single source of truth for them:
#
#   1. preflight  -- disk, RAM, tools, and the OrangeFox tree layout
#   2. ccache     -- optional but strongly recommended (see docs/BUILD-ON-SERVER.md)
#   3. sync       -- scripts/fox-sync.sh (orangefox_sync.sh --branch 14.1)
#   4. device tree-- rsync this working copy into <tree>/device/xiaomi/mars
#   5. kernel     -- scripts/fetch-kernel.sh -> device/xiaomi/mars/prebuilt/Image
#   6. build      -- lunch twrp_mars-<release>-eng ; mka recoveryimage
#   7. collect    -- dist/{boot.img,...} + BUILD-INFO.txt + sha256sums
#
# The full walkthrough, timings, hardware requirements and the troubleshooting
# table live in docs/BUILD-ON-SERVER.md.
#
# Usage:
#   ./scripts/build-local.sh [options]
#
#   --fox-dir DIR        build tree            (default $FOX_DIR or ~/fox_14.1)
#   --jobs N             parallel jobs         (default: nproc)
#   --kernel-url URL     prebuilt kernel Image (default: the release CI uses)
#   --build-type TYPE    FOX_BUILD_TYPE        (default Unofficial)
#   --skip-sync          tree is already synced
#   --skip-kernel        prebuilt/Image is already in place
#   --no-ccache          do not configure ccache
#   --ccache-dir DIR     (default <tree>/.ccache)
#   --ccache-size SIZE   (default 50G)
#   --clean              remove out/ first
#   --releases "a b c"   lunch release tokens to try (default: discovered from
#                        build/release/release_configs, then ap2a ap3a bp2a)
#   -h|--help
#
set -euo pipefail

# ---------------------------------------------------------------------------
# arguments / defaults
# ---------------------------------------------------------------------------
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FOX_DIR="${FOX_DIR:-$HOME/fox_14.1}"
JOBS="$(nproc 2>/dev/null || echo 4)"
KERNEL_URL="${KERNEL_URL:-https://github.com/S0SL/android_kernel_xiaomi_sm8350/releases/download/boot-img-LOS23.2-20260930-bakasu/anykernel3-BakaSU-susfs-v2.3.0-mars.zip}"
BUILD_TYPE="${FOX_BUILD_TYPE:-Unofficial}"
SKIP_SYNC=0
SKIP_KERNEL=0
USE_CCACHE=1
CCACHE_DIR=""
CCACHE_SIZE="50G"
CLEAN=0
RELEASES=""

while [ $# -gt 0 ]; do
	case "$1" in
		--fox-dir) FOX_DIR="$2"; shift 2 ;;
		--jobs) JOBS="$2"; shift 2 ;;
		--kernel-url) KERNEL_URL="$2"; shift 2 ;;
		--build-type) BUILD_TYPE="$2"; shift 2 ;;
		--skip-sync) SKIP_SYNC=1; shift ;;
		--skip-kernel) SKIP_KERNEL=1; shift ;;
		--no-ccache) USE_CCACHE=0; shift ;;
		--ccache-dir) CCACHE_DIR="$2"; shift 2 ;;
		--ccache-size) CCACHE_SIZE="$2"; shift 2 ;;
		--clean) CLEAN=1; shift ;;
		--releases) RELEASES="$2"; shift 2 ;;
		-h|--help) sed -n '2,40p' "$0"; exit 0 ;;
		*) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
	esac
done

case "$FOX_DIR" in
	/*) ;;
	*) echo "ERROR: --fox-dir must be an absolute path (got '$FOX_DIR')" >&2; exit 1 ;;
esac
[ -z "$CCACHE_DIR" ] && CCACHE_DIR="$FOX_DIR/.ccache"

DEST="$FOX_DIR/device/xiaomi/mars"
DIST="$ROOT/dist"
LOG="$ROOT/build.log"
T0=$SECONDS
phase_start() { PHASE_T0=$SECONDS; }
phase_done() { printf '   ... %s: %dm%02ds\n' "$1" $(( (SECONDS - PHASE_T0) / 60 )) $(( (SECONDS - PHASE_T0) % 60 )); }

echo "==================================================================="
echo " mars OrangeFox recovery -- local build"
echo "   workspace : $ROOT"
echo "   tree      : $FOX_DIR"
echo "   device dir: $DEST"
echo "   jobs      : $JOBS"
echo "   build type: $BUILD_TYPE"
echo "==================================================================="

# ---------------------------------------------------------------------------
# 1. preflight
# ---------------------------------------------------------------------------
echo
echo "== 1. preflight =="
phase_start

FREE_GB=$(df -Pk "$(dirname "$FOX_DIR")" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}')
if [ -n "${FREE_GB:-}" ]; then
	echo "   free disk where the tree will live: ${FREE_GB} GB"
	if [ "$FREE_GB" -lt 120 ]; then
		echo "   WARNING: the tree plus out/ needs roughly 150 GB; a full build" >&2
		echo "            has been observed at ~120 GB used with out/ still to come." >&2
	fi
fi
MEM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
echo "   RAM: ${MEM_GB} GB (linking needs headroom; 16 GB+ recommended)"
echo "   jobs: $JOBS (use --jobs 4-6 on a memory-constrained machine)"

# Dependency check.  The apt package set is the same one the CI installs (see
# docs/BUILD-ON-SERVER.md); printing the exact command matters, because the
# server operator will paste it.
have_pkg() { command -v dpkg >/dev/null 2>&1 && dpkg -s "$1" >/dev/null 2>&1; }
APT_PKGS="bc bison build-essential ccache cpio curl flex git git-lfs gnupg gperf
imagemagick libelf-dev libssl-dev libxml2-utils lzop pngcrush rsync schedtool
squashfs-tools unzip xsltproc zip zlib1g-dev zstd lz4 python3 patchelf
gcc-multilib g++-multilib libc6-dev-i386 lib32z1-dev libncurses5-dev"
MISSING_PKGS=""
for p in $APT_PKGS; do
	have_pkg "$p" || MISSING_PKGS="$MISSING_PKGS $p"
done
for t in git repo python3 java rsync zip unzip ccache lz4 zstd make; do
	if command -v "$t" >/dev/null 2>&1; then
		printf '   ok       %-8s %s\n' "$t" "$(command -v "$t")"
	else
		printf '   MISSING  %-8s\n' "$t"
	fi
done
if [ -n "$MISSING_PKGS" ]; then
	echo
	echo "   missing apt packages:$MISSING_PKGS"
	echo "   -> sudo apt-get update"
	echo "   -> sudo apt-get install -y$MISSING_PKGS openjdk-17-jdk-headless"
fi
command -v repo >/dev/null 2>&1 || {
	echo "   -> repo (needed by scripts/fox-sync.sh):"
	echo "      mkdir -p ~/bin && curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o ~/bin/repo && chmod +x ~/bin/repo"
	echo "      export PATH=\"\$HOME/bin:\$PATH\""
}
[ -f "$ROOT/BoardConfig.mk" ] || { echo "ERROR: $ROOT is not the mars device tree" >&2; exit 1; }
phase_done preflight

# ---------------------------------------------------------------------------
# 2. ccache
# ---------------------------------------------------------------------------
if [ "$USE_CCACHE" = 1 ] && command -v ccache >/dev/null 2>&1; then
	echo
	echo "== 2. ccache =="
	export USE_CCACHE=1
	export CCACHE_DIR
	export CCACHE_EXEC="$(command -v ccache)"
	mkdir -p "$CCACHE_DIR"
	ccache -M "$CCACHE_SIZE" >/dev/null 2>&1 || true
	ccache -s 2>/dev/null | sed 's/^/   /' | head -8 || true
	echo "   CCACHE_DIR=$CCACHE_DIR (size $CCACHE_SIZE)"
	[ "$CLEAN" = 1 ] && echo "   --clean given: ccache still helps, out/ is rebuilt"
fi

# ---------------------------------------------------------------------------
# 3. sync the OrangeFox tree
# ---------------------------------------------------------------------------
if [ "$SKIP_SYNC" = 1 ]; then
	echo
	echo "== 3. sync skipped (--skip-sync) =="
else
	echo
	echo "== 3. sync OrangeFox fox_14.1 (this is the long one) =="
	phase_start
	# fox-sync.sh is pure build logic (no CI caches/uploads); it refuses to
	# continue if the vendor/twrp patch did not apply.
	"$ROOT/scripts/fox-sync.sh" "$FOX_DIR"
	phase_done sync
fi

# ---------------------------------------------------------------------------
# 4. install the device tree
# ---------------------------------------------------------------------------
echo
echo "== 4. device tree -> $DEST =="
mkdir -p "$DEST"
# No --delete: prebuilt/Image is git-ignored and therefore absent from this
# working copy, so a mirroring rsync would throw away the kernel just fetched.
rsync -a \
	--exclude '.git/' \
	--exclude '.github/' \
	--exclude 'scripts/' \
	--exclude 'docs/' \
	--exclude 'dist/' \
	--exclude 'build.log' \
	--exclude 'prebuilt/Image' \
	"$ROOT/" "$DEST/"
echo "   files: $(find "$DEST" -type f | wc -l)"

# ---------------------------------------------------------------------------
# 5. prebuilt kernel Image
# ---------------------------------------------------------------------------
echo
echo "== 5. prebuilt kernel =="
if [ "$SKIP_KERNEL" = 1 ] && [ -f "$DEST/prebuilt/Image" ]; then
	echo "   skipped (--skip-kernel), using $(du -h "$DEST/prebuilt/Image" | cut -f1) existing Image"
else
	"$ROOT/scripts/fetch-kernel.sh" "$KERNEL_URL" "$DEST/prebuilt/Image"
fi

# ---------------------------------------------------------------------------
# 6. lunch + build
# ---------------------------------------------------------------------------
echo
echo "== 6. build =="
phase_start
cd "$FOX_DIR"

export LC_ALL=C
export FOX_BUILD_DEVICE=mars
export FOX_BUILD_TYPE="$BUILD_TYPE"
export ALLOW_MISSING_DEPENDENCIES=true

if [ "$CLEAN" = 1 ]; then
	echo "   removing out/ (--clean)"
	rm -rf out
fi

# build/envsetup.sh dereferences unset variables (TOP, ...) and aborts under
# `set -u`, so relax nounset for the source; keep -e -o pipefail.
set +u
# shellcheck disable=SC1091
source build/envsetup.sh || echo "-- note: envsetup.sh returned $?"
set -u
type lunch >/dev/null 2>&1 || { echo "ERROR: build/envsetup.sh did not define lunch()" >&2; exit 1; }

if [ -z "$RELEASES" ]; then
	# Authoritative list, straight from the tree.  The release token is NOT
	# guessable: CI run 5 died with
	#   No release config found for TARGET_RELEASE: bp2a. Available releases are: ap2a.
	if [ -d build/release/release_configs ]; then
		RELEASES="$(ls -1 build/release/release_configs 2>/dev/null \
			| sed -e 's/\.textproto$//' -e 's/\.json$//' -e 's/\.scl$//' -e 's/\.mk$//' \
			| sort -u | tr '\n' ' ')"
	fi
	RELEASES="$RELEASES ap2a ap3a bp2a"
fi
echo "   release candidates: $RELEASES"

LUNCH_OK=0
for REL in $RELEASES; do
	CAND="twrp_mars-$REL-eng"
	# A failed lunch() returns before destroy_build_var_cache(), so clear the
	# cache between attempts instead of letting attempt N poison N+1.
	destroy_build_var_cache 2>/dev/null || true
	unset BUILD_VAR_CACHE_READY || true
	echo "   -- lunch $CAND"
	set +u
	if lunch "$CAND" >"/tmp/lunch-$REL.log" 2>&1; then
		set -u
		echo "      ok"
		LUNCH_OK=1
		break
	fi
	set -u
	echo "      failed:"
	sed -n '1,40p' "/tmp/lunch-$REL.log" | sed 's/^/      | /'
done
[ "$LUNCH_OK" = 1 ] || {
	echo "ERROR: no lunch combo worked.  The errors are printed above." >&2
	echo "       If it says 'No release config found', pick a token from" >&2
	echo "       build/release/release_configs and pass it with --releases." >&2
	exit 1
}

echo "   TARGET_PRODUCT=$(get_build_var TARGET_PRODUCT) TARGET_RELEASE=$(get_build_var TARGET_RELEASE)"
echo "   starting mka recoveryimage (log: $LOG)"
set +e
mka recoveryimage 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}
set -e
if [ "$RC" != 0 ]; then
	echo "ERROR: mka recoveryimage failed (exit $RC)." >&2
	echo "       Last 40 lines of $LOG:" >&2
	tail -40 "$LOG" | sed 's/^/       /' >&2
	exit "$RC"
fi
phase_done build

# ---------------------------------------------------------------------------
# 7. collect
# ---------------------------------------------------------------------------
echo
echo "== 7. collect =="
OUT="$FOX_DIR/out/target/product/mars"
mkdir -p "$DIST"
find "$OUT" -maxdepth 1 -type f \
	\( -name 'boot.img' -o -name 'recovery.img' -o -name 'vendor_boot.img' \
	   -o -name 'OrangeFox-*' -o -name 'dtbo.img' \) \
	-exec cp -v {} "$DIST/" \;
[ -n "$(ls -A "$DIST" 2>/dev/null)" ] || { echo "ERROR: no images in $OUT" >&2; exit 1; }

{
	echo "mars / twrp_mars-$BUILD_TYPE / fox_14.1 -- built on $(hostname)"
	echo "date:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "tree:   $FOX_DIR"
	echo "kernel: $KERNEL_URL"
	echo "build type: $BUILD_TYPE"
	echo
	sha256sum "$DIST"/* | sed "s|$DIST/||"
} > "$DIST/BUILD-INFO.txt"

echo
echo "   artifacts in $DIST:"
ls -lh "$DIST" | sed 's/^/   /'
echo
echo "   flash/boot it with (nothing is flashed by this script):"
for f in "$DIST"/*.img; do
	[ -e "$f" ] && echo "     fastboot boot $(basename "$f")"
done
echo
printf '== done: total %dm%02ds ==\n' $(( (SECONDS - T0) / 60 )) $(( (SECONDS - T0) % 60 ))
