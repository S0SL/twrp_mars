#
# Copyright 2018-2026 The Android Open Source Project
# Copyright (C) 2021-2026 The OrangeFox Recovery Project
# SPDX-License-Identifier: Apache-2.0
#
# Product makefiles / lunch choices for the Xiaomi Mi 11 Pro (mars).
#
# `twrp_mars` is the PRODUCT_NAME used by fox_14.1 device trees
# (see OrangeFox/device/vayu: PRODUCT_NAME := twrp_vayu,
#  COMMON_LUNCH_CHOICES := twrp_vayu-eng).
#

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/twrp_mars.mk

COMMON_LUNCH_CHOICES := \
    twrp_mars-eng \
    twrp_mars-userdebug
