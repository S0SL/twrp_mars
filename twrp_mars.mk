#
# Copyright (C) 2018-2026 The OrangeFox Recovery Project
# Copyright (C) 2020-2025 The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# OrangeFox / TWRP product definition for the Xiaomi Mi 11 Pro (mars).
#
# Lunch target: twrp_mars-eng
#   (fox_14.1 keeps the historical `twrp_<device>` PRODUCT_NAME even though the
#    UI is OrangeFox -- see OrangeFox/device/vayu, branch fox_14.1, whose
#    AndroidProducts.mk declares exactly `COMMON_LUNCH_CHOICES := twrp_vayu-eng`.)
#

# Release name
PRODUCT_RELEASE_NAME := mars
DEVICE_PATH := device/xiaomi/$(PRODUCT_RELEASE_NAME)

$(call inherit-product, $(SRC_TARGET_DIR)/product/base.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, vendor/twrp/config/common.mk)
$(call inherit-product, $(DEVICE_PATH)/device.mk)

# Inherit any OrangeFox-specific settings (OF_* switches)
$(call inherit-product-if-exists, $(DEVICE_PATH)/fox_mars.mk)

## Device identifier. This must come after all inclusions
PRODUCT_DEVICE := $(PRODUCT_RELEASE_NAME)
PRODUCT_NAME := twrp_$(PRODUCT_RELEASE_NAME)
PRODUCT_BRAND := Xiaomi
PRODUCT_MODEL := M2102K1AC
PRODUCT_MANUFACTURER := Xiaomi

PRODUCT_GMS_CLIENTID_BASE := android-xiaomi
