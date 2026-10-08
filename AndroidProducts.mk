#
# Copyright 2018-2026 The Android Open Source Project
# Copyright (C) 2021-2026 The OrangeFox Recovery Project
# SPDX-License-Identifier: Apache-2.0
#
# Product makefiles / lunch choices for the Xiaomi Mi 11 Pro (mars).
#
# ---------------------------------------------------------------------------
# IMPORTANT: the lunch combo MUST have three parts.
#
# The build/make fork that fox_14.1 uses (nebrassy/android_build, android-14)
# enforces this at the top of lunch():
#
#     # This must be <product>-<release>-<variant>
#     IFS="-" read -r product release variant <<< "$selection"
#     if [[ -z "$product" ]] || [[ -z "$release" ]] || [[ -z "$variant" ]]
#     then
#         echo "Invalid lunch combo: $selection"
#         echo "Valid combos must be of the form <product>-<release>-<variant>"
#         return 1
#     fi
#
# So the historical 2-part form `twrp_mars-eng` splits into
# product=twrp_mars, release=eng, variant=<empty> and is ALWAYS rejected.
# This is why OrangeFox's own fox_16.0 documentation says
#     lunch twrp_mondrian-bp2a-eng
# rather than `twrp_mondrian-eng`, even though `OrangeFox/device/vayu`
# (fox_14.1) still advertises the 2-part `twrp_vayu-eng` -- that entry is stale
# and does not work on this build system.
#
# `bp2a` is the Android 14 QPR3 release token used by this manifest (the sync
# script pins android14-qpr3-release for the projects it has to re-clone).
# If a future manifest renames it, `.github/workflows/build-recovery.yml`
# probes a short candidate list before giving up.
# ---------------------------------------------------------------------------

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/twrp_mars.mk

COMMON_LUNCH_CHOICES := \
    twrp_mars-bp2a-eng \
    twrp_mars-bp2a-userdebug
