#
# Copyright (C) 2020-2025 The LineageOS Project
# Copyright (C) 2021-2026 The OrangeFox Recovery Project
# SPDX-License-Identifier: Apache-2.0
#
# Xiaomi Mi 11 Pro (mars) -- product configuration for OrangeFox / TWRP.
#
# This tree is SELF-CONTAINED: it does not inherit device/xiaomi/sm8350-common.
# Everything recovery needs from that common tree has been folded in here, so
# the CI only has to clone *this* repository.  See docs/PROVENANCE.md.
#

DEVICE_PATH := device/xiaomi/mars

# ---------------------------------------------------------------------------
# Dynamic partitions
# ---------------------------------------------------------------------------
PRODUCT_USE_DYNAMIC_PARTITIONS := true
PRODUCT_SHIPPING_API_LEVEL := 30

# ---------------------------------------------------------------------------
# Soong namespaces
#   libdisplayconfig.qti / vendor.display.config@* are built from
#   vendor/qcom/opensource/commonsys-intf/display.
# ---------------------------------------------------------------------------
PRODUCT_SOONG_NAMESPACES += \
    vendor/qcom/opensource/commonsys-intf/display

# ---------------------------------------------------------------------------
# Display libraries required by TWRP's minuitwrp / gralloc path.
#   source: OrangeFox_device_xiaomi_sm8350-common (kotah81) and
#           OrangeFox/device/vayu (fox_14.1).
#
# libion is AOSP (system/core/libion) and is always buildable.
# libdisplayconfig.qti / vendor.display.config@* are *CAF* projects living in
# vendor/qcom/opensource/commonsys-intf/display -- which the fox_14.1 manifest
# (nebrassy platform_manifest_twrp_aosp, branch twrp-14) does NOT contain.
# Verified: that manifest lists 1357 projects and none is under vendor/qcom.
#
# Copying a source file that is never built is a hard install error, so these
# are only referenced when the project is really present.  If it is absent the
# recovery has to rely on prebuilt blobs under recovery/root/vendor/lib64/,
# which is how OrangeFox/device/vayu ships them.
# See docs/KNOWN_ISSUES.md I16.
# ---------------------------------------------------------------------------
TARGET_RECOVERY_DEVICE_MODULES += \
    libdisplayconfig.qti \
    libion \
    vendor.display.config@1.0 \
    vendor.display.config@2.0

RECOVERY_LIBRARY_SOURCE_FILES += \
    $(TARGET_OUT_SHARED_LIBRARIES)/libion.so

ifneq ($(wildcard vendor/qcom/opensource/commonsys-intf/display),)
RECOVERY_LIBRARY_SOURCE_FILES += \
    $(TARGET_OUT_SYSTEM_EXT_SHARED_LIBRARIES)/libdisplayconfig.qti.so \
    $(TARGET_OUT_SYSTEM_EXT_SHARED_LIBRARIES)/vendor.display.config@1.0.so \
    $(TARGET_OUT_SYSTEM_EXT_SHARED_LIBRARIES)/vendor.display.config@2.0.so
else
$(warning device/xiaomi/mars: vendor/qcom/opensource/commonsys-intf/display is not in the manifest)
$(warning   -> libdisplayconfig.qti / vendor.display.config@* will NOT be built into recovery)
$(warning   -> If the display does not come up, extract them from a mars ROM into)
$(warning      recovery/root/vendor/lib64/ (see docs/KNOWN_ISSUES.md I16))
endif

# ---------------------------------------------------------------------------
# Kernel modules loaded at recovery runtime
#
# The kernel is prebuilt (TARGET_PREBUILT_KERNEL), so no .ko is compiled here.
# TWRP therefore insmods them straight out of the *installed ROM's*
# /vendor/lib/modules -- after mounting /vendor, and *before* gui_init()
# (twrp.cpp:539 `PartitionManager.Process_Fstab()` -> partitionmanager.cpp:500
# `KernelModuleLoader::Load_Vendor_Modules()`, vs twrp.cpp:549 `gui_init()`).
#
# This list is LineageOS' own mars recovery list
# (android_device_xiaomi_mars, BoardConfig.mk: `BOOT_KERNEL_MODULES`), with the
# file names verified against this kernel's Makefiles:
#   fts_touch_spi.ko              drivers/input/touchscreen/fts_spi/Makefile:2
#                                 (CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI, =m in star_QGKI)
#   xiaomi_touch.ko               drivers/input/touchscreen/xiaomi/Makefile:2
#                                 (CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE, =m in star_QGKI)
#   hwid.ko                       drivers/misc/Makefile:68            (CONFIG_MI_HARDWARE_ID=m)
#   qti_battery_charger_main.ko   drivers/power/supply/Makefile:95    (CONFIG_QTI_BATTERY_CHARGER=m)
#   msm_drm.ko                    techpack/display/msm/Makefile:165   (CONFIG_DISPLAY_BUILD=m)
#   adsp_loader_dlkm / apr_dlkm / q6_notifier_dlkm / q6_pdr_dlkm /
#   snd_event_dlkm                audio DLKMs used by the recovery ADSP path
#   mmhardware_sysfs_dlkm.ko      Mi hardware sysfs nodes
#
# NOTE `qti_battery_charger.ko` was in the previous version of this list and
# does not exist in this kernel -- the module is `qti_battery_charger_main.ko`.
# TWRP only insmods names it actually finds, so a wrong name is harmless, but it
# means "the battery/charger module is not loaded" while looking like it is.
#
# `msm_drm.ko` matters more than it looks: display is a *module* for lahaina
# (CONFIG_DISPLAY_BUILD=m), so this is the only path by which the panel comes up
# in this build.  If it does not load, the recovery has no display at all -- see
# docs/RAMDISK-MODULES.md for shipping our own copy in the ramdisk instead.
#
# KNOWN LIMITATION: loading the ROM's modules only works when they were built
# against the same kernel (CONFIG_MODVERSIONS symbol CRCs / vermagic).  See
# docs/KNOWN_ISSUES.md I7 and docs/RAMDISK-MODULES.md.
# ---------------------------------------------------------------------------
TW_LOAD_VENDOR_MODULES := "xiaomi_touch.ko fts_touch_spi.ko msm_drm.ko hwid.ko mmhardware_sysfs_dlkm.ko qti_battery_charger_main.ko adsp_loader_dlkm.ko apr_dlkm.ko q6_notifier_dlkm.ko q6_pdr_dlkm.ko snd_event_dlkm.ko"

# ---------------------------------------------------------------------------
# Touch panel firmware
#
# mars uses the same FingerTipS (FTS) touch family as venus/star.  The .ftb
# blobs come from the OrangeFox venus tree (kotah81) and are placed:
#   * physically inside the recovery ramdisk at /lib/firmware/ via this tree's
#     recovery/root/... directory (guaranteed to land in the ramdisk), and
#   * into the vendor image at /vendor/firmware/ in case it is ever built.
#
# UNCERTAIN: the .ftb blobs were taken from venus, not from a mars ROM dump.
# If touch does not initialise, dump /vendor/firmware from a mars device and
# replace them (see docs/KNOWN_ISSUES.md).
# ---------------------------------------------------------------------------
PRODUCT_COPY_FILES += \
    $(DEVICE_PATH)/firmware/st_fts_k2.ftb:$(TARGET_COPY_OUT_VENDOR)/firmware/st_fts_k2.ftb \
    $(DEVICE_PATH)/firmware/st_fts_k2_htp.ftb:$(TARGET_COPY_OUT_VENDOR)/firmware/st_fts_k2_htp.ftb

# ---------------------------------------------------------------------------
# Crypto / FBE -- PHASE 1: DISABLED
#
# The goal of phase 1 is only: boot the UI, flash zips, back up/restore
# partitions, MTP/ADB.  Decrypting /data is phase 2 and needs the qcom
# keymaster / qseecomd / rpmb blobs checked into recovery/root/vendor/lib64/.
#
# Flip the block below on for phase 2 (see docs/PHASE2-CRYPTO.md):
#
#TW_INCLUDE_CRYPTO := true
#TW_INCLUDE_CRYPTO_FBE := true
#TW_INCLUDE_FBE_METADATA_DECRYPT := true
#PRODUCT_PACKAGES += \
#    qcom_decrypt \
#    qcom_decrypt_fbe
#TARGET_RECOVERY_DEVICE_MODULES += \
#    libkeymaster4 \
#    libpuresoftkeymasterdevice
#RECOVERY_LIBRARY_SOURCE_FILES += \
#    $(TARGET_OUT_SHARED_LIBRARIES)/libkeymaster4.so \
#    $(TARGET_OUT_SHARED_LIBRARIES)/libpuresoftkeymasterdevice.so
# ---------------------------------------------------------------------------
TW_INCLUDE_CRYPTO := false

# Never touch an encrypted /data in phase 1.
OF_DONT_PATCH_ENCRYPTED_DEVICE := 1

# ---------------------------------------------------------------------------
# A/B device
# ---------------------------------------------------------------------------
# FOX_AB_DEVICE (not OF_AB_DEVICE): the OF_ spelling is a hard error in
# OrangeFox's orangefox.mk:597.  vendor/recovery/OrangeFox_vendor.sh accepts
# either spelling, so this stays compatible.
FOX_AB_DEVICE := 1

# OEM otacert for MIUI/Xiaomi OTA zips (provided by vendor/recovery).
PRODUCT_EXTRA_RECOVERY_KEYS += \
    vendor/recovery/security/miui
