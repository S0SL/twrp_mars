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
# UFFD GC (dalvik runtime)
#
#   The prebuilt kernel used here is 5.4.302-qgki-g797c093f5b52.  AOSP only
#   knows how to derive the UFFD-GC default for a handful of GKI version
#   strings; for anything it cannot classify, `post_process_props` aborts the
#   build while generating build.prop with:
#
#       Unable to determine UFFD GC flag for kernel version "5.4.302-qgki-..."
#       You can fix this by explicitly setting PRODUCT_ENABLE_UFFD_GC to
#       "true" or "false" based on the kernel version.
#
#   (build/make/core/Makefile:5440-5466, art_config.mk:12-21).  That failure
#   lands at ~98% of the build, after ~15 minutes of compiling, and it is the
#   only thing left between the tree and a boot image.
#
#   UFFD GC is a runtime *dalvik* GC optimisation; it has no meaning for a
#   recovery ramdisk, so "false" is the right answer here.  A future kernel can
#   override it without touching this file:
#       mka OVERRIDE_ENABLE_UFFD_GC=true bootimage
# ---------------------------------------------------------------------------
PRODUCT_ENABLE_UFFD_GC := false

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
# v2: the device's own vendor_boot ramdisk also carries modules built for the
# stock kernel; let TWRP scan /lib/modules as a second source before /vendor.
TW_LOAD_VENDOR_BOOT_MODULES := true

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
# Crypto / FBE -- PHASE 2 (v4): ENABLED
#
# Same option set as OrangeFox/device/vayu (fox_14.1), which is the reference
# for this recovery generation, and not the older TeamWin A11 recipe:
#
#   * in fox_14.1 TW_INCLUDE_CRYPTO := true is enough for the *whole* FBE +
#     metadata-decrypt path, because bootable/recovery/Android.mk:348-375 then
#     sets TW_INCLUDE_CRYPTO_FBE := true itself, adds -DTW_INCLUDE_FBE and
#     -DTW_INCLUDE_FBE_METADATA_DECRYPT, and links the keystore2 stack
#     (keystore2, libkeymint_support, libkm_compat*, gatekeeper AIDL, ...).
#     The three switches are still written out explicitly so the intent is
#     visible in the tree.
#   * libkeymaster4 / libpuresoftkeymasterdevice (the old A11 list) are NOT
#     needed here and are deliberately not added: fox_14.1's
#     bootable/recovery/prebuilt/Android.mk already copies libkeymaster4support,
#     libkeymaster4_1support, libpuresoftkeymasterdevice, libsoftkeymaster,
#     android.hardware.keymaster@4.x.so, android.hardware.gatekeeper@1.0.so,
#     libion and libxml2 into the recovery ramdisk when crypto is on.
#   * TW_USE_FSCRYPT_POLICY := 2 -> USE_FSCRYPT_POLICY_V2, which is what mars'
#     /data line asks for (fileencryption=...:v2+inlinecrypt_optimized+wrappedkey_v0).
#     (Anything but "1" selects V2 - it is set explicitly to document that.)
#
# PLATFORM_SECURITY_PATCH / PLATFORM_VERSION: the TEE's keymaster refuses to
# unwrap keys for a client that claims to be *older* than the key (rollback
# protection).  Recovery therefore claims a far-future SPL, exactly like
# OrangeFox/device/vayu (2127-12-31) and the kotah sm8350 tree (2099-12-31).
# This build system rejects a direct PLATFORM_SECURITY_PATCH assignment in
# build/make/core/version_util.mk:53 *if it is set before that file is parsed*;
# device.mk is parsed afterwards, which is why the override works here (same
# place vayu puts it).
#
# The QCOM TEE stack itself cannot be built from source and is checked in as
# vendor blobs under recovery/root/ -- see docs/V4-REPORT.md for the exact list
# and their provenance (LineageOS 23.2 sm8350-common proprietary files).
# ---------------------------------------------------------------------------
TW_USE_FSCRYPT_POLICY := 2

TW_INCLUDE_CRYPTO := true
TW_INCLUDE_CRYPTO_FBE := true
TW_INCLUDE_FBE_METADATA_DECRYPT := true

PRODUCT_PACKAGES += \
    qcom_decrypt \
    qcom_decrypt_fbe

# platform / security patch (see the note above)
PLATFORM_VERSION := 99.87.36
PLATFORM_VERSION_LAST_STABLE := $(PLATFORM_VERSION)

PLATFORM_SECURITY_PATCH := 2099-12-31
VENDOR_SECURITY_PATCH := $(PLATFORM_SECURITY_PATCH)

# Safety net kept from phase 1: do not rewrite the fstab / boot image of an
# already-encrypted device (OrangeFox twrp-functions.cpp:3283,3939,4063).
# It does not affect /data decryption itself.
OF_DONT_PATCH_ENCRYPTED_DEVICE := 1

# ---------------------------------------------------------------------------
# A/B device
# ---------------------------------------------------------------------------
# Not declared for the first validation build -- see the long note in
# fox_mars.mk: `OF_AB_DEVICE` is a hard error now, and `FOX_AB_DEVICE` makes
# orangefox.mk:170 assign to the KATI_READONLY variable AB_OTA_UPDATER, which
# stops kati.  mars still gets its A/B *mounting* behaviour from the `slotselect`
# flags in recovery/root/system/etc/recovery.fstab; only the OrangeFox UI's A/B
# awareness (and bootctl) is off.

# OEM otacert for MIUI/Xiaomi OTA zips (provided by vendor/recovery).
# ---------------------------------------------------------------------------
# V4.1: /etc/task_profiles.json must exist in the recovery ramdisk
#
# logd aborts on start (SIGABRT) because
#     system/logging/logd/main.cpp:77  PLOG(FATAL) << "failed to set background
#     scheduling policy";
# follows set_sched_policy(0, SP_BACKGROUND) failing: libprocessgroup cannot
# find the SCHED_SP_BACKGROUND profile because /etc/task_profiles.json is not in
# the recovery ramdisk.  AOSP ships that file as the module `task_profiles.json`,
# while TWRP's bootable/recovery/Android.mk:584 asks for a module named
# `task_recovery_profiles.json` that does not exist in this tree -- so nothing
# ever put it into the *recovery* ramdisk (out/.../recovery/root/system/etc has
# cgroups.json but no task_profiles.json).  Result: logd restart-loops every 5 s
# and every other service's liblog output is silently dropped, which is why the
# keystore2/keymaster abort reasons were invisible.  Copy it explicitly.
PRODUCT_COPY_FILES += \
    system/core/libprocessgroup/profiles/task_profiles.json:$(TARGET_COPY_OUT_RECOVERY)/root/system/etc/task_profiles.json

PRODUCT_EXTRA_RECOVERY_KEYS += \
    vendor/recovery/security/miui
