#
#	This file is part of the OrangeFox Recovery Project
#	Copyright (C) 2021-2026 The OrangeFox Recovery Project
#	SPDX-License-Identifier: GPL-3.0-or-later
#
#	OrangeFox environment setup for the Xiaomi Mi 11 Pro (mars).
#	Sourced by build/envsetup.sh, exactly like OrangeFox/device/vayu
#	(fox_14.1) does.
#

FDEVICE="mars"

fox_get_target_device() {
  if echo "$BASH_SOURCE" | grep -q "/$FDEVICE/"; then
      FOX_BUILD_DEVICE="$FDEVICE";
  elif set | grep BASH_ARGV | grep -w \"$FDEVICE\"; then
      FOX_BUILD_DEVICE="$FDEVICE";
  elif echo "${BASH_SOURCE[0]}" | grep -q "/$FDEVICE/"; then
      FOX_BUILD_DEVICE="$FDEVICE";
  elif echo "$0" | grep -q "$FDEVICE"; then
      FOX_BUILD_DEVICE="$FDEVICE";
  fi
}

if [ -z "$1" -a -z "$FOX_BUILD_DEVICE" ]; then
   fox_get_target_device
fi

if [ "$1" = "$FDEVICE" -o "$FOX_BUILD_DEVICE" = "$FDEVICE" ]; then
	export TW_DEFAULT_LANGUAGE="en"
	export LC_ALL="C"
	# The recovery manifest does not carry every AOSP module; this is required
	# by OrangeFox's own build wrapper (see orangefox_sync.sh).
	export ALLOW_MISSING_DEPENDENCIES=true

	# OrangeFox shell / tooling
	export FOX_USE_BASH_SHELL=1
	export FOX_ASH_IS_BASH=1
	export FOX_USE_TAR_BINARY=1
	export FOX_USE_XZ_UTILS=1
	export FOX_USE_LZ4_BINARY=1
	export FOX_USE_ZSTD_BINARY=1
	export FOX_USE_BUSYBOX_BINARY=1
	export FOX_USE_DATE_BINARY=1
	export FOX_DELETE_AROMAFM=1

	# A/B device, no recovery partition.
	# Must be FOX_AB_DEVICE: OF_AB_DEVICE is a hard error in orangefox.mk:597.
	export FOX_AB_DEVICE=1

	# mars has no alternate SKU codename
	export TARGET_DEVICE_ALT=""

	# OrangeFox logical partition paths
	export FOX_RECOVERY_SYSTEM_PARTITION="/dev/block/mapper/system"
	export FOX_RECOVERY_VENDOR_PARTITION="/dev/block/mapper/vendor"

	export FOX_SETTINGS_ROOT_DIRECTORY=/data/recovery
	export FOX_MISCELLANEOUS_ROOT_DIRECTORY=/sdcard

	# let's see what our build VARs are
	if [ -n "$FOX_BUILD_LOG_FILE" -a -f "$FOX_BUILD_LOG_FILE" ]; then
	   export | grep "FOX" >> $FOX_BUILD_LOG_FILE
	   export | grep "OF_" >> $FOX_BUILD_LOG_FILE
	   export | grep "TARGET_" >> $FOX_BUILD_LOG_FILE
	   export | grep "TW_" >> $FOX_BUILD_LOG_FILE
	fi
else
	if [ -z "$FOX_BUILD_DEVICE" -a -z "$BASH_SOURCE" ]; then
		echo "I: This script requires bash. Not processing the $FDEVICE $(basename $0)"
	fi
fi
#
