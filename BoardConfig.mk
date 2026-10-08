#
# Copyright (C) 2021-2026 The OrangeFox Recovery Project
# Copyright (C) 2020-2025 The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# Xiaomi Mi 11 Pro (mars) -- Qualcomm sm8350 / lahaina
# OrangeFox / TWRP device tree.  The recovery is shipped *inside boot.img*.
#
# mars is an A/B device with NO dedicated recovery partition, therefore
# BOARD_USES_RECOVERY_AS_BOOT is mandatory.  With it enabled the AOSP/TWRP
# build system makes `recoveryimage` emit out/target/product/mars/boot.img
# (build/make/core/Makefile, "Target boot image from recovery").
#
# Sources for each block are annotated inline; see docs/PROVENANCE.md for the
# full mapping and docs/KNOWN_ISSUES.md for everything that is still unverified.
#

DEVICE_PATH := device/xiaomi/mars

# ---------------------------------------------------------------------------
# Architecture
#   source: LineageOS android_device_xiaomi_sm8350-common (lineage-23.2)
# ---------------------------------------------------------------------------
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-2a
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_ABI2 :=
TARGET_CPU_VARIANT := generic
TARGET_CPU_VARIANT_RUNTIME := kryo385

TARGET_2ND_ARCH := arm
TARGET_2ND_ARCH_VARIANT := armv8-a
TARGET_2ND_CPU_ABI := armeabi-v7a
TARGET_2ND_CPU_ABI2 := armeabi
TARGET_2ND_CPU_VARIANT := generic
TARGET_2ND_CPU_VARIANT_RUNTIME := kryo385

TARGET_SUPPORTS_64_BIT_APPS := true
TARGET_IS_64_BIT := true
TARGET_USES_64_BIT_BINDER := true

# ---------------------------------------------------------------------------
# Platform / bootloader
# ---------------------------------------------------------------------------
TARGET_BOARD_PLATFORM := lahaina
TARGET_BOARD_PLATFORM_GPU := qcom-adreno660
QCOM_BOARD_PLATFORMS += lahaina
TARGET_BOOTLOADER_BOARD_NAME := mars
TARGET_NO_BOOTLOADER := true

# TWRP zip assert
TARGET_OTA_ASSERT_DEVICE := mars

# ---------------------------------------------------------------------------
# A/B + recovery-as-boot
#   mars has no recovery partition.  Vendor_boot is left completely untouched
#   by this project; we only ever replace `boot`.
# ---------------------------------------------------------------------------
BOARD_USES_RECOVERY_AS_BOOT := true

# ---------------------------------------------------------------------------
# Kernel -- PREBUILT
#   Built by S0SL/android_kernel_xiaomi_sm8350 and dropped in by CI at
#   prebuilt/Image (see scripts/fetch-kernel.sh).  Image is .gitignore'd.
#   source of the idea: OrangeFox/device/vayu (fox_14.1), which also uses
#   TARGET_PREBUILT_KERNEL for a header-v2 device.
# ---------------------------------------------------------------------------
TARGET_PREBUILT_KERNEL := $(DEVICE_PATH)/prebuilt/Image
BOARD_KERNEL_IMAGE_NAME := Image
BOARD_KERNEL_BASE := 0x00000000
BOARD_KERNEL_PAGESIZE := 4096
BOARD_BOOT_HEADER_VERSION := 3
BOARD_MKBOOTIMG_ARGS += --header_version $(BOARD_BOOT_HEADER_VERSION)

# BOARD_INCLUDE_DTB_IN_BOOTIMG is deliberately NOT set.
#
# `boot` header v3 has no dtb field at all -- the dtb/dtb.img moved to
# vendor_boot.  Verified empirically: the official LineageOS 23.2
# boot.img for mars unpacks (magiskboot) to exactly kernel + ramdisk.cpio,
# with HEADER_VER [3] and no dtb section.  Since this project only replaces
# `boot`, the dtb keeps coming from the untouched vendor_boot partition.
#
# Setting BOARD_INCLUDE_DTB_IN_BOOTIMG would additionally make
# recoveryimage-deps depend on $(INSTALLED_DTBIMAGE_TARGET) (dtb.img) and
# fail unless a real BOARD_PREBUILT_DTBIMAGE_DIR is supplied -- avoid it.

BOARD_KERNEL_CMDLINE := androidboot.console=ttyMSM0
BOARD_KERNEL_CMDLINE += androidboot.hardware=qcom
BOARD_KERNEL_CMDLINE += androidboot.memcg=1
BOARD_KERNEL_CMDLINE += androidboot.usbcontroller=a600000.dwc3
BOARD_KERNEL_CMDLINE += cgroup.memory=nokmem,nosocket
BOARD_KERNEL_CMDLINE += console=ttyMSM0,115200n8
BOARD_KERNEL_CMDLINE += loop.max_part=7
BOARD_KERNEL_CMDLINE += msm_rtb.filter=0x237
BOARD_KERNEL_CMDLINE += service_locator.enable=1
BOARD_KERNEL_CMDLINE += swiotlb=0
BOARD_KERNEL_CMDLINE += pcie_ports=compat
BOARD_KERNEL_CMDLINE += iptable_raw.raw_before_defrag=1
BOARD_KERNEL_CMDLINE += ip6table_raw.raw_before_defrag=1
# TWRP additions (android_device_xiaomi_sm8350-common, android-11):
# vfb console + permissive SELinux, both wanted by recovery.
BOARD_KERNEL_CMDLINE += video=vfb:640x400,bpp=32,memsize=3072000
BOARD_KERNEL_CMDLINE += androidboot.selinux=permissive

# ---------------------------------------------------------------------------
# Partitions -- sizes are the real mars GPT sizes
#   source: LineageOS android_device_xiaomi_sm8350-common (lineage-23.2)
#           + device/xiaomi/mars BoardConfig.mk (BOARD_DTBOIMG_PARTITION_SIZE)
# ---------------------------------------------------------------------------
BOARD_BOOTIMAGE_PARTITION_SIZE := 201326592
BOARD_DTBOIMG_PARTITION_SIZE := 25165824
BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE := 100663296

BOARD_SUPER_PARTITION_SIZE := 9126805504
BOARD_SUPER_PARTITION_GROUPS := qti_dynamic_partitions
BOARD_QTI_DYNAMIC_PARTITIONS_PARTITION_LIST := odm product system system_ext vendor vendor_dlkm
BOARD_QTI_DYNAMIC_PARTITIONS_SIZE := 9122611200

BOARD_USES_METADATA_PARTITION := true
BOARD_FLASH_BLOCK_SIZE := 131072
BOARD_HAS_LARGE_FILESYSTEM := true
BOARD_ROOT_EXTRA_FOLDERS := bluetooth dsp firmware persist
BOARD_SUPPRESS_SECURE_ERASE := true
BOARD_BUILD_SYSTEM_ROOT_IMAGE := false

# ---------------------------------------------------------------------------
# Filesystems
# ---------------------------------------------------------------------------
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true
TARGET_USES_MKE2FS := true

BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_ODMIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_VENDOR_DLKMIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_USERDATAIMAGE_FILE_SYSTEM_TYPE := f2fs

TARGET_COPY_OUT_SYSTEM := system
TARGET_COPY_OUT_SYSTEM_EXT := system_ext
TARGET_COPY_OUT_PRODUCT := product
TARGET_COPY_OUT_VENDOR := vendor
TARGET_COPY_OUT_ODM := odm
TARGET_COPY_OUT_VENDOR_DLKM := vendor_dlkm

# ---------------------------------------------------------------------------
# Recovery
#
# TARGET_RECOVERY_DEVICE_DIRS is intentionally left UNSET: the TWRP-patched
# build system (build/make/core/Makefile, "recovery_root_private") falls back
# to $(TARGET_DEVICE_DIR)/recovery/root, which is exactly where this tree keeps
# recovery.fstab, twrp.flags, ueventd.qcom.rc and init.recovery.qcom.rc.
#   (fork used by fox_14.1: github.com/nebrassy/android_build, android-14)
# ---------------------------------------------------------------------------
TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/recovery/root/system/etc/recovery.fstab
TARGET_RECOVERY_PIXEL_FORMAT := RGBX_8888
TARGET_RECOVERY_QCOM_RTC_FIX := true
RECOVERY_SDCARD_ON_DATA := true

# Mars has a notch/rounded corners; value taken from the LineageOS mars tree.
TARGET_RECOVERY_UI_MARGIN_HEIGHT := 165

# ---------------------------------------------------------------------------
# Crypto / FBE
#
# PHASE 1: /data decryption is explicitly out of scope, so TW_INCLUDE_CRYPTO
# stays off in device.mk.  The *fstab metadata* for FBE is nevertheless kept
# complete (see recovery/root/system/etc/recovery.fstab) because it is the
# starting point for phase 2.
#
# BOARD_USES_QCOM_FBE_DECRYPTION is harmless on its own (it only switches the
# qcom_decrypt helper on when TW_INCLUDE_CRYPTO is enabled).
# ---------------------------------------------------------------------------
BOARD_USES_QCOM_FBE_DECRYPTION := true

# ---------------------------------------------------------------------------
# Verified boot
#   source: LineageOS android_device_xiaomi_sm8350-common + OrangeFox vayu
#   Only the `boot` hash footer matters here (recovery-as-boot).
# ---------------------------------------------------------------------------
BOARD_AVB_ENABLE := true
BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 3
BOARD_AVB_BOOT_KEY_PATH := external/avb/test/data/testkey_rsa2048.pem
BOARD_AVB_BOOT_ALGORITHM := SHA256_RSA2048
BOARD_AVB_BOOT_ROLLBACK_INDEX := $(PLATFORM_SECURITY_PATCH_TIMESTAMP)
BOARD_AVB_BOOT_ROLLBACK_INDEX_LOCATION := 1

# ---------------------------------------------------------------------------
# TWRP / OrangeFox board configuration
#   source: OrangeFox_device_xiaomi_sm8350-common (kotah81, tiramisu)
#           + TeamWin android_device_xiaomi_sm8350-common (android-11)
#           + OrangeFox/device/vayu (fox_14.1)
# ---------------------------------------------------------------------------
TW_THEME := portrait_hdpi
TW_DEVICE_VERSION := mars-1
TW_EXTRA_LANGUAGES := true
TW_EXCLUDE_DEFAULT_USB_INIT := true
TW_INCLUDE_NTFS_3G := true
TW_USE_TOOLBOX := true
TW_INCLUDE_RESETPROP := true
TW_INCLUDE_REPACKTOOLS := true
TW_NO_SCREEN_BLANK := true
TW_EXCLUDE_APEX := true
TWRP_INCLUDE_LOGCAT := true
TARGET_USES_LOGD := true

# The mars touch panel needs the "hbtp_vm" node blacklisted, otherwise TWRP
# picks up a phantom input device.
TW_INPUT_BLACKLIST := "hbtp_vm"

# Display / backlight
TW_BRIGHTNESS_PATH := "/sys/class/backlight/panel0-backlight/brightness"
TW_MAX_BRIGHTNESS := 4095
TW_DEFAULT_BRIGHTNESS := 1640
TW_Y_OFFSET := 80
TW_H_OFFSET := -80
TW_FRAMERATE := 120

# PHASE 1: no vibration motor support.  The sm8350 AIDL vibrator HAL
# (vendor.qti.hardware.vibrator.service.xiaomi_sm8350) is not part of the
# recovery manifest used here, so we simply disable haptics instead of
# pulling in extra vendor blobs.
TW_NO_HAPTICS := true

# ---------------------------------------------------------------------------
# Build-system workarounds
#   source: OrangeFox_device_xiaomi_sm8350-common (kotah81, tiramisu)
#           + OrangeFox/device/vayu (fox_14.1)
# ---------------------------------------------------------------------------
BUILD_BROKEN_DUP_RULES := true
BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true
BUILD_BROKEN_MISSING_REQUIRED_MODULES := true
BUILD_BROKEN_USES_BUILD_COPY_HEADERS := true

# fastboot update <zip> metadata
TARGET_BOARD_INFO_FILE := $(DEVICE_PATH)/board-info.txt
