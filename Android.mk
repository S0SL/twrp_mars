#
# Copyright (C) 2020-2025 The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# Hardware-specific build definitions for the Xiaomi Mi 11 Pro (mars).
#
# This tree is self-contained, so there are no sub-makefiles to pull in.
# NOTE: `all-subdir-makefiles` is deliberately avoided -- the repository root
# also contains scripts/ and docs/, which must not be parsed by the build.
#

LOCAL_PATH := $(call my-dir)

ifeq ($(TARGET_DEVICE),mars)
# nothing to build from source in this directory yet
endif
