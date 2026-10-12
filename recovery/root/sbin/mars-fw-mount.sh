#!/system/bin/sh
# v4.8: mount the modem/firmware partition where both consumers expect it.
#   * the kernel/ueventd ask for firmware under /vendor/firmware_mnt/image
#     ("ueventd : firmware: attempted /vendor/firmware_mnt/image/ipa_fws.mdt")
#   * the vendor decryption/PMIC logic looks at /firmware
# This shell is Android mksh: properties MUST be read with getprop, never as a
# bash-style dotted expansion (the v4.7 script died there: "bad substitution").
# The old rc mount never worked either: the modem node is modem_a/modem_b on
# this A/B device while .../by-name/modem does not exist when the kernel is
# booted with "fastboot boot".  Everything is logged to /tmp/mars-fw-mount.log.
LOG=/tmp/mars-fw-mount.log

mount_one() {	# $1 device, $2 mountpoint
	mp="$2"
	mkdir -p "$mp" 2>/dev/null
	for fs in vfat ext4; do
		if mount -t "$fs" -o ro "$1" "$mp" 2>>"$LOG"; then
			echo "MOUNTED $1 -> $mp (fstype $fs)"
			return 0
		fi
	done
	echo "FAILED to mount $1 at $mp (tried vfat, ext4)"
	return 1
}

{
	echo "=== mars-fw-mount $(date 2>/dev/null) ==="
	echo "--- /proc/cmdline:"; cat /proc/cmdline

	# slot suffix: property first, then androidboot.slot_suffix= in the cmdline,
	# then the plain candidates.  (The v4.7 log showed the cmdline carries
	# androidboot.slot_suffix=_a even though the property was empty.)
	suf="$(getprop ro.boot.slot_suffix 2>/dev/null)"
	cmdline="$(cat /proc/cmdline 2>/dev/null)"
	for w in $cmdline; do
		case "$w" in
			androidboot.slot_suffix=*) suf="${w#androidboot.slot_suffix=}" ;;
		esac
	done
	echo "--- getprop ro.boot.slot_suffix='$(getprop ro.boot.slot_suffix 2>/dev/null)' decided suffix='$suf'"
	echo "--- getprop ro.boot.bootdevice='$(getprop ro.boot.bootdevice 2>/dev/null)'"

	echo "--- /dev/block/by-name entries matching modem/firmware/image:"
	ls -l /dev/block/by-name/ 2>&1 | grep -iE "modem|firmware|image|bluetooth|dsp"
	echo "--- all by-name nodes: $(ls /dev/block/by-name/ 2>/dev/null | wc -l)"

	cands=""
	for s in "$suf" _a _b ""; do
		for base in /dev/block/by-name/modem /dev/block/bootdevice/by-name/modem; do
			c="$base$s"
			if [ -e "$c" ]; then
				case " $cands " in
					*" $c "*) ;;
					*) cands="$cands $c" ;;
				esac
			fi
		done
	done
	echo "--- candidate nodes:$cands"

	dev=""
	for c in $cands; do
		if mount_one "$c" /firmware; then dev="$c"; break; fi
	done

	if [ -n "$dev" ]; then
		if mount_one "$dev" /vendor/firmware_mnt; then
			echo "second mount at /vendor/firmware_mnt ok"
		else
			rmdir /vendor/firmware_mnt 2>/dev/null
			if ln -sfn /firmware /vendor/firmware_mnt; then
				echo "symlinked /vendor/firmware_mnt -> /firmware"
			else
				echo "could not create the symlink either"
			fi
		fi
	else
		echo "no modem/firmware node could be mounted; full by-name listing follows"
		ls -l /dev/block/by-name/ 2>&1
	fi

	echo "--- mounts matching firmware/modem:"
	mount 2>&1 | grep -iE "firmware|modem"
	echo "--- ls -la /firmware:"; ls -la /firmware 2>&1 | head -12
	echo "--- ls /firmware/image | head -20:"; ls /firmware/image 2>&1 | head -20
	echo "--- ls -la /vendor/firmware_mnt:"; ls -la /vendor/firmware_mnt 2>&1 | head -12
	echo "--- ls /vendor/firmware_mnt/image | head -20:"; ls /vendor/firmware_mnt/image 2>&1 | head -20
	echo "--- spss/spu/keymaster files in /vendor/firmware_mnt/image:"
	ls /vendor/firmware_mnt/image 2>&1 | grep -iE "spss|spu|keymaster|gatekeeper"
	echo "--- spss/spu/keymaster files in /firmware/image:"
	ls /firmware/image 2>&1 | grep -iE "spss|spu|keymaster|gatekeeper"
	echo "--- /dev/spss_utils:"; ls -l /dev/spss_utils 2>&1
	echo "--- spss platform devices:"; ls -d /sys/devices/platform/soc/*spss* 2>&1 | head -5
	echo "=== mars-fw-mount done ==="
} >> "$LOG" 2>&1
