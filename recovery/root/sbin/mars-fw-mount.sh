#!/system/bin/sh
# v4.7: mount the modem/firmware partition where both consumers expect it.
#   * the kernel/ueventd ask for firmware under /vendor/firmware_mnt/image
#     ("ueventd : firmware: attempted /vendor/firmware_mnt/image/ipa_fws.mdt")
#   * the vendor decryption/PMIC logic looks at /firmware
# The old rc line never worked (the modem node is modem_a/_b on this A/B device
# while ro.boot.slot_suffix is empty when the kernel is booted with "fastboot
# boot"), so this is done here, with full diagnostics in /tmp/mars-fw-mount.log.
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
	suf="${ro.boot.slot_suffix}"
	for w in $(cat /proc/cmdline); do
		case "$w" in androidboot.slot_suffix=*) suf="${w#androidboot.slot_suffix=}" ;; esac
	done
	echo "--- ro.boot.slot_suffix='${ro.boot.slot_suffix}' androidboot.slot_suffix='$suf'"
	echo "--- /dev/block/by-name entries matching modem/firmware/image:"
	ls -l /dev/block/by-name/ 2>&1 | grep -iE "modem|firmware|image|bluetooth|dsp"
	echo "--- all by-name nodes: $(ls /dev/block/by-name/ 2>/dev/null | wc -l)"

	cands=""
	for s in "$suf" _a _b ""; do
		for base in /dev/block/by-name/modem /dev/block/bootdevice/by-name/modem; do
			c="$base$s"
			if [ -e "$c" ]; then
				case " $cands " in *" $c "*) ;; *) cands="$cands $c" ;; esac
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
