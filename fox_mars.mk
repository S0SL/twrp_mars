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
OF_AB_DEVICE := 1
OF_USE_GREEN_LED := 0
OF_NO_TREBLE_COMPATIBILITY_CHECK := 1
OF_NO_MIUI_PATCH_WARNING := 1
OF_DONT_PATCH_ENCRYPTED_DEVICE := 1

# Let OrangeFox ignore logical (super) partition mount hiccups: on A/B
# sm8350 devices with a freshly wiped super, some logical partitions are
# legitimately absent.
OF_IGNORE_LOGICAL_MOUNT_ERRORS := 1

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
OF_SCREEN_H := 3200
OF_STATUS_H := 90
OF_STATUS_INDENT_LEFT := 48
OF_STATUS_INDENT_RIGHT := 48
OF_HIDE_NOTCH := 1
OF_CLOCK_POS := 1

# number of list options before the scrollbar appears
OF_OPTIONS_LIST_NUM := 9

# ---------------------------------------------------------------------------
# Ramdisk compression
#   fox_14.1 ramdisks are large; lzma keeps the recovery ramdisk inside the
#   192 MiB boot partition.  (Same rationale as OrangeFox/device/vayu.)
# ---------------------------------------------------------------------------
OF_USE_LZMA_COMPRESSION := 1

# use dmctl when formatting /data
OF_USE_DMCTL := 1

# Do not keep a rolling log history unless we are cutting a Stable build.
ifeq ($(FOX_BUILD_TYPE),Stable)
OF_DONT_KEEP_LOG_HISTORY := 1
endif

# ---------------------------------------------------------------------------
# Phase 1: no haptics (see BoardConfig.mk).
# ---------------------------------------------------------------------------
OF_NO_HAPTICS := 1
