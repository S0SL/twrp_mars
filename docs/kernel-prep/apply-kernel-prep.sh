#!/usr/bin/env bash
#
# Prepare -- NOT push -- the S0SL/android_kernel_xiaomi_sm8350 change that lets
# the recovery ship touch/display kernel modules built from the same source and
# commit as the prebuilt Image it boots.
#
# Rationale, measurements and the recovery-side half of the plan:
#   twrp_mars/docs/RAMDISK-MODULES.md
#
# What it does, in one commit's worth of changes:
#
#   1. new config fragment arch/arm64/configs/vendor/mars_recovery_touch.config
#      with exactly two =m symbols:
#         CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI=m      -> fts_touch_spi.ko
#         CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE=m  -> xiaomi_touch.ko
#      (a dry run of the merge chain shows the *entire* resulting .config diff
#       is those two lines: no built-in driver changes, no `select` triggered)
#   2. ci/build-kernel.sh: merge that fragment, and build "Image modules"
#   3. ci/package-modules.sh (new): modules_install + dist/kernel-modules-<kver>.tar.gz
#   4. .github/workflows/build-kernel.yml: run (3) and upload the tarball next
#      to the existing AnyKernel3 zip / boot.img assets
#
# Usage:
#   ./apply-kernel-prep.sh [--target DIR] [--revert]
#
#   --target DIR   kernel checkout (default: the current directory)
#   --revert       undo everything this script created/modified (git checkout
#                  for tracked files + rm for the two new files).  Untracked
#                  build output (out/, modules_root/, dist/) is left alone.
#
# Idempotent: re-running skips steps that are already applied.
#
set -euo pipefail

TARGET="."
REVERT=0
while [ $# -gt 0 ]; do
	case "$1" in
		--target) TARGET="$2"; shift 2 ;;
		--revert) REVERT=1; shift ;;
		-h|--help) sed -n '2,40p' "$0"; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done
cd "$TARGET"

FRAGMENT="arch/arm64/configs/vendor/mars_recovery_touch.config"
PKG_SCRIPT="ci/package-modules.sh"
BUILD_SH="ci/build-kernel.sh"
WORKFLOW=".github/workflows/build-kernel.yml"

[ -f "$BUILD_SH" ] && [ -f arch/arm64/configs/vendor/xiaomi_QGKI.config ] || {
	echo "ERROR: $PWD does not look like S0SL/android_kernel_xiaomi_sm8350" >&2
	exit 1
}

if [ "$REVERT" = 1 ]; then
	git checkout -- "$BUILD_SH" "$WORKFLOW" 2>/dev/null || true
	rm -f "$FRAGMENT" "$PKG_SCRIPT"
	echo "-- reverted; git status:"
	git status --short
	exit 0
fi

# ---------------------------------------------------------------------------
echo "== 1/4 $FRAGMENT =="
cat > "$FRAGMENT" <<'EOF'
# Touch drivers the mars recovery needs, built as modules instead of being
# absent.  Same two symbols LineageOS' vendor/star_QGKI.config sets for
# mars/star/venus.
#
# Measured side effect on the built-in kernel: none.  Merging this fragment
# after vendor/lahaina-qgki_defconfig + vendor/debugfs.config +
# vendor/xiaomi_QGKI.config changes exactly these two lines in the resulting
# .config (both Kconfig entries are plain tristate with only
# `depends on I2C` / `depends on INPUT_TOUCHSCREEN` -- no `select`):
#   -# CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI is not set
#   +CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI=m
#   -# CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE is not set
#   +CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE=m
#
# The modules must be built in the same run as the Image: CONFIG_LOCALVERSION_AUTO
# puts the commit hash into vermagic, so modules from another build can never be
# loaded into it.
CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI=m
CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE=m
EOF
echo "   written"

# ---------------------------------------------------------------------------
echo "== 2/4 $BUILD_SH =="
python3 - "$BUILD_SH" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
orig = s

if '"vendor/mars_recovery_touch.config"' not in s:
    s2 = s.replace('\t"vendor/xiaomi_QGKI.config"\n)',
                   '\t"vendor/xiaomi_QGKI.config"\n\t"vendor/mars_recovery_touch.config"\n)')
    if s2 == s:
        sys.exit("ERROR: could not find the FRAGMENTS block in ci/build-kernel.sh")
    s = s2
    print("   + FRAGMENTS: vendor/mars_recovery_touch.config")

if 'MAKE_TARGET="${MAKE_TARGET:-Image modules}"' not in s:
    s2 = s.replace('MAKE_TARGET="${MAKE_TARGET:-Image}"',
                   'MAKE_TARGET="${MAKE_TARGET:-Image modules}"')
    if s2 == s:
        sys.exit("ERROR: could not find the MAKE_TARGET default in ci/build-kernel.sh")
    s = s2
    print("   + MAKE_TARGET default: Image modules")

if 'MAKE_TARGET="Image"' in s and 'modules' not in s.split('MAKE_TARGET=')[1][:40]:
    print("   ! check the MAKE_TARGET comment block manually")

if s != orig:
    open(p, "w").write(s)
else:
    print("   (already applied)")
PY

# ---------------------------------------------------------------------------
echo "== 3/4 $PKG_SCRIPT =="
cat > "$PKG_SCRIPT" <<'EOF'
#!/usr/bin/env bash
#
# Collect the kernel modules built by ci/build-kernel.sh into a tarball the
# recovery device tree consumes (twrp_mars: docs/RAMDISK-MODULES.md).
#
# The recovery ramdisk only needs the flat `*.ko` basenames, but
# modules_install's tree (modules.dep / modules.alias / modules.softdep) is
# what lets TWRP's libmodprobe resolve dependencies at runtime, so both are
# shipped.
#
# Env:
#   OUT    kernel O= directory (default <repo>/out)
#   DIST   output directory     (default <repo>/dist)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/out}"
DIST="${DIST:-$ROOT/dist}"
STAGE="$ROOT/modules_root"

mkdir -p "$DIST"
rm -rf "$STAGE"

kmake() { make -C "$ROOT" O="$OUT" ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- "$@"; }

echo "== modules_install -> $STAGE =="
kmake INSTALL_MOD_PATH="$STAGE" modules_install

KV="$(make -s -C "$ROOT" O="$OUT" ARCH=arm64 kernelrelease)"
echo "== kernel release: $KV =="
DIR="$STAGE/lib/modules/$KV"
[ -d "$DIR" ] || { echo "ERROR: modules_install produced no $DIR" >&2; exit 1; }

COUNT="$(find "$DIR" -maxdepth 1 -name '*.ko' | wc -l)"
echo "== $COUNT modules built =="

# The recovery depends on these three: touch (fts + xiaomi feature) and the
# panel driver (display is a module for lahaina).  Fail loudly rather than
# publishing a tarball that cannot bring the recovery UI up.
MISSING=0
for want in fts_touch_spi.ko xiaomi_touch.ko msm_drm.ko; do
	if [ -f "$DIR/$want" ]; then
		echo "   ok       $want"
	else
		echo "   MISSING  $want"
		MISSING=1
	fi
done
[ "$MISSING" = 0 ] || { echo "ERROR: the recovery's modules are not in this build" >&2; exit 1; }

TARBALL="$DIST/kernel-modules-$KV.tar.gz"
tar -C "$DIR" -czf "$TARBALL" .
printf '%s\n' "$KV" > "$DIST/kernel-modules.release"
ls -l "$TARBALL"
sha256sum "$TARBALL"
EOF
chmod +x "$PKG_SCRIPT"
echo "   written"

# ---------------------------------------------------------------------------
echo "== 4/4 $WORKFLOW =="
python3 - "$WORKFLOW" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
orig = s

step = """      - name: Package kernel modules tarball
        run: ./ci/package-modules.sh

"""
anchor = "      - name: Package AnyKernel3 zip\n        run: ./ci/package-anykernel.sh\n"
if "Package kernel modules tarball" not in s:
    if anchor not in s:
        sys.exit("ERROR: could not find the AnyKernel3 packaging step")
    s = s.replace(anchor, anchor + "\n" + step)
    print("   + step: Package kernel modules tarball")

if "dist/kernel-modules-*.tar.gz" not in s:
    path_anchor = "          path: |\n            dist/*.zip\n            dist/*.img\n"
    if path_anchor not in s:
        sys.exit("ERROR: could not find the upload step's path list")
    s = s.replace(path_anchor,
                  "          path: |\n            dist/*.zip\n            dist/*.img\n"
                  "            dist/kernel-modules-*.tar.gz\n")
    print("   + upload: dist/kernel-modules-*.tar.gz")

if s != orig:
    open(p, "w").write(s)
else:
    print("   (already applied)")
PY

echo
echo "== done -- nothing was committed or pushed =="
git status --short
