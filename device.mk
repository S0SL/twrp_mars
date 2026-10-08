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
#           OrangeFox/device/vayu (fox_14.1).  All of these are built from
#           source inside the fox_14.1 manifest, so no prebuilt blobs are
#           needed for them.
# ---------------------------------------------------------------------------
TARGET_RECOVERY_DEVICE_MODULES += \
    libdisplayconfig.qti \
    libion \
    vendor.display.config@1.0 \
    vendor.display.config@2.0

RECOVERY_LIBRARY_SOURCE_FILES += \
    $(TARGET_OUT_SHARED_LIBRARIES)/libion.so \
    $(TARGET_OUT_SYSTEM_EXT_SHARED_LIBRARIES)/libdisplayconfig.qti.so \
    $(TARGET_OUT_SYSTEM_EXT_SHARED_LIBRARIES)/vendor.display.config@1.0.so \
    $(TARGET_OUT_SYSTEM_EXT_SHARED_LIBRARIES)/vendor.display.config@2.0.so

# ---------------------------------------------------------------------------
# Kernel modules loaded at recovery runtime
#
# The kernel is prebuilt (TARGET_PREBUILT_KERNEL), so no .ko is compiled here.
# TWRP therefore insmods the touch driver straight out of the *installed ROM's*
# /vendor/lib/modules.  Names taken from
#   OrangeFox_device_xiaomi_sm8350-common (kotah81, tiramisu).
#
# KNOWN LIMITATION: this only works when the ROM's modules were built against
# the same kernel (CONFIG_MODVERSIONS / vermagic).  See docs/KNOWN_ISSUES.md.
# ---------------------------------------------------------------------------
TW_LOAD_VENDOR_MODULES := "xiaomi_touch.ko fts_touch_spi.ko fts_touch_spi_k2.ko focaltech_touch.ko adsp_loader_dlkm.ko qti_battery_charger.ko"

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
OF_AB_DEVICE := 1

# OEM otacert for MIUI/Xiaomi OTA zips (provided by vendor/recovery).
PRODUCT_EXTRA_RECOVERY_KEYS += \
    vendor/recovery/security/miui
