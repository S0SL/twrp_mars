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
#   5. kernel     -- keep $DEST/prebuilt/Image if present (auto), else
#                    scripts/fetch-kernel.sh -> device/xiaomi/mars/prebuilt/Image
#   6. build      -- lunch twrp_mars-<release>-eng ; mka bootimage (recovery-as-boot)
#   7. collect    -- dist/{boot.img,...} + BUILD-INFO.txt + sha256sums
#
# The full walkthrough, timings, hardware requirements and the troubleshooting
# table live in docs/BUILD-ON-SERVER.md.
#
# WARNING about the kernel: the recovery boots the ROM's kernel modules from
# /vendor/lib/modules at runtime (msm_drm.ko lights the panel), and with
# CONFIG_MODVERSIONS=y they only load into the matching kernel.  Keep the stock
# LineageOS 23.2 Image (5.4.302-qgki-g7ede20c8692e, sha256 2287c094…f7e8bf);
# the default --kernel-url is a BakaSU build (-g797c093f5b52) whose vermagic
# does not match.  Section 5 prints the sha256 and the version string of the
# Image it will use, so the log always says which kernel went in.
#
# Usage:
#   ./scripts/build-local.sh [options]
#
#   --fox-dir DIR        build tree            (default $FOX_DIR or ~/fox_14.1)
#   --jobs N             parallel jobs         (default: nproc, capped at 14;
#                        MARS_JOBS overrides)
#   --kernel-url URL     prebuilt kernel Image (implies --force-kernel)
#   --force-kernel       download even though prebuilt/Image already exists
#   --build-type TYPE    FOX_BUILD_TYPE        (default Unofficial)
#   --skip-sync          tree is already synced
#   --skip-kernel        prebuilt/Image is already in place (the default is
#                        "auto": keep it if it exists, download only if missing)
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
# Parallelism: derive it from the host (MARS_JOBS / --jobs overrides).  The
# build box is 24 cores / 22 GB + 17 GB swap.  Measured on it: 12 jobs ->
# 10m32s for `mka bootimage`, 16 jobs -> 15m40s, because the memory pressure
# pushes the build into swap.  MARS_JOBS=12 is what the operator uses.
#
# NOTE (v4): this value is only advisory unless it is *passed to make* -- a bare
# `mka` runs ninja at nproc+2 (=26 here), which is what the
# "Warning: high -j26 count compared to 22.1GB of RAM" line in the logs is
# about.  The build step below therefore runs `mka -j"$JOBS"`.
JOBS="${MARS_JOBS:-}"
KERNEL_URL="${KERNEL_URL:-https://github.com/S0SL/android_kernel_xiaomi_sm8350/releases/download/boot-img-LOS23.2-20260930-bakasu/anykernel3-BakaSU-susfs-v2.3.0-mars.zip}"
BUILD_TYPE="${FOX_BUILD_TYPE:-Unofficial}"
SKIP_SYNC=0
# auto = keep an already-present $DEST/prebuilt/Image, download only if missing.
# This must be the default: the recovery only shows anything when its kernel
# matches the ROM's /vendor/lib/modules, and the stock LineageOS 23.2 Image
# (5.4.302-qgki-g7ede20c8692e, sha256 2287c094…f7e8bf) is the one that matches.
# The default release URL above is the BakaSU kernel (-g797c093f5b52), whose
# vermagic does NOT match, so an automatic re-download silently breaks the
# display.  Use --force-kernel / --kernel-url when a swap is really intended.
SKIP_KERNEL=auto
FORCE_KERNEL=0
USE_CCACHE=1
CCACHE_DIR=""
CCACHE_SIZE="50G"
CLEAN=0
RELEASES=""

while [ $# -gt 0 ]; do
	case "$1" in
		--fox-dir) FOX_DIR="$2"; shift 2 ;;
		--jobs) JOBS="$2"; shift 2 ;;
		--kernel-url) KERNEL_URL="$2"; FORCE_KERNEL=1; shift 2 ;;
		--build-type) BUILD_TYPE="$2"; shift 2 ;;
		--skip-sync) SKIP_SYNC=1; shift ;;
		--skip-kernel) SKIP_KERNEL=1; shift ;;
		--force-kernel) FORCE_KERNEL=1; SKIP_KERNEL=0; shift ;;
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

# JOBS: nproc unless MARS_JOBS/--jobs says otherwise, capped at 16.
if [ -z "$JOBS" ]; then
	JOBS="$(nproc 2>/dev/null || echo 4)"
	if [ "$JOBS" -gt 14 ]; then JOBS=14; fi
fi
case "$JOBS" in
	''|*[!0-9]*) echo "ERROR: --jobs must be a positive integer (got '$JOBS')" >&2; exit 2 ;;
esac
[ "$JOBS" -ge 1 ] || { echo "ERROR: --jobs must be >= 1" >&2; exit 2; }

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
echo "   jobs      : $JOBS (passed to mka as -j$JOBS)"
echo "   build type: $BUILD_TYPE"
echo "==================================================================="

# ---------------------------------------------------------------------------
# 0. shell syntax lint
#   Recovery runs Android mksh.  Bash-only constructs such as a dotted property
#   expansion killed the v4.7 firmware script ("bad substitution",
#   /sbin/mars-fw-mount.sh[81]), so every script this tree ships is checked
#   before anything is built.
# ---------------------------------------------------------------------------
if [ -x ./scripts/check-shell.sh ]; then
	echo
	echo "== 0. shell syntax lint =="
	./scripts/check-shell.sh || { echo "shell lint failed - refusing to build"; exit 1; }
fi

if [ -x ./scripts/apply-patches.sh ]; then
	echo
	echo "== 0b. build-tree patches =="
	./scripts/apply-patches.sh "$FOX_DIR" || { echo "applying patches failed - refusing to build"; exit 1; }
fi

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
echo "   jobs: $JOBS (nproc capped at 14; --jobs N or MARS_JOBS=N to override, --jobs 4 on a small box)"

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
elif [ "$SKIP_KERNEL" = auto ] && [ "$FORCE_KERNEL" != 1 ] && [ -f "$DEST/prebuilt/Image" ]; then
	echo "   keeping the existing Image ($(du -h "$DEST/prebuilt/Image" | cut -f1))"
	echo "   --force-kernel would replace it with: $KERNEL_URL"
else
	if [ "$KERNEL_URL" = "https://github.com/S0SL/android_kernel_xiaomi_sm8350/releases/download/boot-img-LOS23.2-20260930-bakasu/anykernel3-BakaSU-susfs-v2.3.0-mars.zip" ]; then
		echo "   WARNING: no kernel was in place and --kernel-url was not given, so the" >&2
		echo "            default BakaSU release is being downloaded.  That kernel is" >&2
		echo "            '-g797c093f5b52' and does NOT match a LineageOS 23.2 ROM's" >&2
		echo "            /vendor/lib/modules (vermagic + MODVERSIONS): msm_drm.ko" >&2
		echo "            will not load and the panel stays dark." >&2
	fi
	KERNEL_FORCE=1 "$ROOT/scripts/fetch-kernel.sh" "$KERNEL_URL" "$DEST/prebuilt/Image"
fi

# ---------------------------------------------------------------------------
# Provenance of the Image that will actually end up in the boot image.
# BUILD-INFO.txt used to print $KERNEL_URL even when nothing was downloaded,
# which read as "the BakaSU kernel was used" while the stock Image was in
# place -- print what is really there, from the file itself.
# ---------------------------------------------------------------------------
if [ -f "$DEST/prebuilt/Image" ]; then
	echo "-- prebuilt/Image in use:"
	ls -l "$DEST/prebuilt/Image" | sed 's/^/   /'
	sha256sum "$DEST/prebuilt/Image" | sed 's/^/   /'
	MAGIC="$(dd if="$DEST/prebuilt/Image" bs=1 skip=56 count=4 status=none)"
	if [ "$MAGIC" != $'ARM\x64' ]; then
		echo "ERROR: $DEST/prebuilt/Image has no arm64 magic at 0x38" >&2
		exit 1
	fi
	if command -v strings >/dev/null 2>&1; then
		strings "$DEST/prebuilt/Image" | grep -m1 '5\.4\.302' | sed 's/^/   /' || true
	fi
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

# envsetup.sh's helpers dereference variables that do not exist until the build
# var cache has been built ($cached_vars, $BUILD_VAR_CACHE_READY).  Under
# `set -u` the first such dereference aborts the whole shell -- and because the
# cache call below sends stderr to /dev/null it does so *silently*, with no
# error line at all.  That is exactly how the first server build died between
# "release candidates" and the first lunch attempt.  So nounset stays off from
# here to the end of the script; -e and -o pipefail are untouched.
set +u
LUNCH_OK=0
for REL in $RELEASES; do
	CAND="twrp_mars-$REL-eng"
	# A failed lunch() returns before destroy_build_var_cache(), so clear the
	# cache between attempts instead of letting attempt N poison N+1.
	destroy_build_var_cache 2>/dev/null || true
	unset BUILD_VAR_CACHE_READY || true
	echo "   -- lunch $CAND"
	if lunch "$CAND" >"/tmp/lunch-$REL.log" 2>&1; then
		echo "      ok"
		LUNCH_OK=1
		break
	fi
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

# ---------------------------------------------------------------------------
# Which make goal actually produces an image?
#
# With `BOARD_USES_RECOVERY_AS_BOOT := true` -- which this device tree sets --
# build/make/core/Makefile:275-285 deliberately leaves
# INSTALLED_RECOVERYIMAGE_TARGET EMPTY:
#
#     ifneq ($(BOARD_USES_RECOVERY_AS_BOOT),true)
#     INSTALLED_RECOVERYIMAGE_TARGET := $(PRODUCT_OUT)/recovery.img
#     endif
#
# so `mka recoveryimage` is a goal with NO prerequisites.  ninja then prints
# "no work to do", the build reports success in ~5 minutes, and not a single
# .img file exists -- which is exactly the failure that made the systemd unit
# restart eight times against an empty dist/.  Neither `make` nor `repo` ever
# says a word about it.
#
# In this configuration the image is produced by the *boot* target:
# Makefile:2424-2426, inside the BUILDING_RECOVERY_IMAGE branch, does
#
#     ifeq ($(BOARD_USES_RECOVERY_AS_BOOT),true)
#     INSTALLED_BOOTIMAGE_TARGET := $(BUILT_BOOTIMAGE_TARGET)
#     endif
#
# i.e. $(PRODUCT_OUT)/boot.img is built *with* the recovery ramdisk inside it.
# (board_config.mk:448-462 keeps BUILDING_BOOT_IMAGE empty for this config,
# which is why this had to be verified by running `mka bootimage`, not inferred
# from the variable.)
# ---------------------------------------------------------------------------
RASB="$(get_build_var BOARD_USES_RECOVERY_AS_BOOT 2>/dev/null || true)"
if [ "$RASB" = "true" ]; then
	GOALS="${MARS_BUILD_GOALS:-bootimage}"
else
	GOALS="${MARS_BUILD_GOALS:-recoveryimage bootimage}"
fi

# ---------------------------------------------------------------------------
# UFFD GC -- second half of the fix (see the comment in device.mk).
#
# Setting PRODUCT_ENABLE_UFFD_GC in the product config is NOT enough in this
# build/make fork: art_config.mk:14 does
#     config_enable_uffd_gc := $(firstword $(OVERRIDE_ENABLE_UFFD_GC) $(PRODUCT_ENABLE_UFFD_GC) default)
# and the PRODUCT_* value either is not promoted to a global at that point or is
# stripped again, so the generated product/etc/build.prop still contained
# `ro.dalvik.vm.enable_uffd_gc=default` and post_process_props aborted the build
# at 98% with:
#     Unable to determine UFFD GC flag for kernel version "5.4.302-qgki-..."
# OVERRIDE_ENABLE_UFFD_GC is the escape hatch the source names explicitly
# ("Can be passed from the commandline", art_config.mk:5) and it is never
# reassigned by any makefile, so a command-line/environment value is guaranteed
# to win.  Passed BOTH ways so it does not matter whether soong_ui sanitises the
# environment.
# ---------------------------------------------------------------------------
UFFD_GC="${OVERRIDE_ENABLE_UFFD_GC:-false}"
export OVERRIDE_ENABLE_UFFD_GC="$UFFD_GC"
echo "   OVERRIDE_ENABLE_UFFD_GC=$UFFD_GC"
echo "   BOARD_USES_RECOVERY_AS_BOOT='$RASB' -> mka $GOALS OVERRIDE_ENABLE_UFFD_GC=$UFFD_GC (log: $LOG)"
set +e
mka -j"$JOBS" $GOALS "OVERRIDE_ENABLE_UFFD_GC=$UFFD_GC" 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}
set -e
if [ "$RC" != 0 ]; then
	echo "ERROR: mka $GOALS failed (exit $RC)." >&2
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
# Never hard-code the product directory.  Capture PRODUCT_OUT from the lunch
# that was just done, and fall back through the names the build system may have
# used.  (The lunch target is twrp_mars, but the output directory is named after
# TARGET_DEVICE = mars.)
OUT="$(get_build_var PRODUCT_OUT 2>/dev/null || true)"
if [ -z "$OUT" ] || [ ! -d "$OUT" ]; then
	DEV="$(get_build_var TARGET_DEVICE 2>/dev/null || true)"
	[ -n "$DEV" ] || DEV=mars
	OUT="$FOX_DIR/out/target/product/$DEV"
fi
[ -d "$OUT" ] || OUT="$FOX_DIR/out/target/product/mars"
echo "   PRODUCT_OUT: $OUT"
mkdir -p "$DIST"
# maxdepth 2 also picks up out/dist and out/target/product/<dev>/recovery/.
# Each directory is tested first: `find` exits non-zero when a path does not
# exist, and under `set -e` that silently kills the script right here -- which is
# exactly how the first successful build lost its BUILD-INFO.txt.
for d in "$OUT" "$FOX_DIR/out/dist"; do
	[ -d "$d" ] || continue
	find "$d" -maxdepth 2 -type f \
		\( -name 'boot.img' -o -name 'recovery.img' -o -name 'vendor_boot.img' \
		   -o -name 'OrangeFox-*.zip' -o -name 'dtbo.img' \) \
		-exec cp -v {} "$DIST/" \;
done

# An *image* is required.  "the command exited 0" is not evidence that anything
# was built -- see the goal discussion above section 6.
HAVE_IMG=0
for f in "$DIST/boot.img" "$DIST/recovery.img" "$DIST/vendor_boot.img"; do
	[ -f "$f" ] && HAVE_IMG=1
done
if [ "$HAVE_IMG" != 1 ]; then
	{
		echo "ERROR: no boot/recovery/vendor_boot image was produced."
		echo "       PRODUCT_OUT       : $OUT"
		echo "       goals requested   : mka $GOALS"
		echo "       BOARD_USES_RECOVERY_AS_BOOT: '$RASB'"
		echo
		echo "       files actually present in $OUT (depth <= 2):"
		find "$OUT" -maxdepth 2 2>/dev/null | head -60 | sed 's/^/         /'
		echo
		echo "       every .img anywhere under $FOX_DIR/out:"
		find "$FOX_DIR/out" -name '*.img' 2>/dev/null | head -40 | sed 's/^/         /'
		echo
		echo "       last 40 lines of $LOG:"
		tail -40 "$LOG" 2>/dev/null | sed 's/^/         /'
	} >&2
	exit 1
fi

{
	echo "mars / twrp_mars-$BUILD_TYPE / fox_14.1 -- built on $(hostname)"
	echo "date:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "tree:   $FOX_DIR"
	# The Image that is really in there -- NOT $KERNEL_URL, which is only the
	# URL that *would* be downloaded and was misleading whenever the existing
	# prebuilt/Image was kept.
	if [ -f "$DEST/prebuilt/Image" ]; then
		echo "kernel Image: $DEST/prebuilt/Image"
		echo "kernel sha256: $(sha256sum "$DEST/prebuilt/Image" | cut -d' ' -f1)"
		if command -v strings >/dev/null 2>&1; then
			echo "kernel version: $(strings "$DEST/prebuilt/Image" | grep -m1 '5\.4\.302' || true)"
		fi
	else
		echo "kernel Image: MISSING"
	fi
	echo "kernel url (only used if a download happened): $KERNEL_URL"
	echo "jobs: $JOBS"
	echo "build type: $BUILD_TYPE"
	echo
	sha256sum "$DIST"/* | sed "s|$DIST/||"
} > "$DIST/BUILD-INFO.txt"

echo
echo "   artifacts in $DIST:"
ls -lh "$DIST" | sed 's/^/   /'
echo
echo "   flash/boot it with (nothing is flashed by this script):"
# mars has no recovery partition, so boot.img IS the recovery.  Only ever
# `fastboot boot` it first; flash only once the recovery actually comes up.
[ -f "$DIST/boot.img" ] && echo "     fastboot boot boot.img      # try it, changes nothing"
[ -f "$DIST/recovery.img" ] && echo "     (recovery.img is a side product -- do NOT flash it on mars)"
echo
printf '== done: total %dm%02ds ==\n' $(( (SECONDS - T0) / 60 )) $(( (SECONDS - T0) % 60 ))
