#!/usr/bin/env bash
#
# Fetch the prebuilt kernel Image for the Xiaomi Mi 11 Pro (mars).
#
# The recovery device tree uses TARGET_PREBUILT_KERNEL, so no kernel is compiled
# during the recovery build.  The Image comes from the companion kernel project:
#
#   https://github.com/S0SL/android_kernel_xiaomi_sm8350
#
# Two accepted inputs:
#   * an AnyKernel3 zip from a release  (the `Image` sits at the zip root)
#   * a direct link to a raw `Image`
#
# Usage:
#   ./scripts/fetch-kernel.sh [<url> [<output-path>]]
#
# Env:
#   KERNEL_URL     same as $1
#   OUTPUT         same as $2 (default: prebuilt/Image)
#   KERNEL_FORCE=1 overwrite an existing $OUTPUT even without a URL
#
# Rules for an existing $OUTPUT:
#   * no URL given (neither $1 nor $KERNEL_URL)  -> keep it, report it, exit 0
#   * a URL was given explicitly                  -> download it (the caller
#     asked for that kernel on purpose)
#   * KERNEL_FORCE=1                              -> always download
#
# IMPORTANT (v2/v3): this script must never silently swap the kernel back.
# The recovery only lights the panel if its kernel matches the ROM's
# /vendor/lib/modules (vermagic + CONFIG_MODVERSIONS CRCs): the LineageOS 23.2
# stock Image `5.4.302-qgki-g7ede20c8692e` (sha256 2287c094ea0291fc21f231273af3cd3d3af80efffb1f2a5f5b06aa9e04f7e8bf).
# The default release URL below still points at the BakaSU AnyKernel3 zip
# (`-g797c093f5b52`), whose vermagic does not match, so build-local.sh no longer
# calls this script at all when a prebuilt/Image is already in place.
#
set -euo pipefail

EXPLICIT_URL="${1:-${KERNEL_URL:-}}"
KERNEL_URL="${1:-${KERNEL_URL:-https://github.com/S0SL/android_kernel_xiaomi_sm8350/releases/download/boot-img-LOS23.2-20260930-bakasu/anykernel3-BakaSU-susfs-v2.3.0-mars.zip}}"
OUTPUT="${2:-${OUTPUT:-prebuilt/Image}}"

mkdir -p "$(dirname "$OUTPUT")"

if [ -f "$OUTPUT" ] && [ "${KERNEL_FORCE:-0}" != 1 ] && [ -z "$EXPLICIT_URL" ]; then
	echo "== kernel: keeping the existing Image =="
	ls -l "$OUTPUT"
	sha256sum "$OUTPUT"
	echo "   (pass a URL, or KERNEL_FORCE=1, to replace it; the built-in default is:"
	echo "    $KERNEL_URL)"
	echo "== done =="
	exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== fetching kernel =="
echo "   url    : $KERNEL_URL"
echo "   output : $OUTPUT"

curl -fsSL --retry 3 --retry-delay 5 -o "$TMP/kernel.bin" "$KERNEL_URL"

# Is it a zip (AnyKernel3) or a raw kernel image?
if unzip -l "$TMP/kernel.bin" >/dev/null 2>&1; then
	echo "-- input is a zip archive, extracting 'Image'"
	unzip -o -j "$TMP/kernel.bin" Image -d "$TMP/extracted" >/dev/null
	[ -f "$TMP/extracted/Image" ] || {
		echo "ERROR: no 'Image' entry inside $KERNEL_URL" >&2
		unzip -l "$TMP/kernel.bin" | head -30 >&2
		exit 1
	}
	cp "$TMP/extracted/Image" "$OUTPUT"
else
	echo "-- input is a raw image"
	cp "$TMP/kernel.bin" "$OUTPUT"
fi

SIZE="$(stat -c %s "$OUTPUT")"
echo "== kernel Image =="
ls -l "$OUTPUT"
sha256sum "$OUTPUT"

# Sanity check: an arm64 Linux Image for this device is ~35-45 MB.
# `file`/magiskboot refuse to identify a bare arm64 Image reliably, so check the
# size band plus the arm64 boot header magic at offset 0x38: the u32 0x644d5241,
# i.e. the four bytes 41 52 4d 64 = "ARMd" ("ARM\x64").
if [ "$SIZE" -lt 20000000 ]; then
	echo "ERROR: $OUTPUT is only $SIZE bytes - that does not look like a kernel Image" >&2
	exit 1
fi
MAGIC="$(dd if="$OUTPUT" bs=1 skip=56 count=4 status=none)"
if [ "$MAGIC" != $'ARM\x64' ]; then
	echo "ERROR: arm64 boot header magic not found at offset 0x38" >&2
	echo "       expected 'ARM\\x64', found '$(printf '%s' "$MAGIC" | od -c | head -1)'" >&2
	exit 1
fi
echo "-- arm64 magic OK at offset 0x38"

echo "== done =="
