#
#	This file is part of the OrangeFox Recovery Project
#	Copyright (C) 2021-2026 The OrangeFox Recovery Project
#	SPDX-License-Identifier: GPL-3.0-or-later
#
#	OrangeFox recovery options for the Xiaomi Mi 11 Pro (mars).
#
#	Inherited from twrp_mars.mk via `inherit-product-if-exists`.
#	Reference for the option set: OrangeFox/device/vayu (fox_14.1).
#

# ---------------------------------------------------------------------------
# Device flags
# ---------------------------------------------------------------------------
# A/B flag: deliberately NOT set for the first validation build.
#
# The old spelling `OF_AB_DEVICE := 1` is now a hard error
# (orangefox.mk:597), and the new spelling `FOX_AB_DEVICE := 1` does not work
# either, because orangefox.mk:167-174 then does
#     ifneq ($(AB_OTA_UPDATER),true)
#         AB_OTA_UPDATER := true      <-- line 170
# and this build system declares AB_OTA_UPDATER with `.KATI_READONLY`
# (build/make/core/board_config.mk:923-924), so kati stops with
#     orangefox.mk:170: error: cannot assign to readonly variable: AB_OTA_UPDATER
#
# Setting AB_OTA_UPDATER := true early (in BoardConfig.mk) is what would make
# that assignment a no-op and restore the A/B flag -- see KNOWN_ISSUES I15 for
# why the tree deliberately does not declare the device A/B to the whole build
# system.  Until that is decided, leave the flag off: the image still boots, it
# just is not A/B-aware (no `-DFOX_AB_DEVICE=1`, no bootctl in the recovery).
OF_USE_GREEN_LED := 0
OF_NO_TREBLE_COMPATIBILITY_CHECK := 1
OF_NO_MIUI_PATCH_WARNING := 1
OF_DONT_PATCH_ENCRYPTED_DEVICE := 1

# NOTE (checked against OrangeFox/bootable/Recovery fox_14.1 +
# OrangeFox/vendor/recovery main): `OF_IGNORE_LOGICAL_MOUNT_ERRORS` is *not* a
# variable OrangeFox reads.  It came from the kotah81 venus reference, whose
# vendorsetup.sh exported it, but nothing consumes it in fox_14.1.
# OrangeFox already tolerates absent logical partitions on its own.
# (The crypto-related `OF_FBE_METADATA_MOUNT_IGNORE` does exist and belongs to
#  phase 2 -- see docs/PHASE2-CRYPTO.md.)

# Use magiskboot for all boot image patching (A/B + header v3 safety).
OF_USE_MAGISKBOOT_FOR_ALL_PATCHES := 1

# Unmount /sdcard before f2fs repair/format (mars has no real sdcard, but
# /sdcard is a bind mount on /data/media).
OF_UNBIND_SDCARD_F2FS := 1

# Keep dm-verity / AVB behaviour conservative during phase 1: do not
# auto-patch AVB on flashed images.
OF_PATCH_AVB20 := 0

# OTA handling
OF_KEEP_DM_VERITY := 1
OF_SUPPORT_ALL_BLOCK_OTA_UPDATES := 1
OF_FIX_OTA_UPDATE_MANUAL_FLASH_ERROR := 1
OF_DISABLE_MIUI_OTA_BY_DEFAULT := 1

# Build every partition tool (helps bring-up debugging).
OF_ENABLE_ALL_PARTITION_TOOLS := 1

# frp addon
OF_ENABLE_FRP_ADDON := 1

# ---------------------------------------------------------------------------
# Screen geometry
#   mars: 1440x3200 panel, rendered at 1440 wide with a ~165px status bar
#   (TARGET_RECOVERY_UI_MARGIN_HEIGHT in BoardConfig.mk comes from LineageOS).
# ---------------------------------------------------------------------------
# v4 -- calibrated against mars' own display overlay
# (android_device_xiaomi_mars/overlay/Frameworks/res/values/{config,dimens}.xml):
#   config_mainBuiltInDisplayCutout = "M 0,0 H 208 V 137 H 0 V 0 Z @left"
#   status_bar_height_portrait      = 137px
# i.e. the punch hole is a 208x137 px box in the TOP-LEFT corner and the ROM
# reserves a 137 px status bar for it.
#
#   OF_SCREEN_H       2400  theme coordinate space.  OrangeFox's theme is
#                           1080-wide and scaled by gr_fb_width()/1080 on x and
#                           (gr_fb_height()+TW_H_OFFSET)/OF_SCREEN_H on y
#                           (gui/pages.cpp:940-990).  mars is a 20:9 device, so
#                           OF_SCREEN_H must be 2400 (= 1080 * 20/9) to keep
#                           those two factors equal; with 3200 the UI was
#                           stretched ~37% horizontally vs vertically.  Every
#                           sm8350 OrangeFox tree uses 2400 (kotah/venus:
#                           OF_SCREEN_H=2400 with the same 1440x3200 panel class,
#                           vayu: OF_SCREEN_H=2400).
#   OF_STATUS_H       137   matches the ROM's own status_bar_height_portrait, so
#                           the Fox status bar band covers exactly the cutout
#                           band; the theme also derives its content inset from
#                           it (vars.xml: cutout_w = status_h - 72).
#   OF_STATUS_INDENT_LEFT 216  the cutout reaches x=208, so left-aligned status
#                           text (which is where the clock sits by default --
#                           theme default center_clock=2, i.e. LEFT) starts
#                           clear of the hole instead of underneath it.
#   OF_STATUS_INDENT_RIGHT 48  hole is on the left only.
OF_SCREEN_H := 2400
OF_STATUS_H := 137
OF_STATUS_INDENT_LEFT := 216
OF_STATUS_INDENT_RIGHT := 48
OF_HIDE_NOTCH := 1
OF_CLOCK_POS := 1

# number of list options before the scrollbar appears
OF_OPTIONS_LIST_NUM := 9

# ---------------------------------------------------------------------------
# Ramdisk compression: GZIP (the build system default).  DO NOT switch to LZMA.
#
# v1 and v2 both shipped an LZMA-alone ramdisk (magic `5d 00 00 80`) and both
# came up as a black screen with no adb -- on two completely different kernels
# (BakaSU `-g797c093f5b52` and LineageOS stock `-g7ede20c8692e`), which is what
# proved the ramdisk, not the kernel, was at fault.
#
# The chain that produced it:
#   bootable/recovery/orangefox.mk:371
#       ifeq ($(OF_USE_LZMA_COMPRESSION),1)
#           BOARD_RAMDISK_USE_LZMA := true
#   build/make/core/Makefile:1210
#       else ifeq ($(BOARD_RAMDISK_USE_LZMA),true)
#           COMPRESSION_COMMAND := $(LZMA) -f -c     # `lzma` alone, not xz
#
# The kernel unpacks an initramfs only with a decompressor it was built with,
# and mars' kernel (LineageOS 23.2 stock) was built with -- read straight off
# the running device, `zcat /proc/config.gz | grep CONFIG_RD_`:
#       CONFIG_RD_GZIP=y
#       # CONFIG_RD_LZMA is not set     <-- the root cause of v1 and v2
#       # CONFIG_RD_XZ is not set
#       # CONFIG_RD_LZO is not set
#       # CONFIG_RD_BZIP2 is not set
#       CONFIG_RD_LZ4=y
# An archive the kernel cannot decompress makes `unpack_to_rootfs()` fail, so no
# /init is ever executed: black screen, adbd never starts.  The stock mars
# boot.img agrees -- its ramdisk is gzip (magic `1f 8b 08`).
#
# Size is a non-issue: ~19 MB LZMA vs ~25 MB gzip for the recovery ramdisk
# inside a 192 MiB (201326592 B) boot partition.
#
# `BOARD_RAMDISK_USE_LZMA := false` is explicit so that re-adding the OrangeFox
# switch (or a future default change) cannot silently bring LZMA back; the
# unset else-branch in core/Makefile then selects gzip.
# scripts/check-tree.sh fails in ~10 s if any non-gzip ramdisk compression is
# re-enabled.
# ---------------------------------------------------------------------------
BOARD_RAMDISK_USE_LZMA := false

# use dmctl when formatting /data
OF_USE_DMCTL := 1

# Do not keep a rolling log history unless we are cutting a Stable build.
ifeq ($(FOX_BUILD_TYPE),Stable)
OF_DONT_KEEP_LOG_HISTORY := 1
endif

# ---------------------------------------------------------------------------
# Phase 1: no haptics.
#
# The switch that actually exists is `TW_NO_HAPTICS` (read in
# bootable/recovery/Android.mk as `ifeq ($(TW_NO_HAPTICS), true)` and compiled
# into data.cpp), and it is set in BoardConfig.mk.
# `OF_NO_HAPTICS` does not exist upstream -- deliberately not used here.
# ---------------------------------------------------------------------------
