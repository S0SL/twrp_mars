#!/bin/bash
# Reproduce the "the proposed fragment has no side effect on the built-in
# kernel" claim without building anything.
#
# Usage: ./config-dryrun.sh [/path/to/android_kernel_xiaomi_sm8350]
#
# It merges the fragments exactly like ci/build-kernel.sh does -- base
# vendor/lahaina-qgki_defconfig, then vendor/debugfs.config, then
# vendor/xiaomi_QGKI.config -- snapshots the result, then merges
# arch/arm64/configs/vendor/mars_recovery_touch.config (created by
# apply-kernel-prep.sh) and diffs the two .config files.
#
# The whole diff is expected to be two lines:
#   CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI=m
#   CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE=m
#
# Only /tmp is written (O=/tmp/kout); the kernel sources are not modified.
set -uo pipefail
K="${1:-${KERNEL_DIR:-/root/mi11/work/kernel}}"
OUT=/tmp/kout
FRAG="$K/arch/arm64/configs/vendor/mars_recovery_touch.config"
rm -rf "$OUT"; mkdir -p "$OUT"

[ -f "$K/ci/build-kernel.sh" ] || { echo "ERROR: $K is not the kernel checkout" >&2; exit 1; }
[ -f "$FRAG" ] || { echo "ERROR: $FRAG is missing -- apply apply-kernel-prep.sh first" >&2; exit 1; }

kmake() { make -s -C "$K" O="$OUT" ARCH=arm64 "$@"; }

cp "$K/arch/arm64/configs/vendor/lahaina-qgki_defconfig" "$OUT/.config"
kmake olddefconfig >/dev/null 2>&1 || { echo "FAILED: base olddefconfig"; exit 1; }
for f in vendor/debugfs.config vendor/xiaomi_QGKI.config; do
	"$K/scripts/kconfig/merge_config.sh" -m -O "$OUT" "$OUT/.config" \
		"$K/arch/arm64/configs/$f" >/dev/null 2>&1 || { echo "FAILED: merge $f"; exit 1; }
	kmake olddefconfig >/dev/null 2>&1 || { echo "FAILED: olddefconfig after $f"; exit 1; }
done
cp "$OUT/.config" /tmp/config-current.txt

"$K/scripts/kconfig/merge_config.sh" -m -O "$OUT" "$OUT/.config" "$FRAG" >/dev/null 2>&1 \
	|| { echo "FAILED: merge mars_recovery_touch.config"; exit 1; }
kmake olddefconfig >/dev/null 2>&1 || { echo "FAILED: olddefconfig after the fragment"; exit 1; }
cp "$OUT/.config" /tmp/config-proposed.txt

echo "############ current chain (what the shipped Image uses) ############"
grep -E "^#? ?CONFIG_(TOUCHSCREEN_ST_FTS_V521_SPI|TOUCHSCREEN_XIAOMI_TOUCHFEATURE)\b" /tmp/config-current.txt
echo "############ proposed chain ############"
grep -E "^#? ?CONFIG_(TOUCHSCREEN_ST_FTS_V521_SPI|TOUCHSCREEN_XIAOMI_TOUCHFEATURE)\b" /tmp/config-proposed.txt
echo "############ full diff (must be exactly these two symbols) ############"
diff -u /tmp/config-current.txt /tmp/config-proposed.txt || true
