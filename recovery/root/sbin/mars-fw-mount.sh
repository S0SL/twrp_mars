#!/system/bin/sh
# v4.9: firmware plumbing for the SPU / gatekeeper stack.
#
#  1. mount the modem image read-only at /firmware (it is the partition that
#     holds image/*.b00 firmware, and the PMIC/adsp logic looks there)
#  2. build /vendor/firmware_mnt/image as a real directory whose entries are
#     symlinks into /firmware/image - the kernel PIL and ueventd ask for
#     /vendor/firmware_mnt/image/... and follow symlinks, and unlike a second
#     vfat mount this directory is writable, so missing files can be added
#  3. report the firmware name the SPU driver actually selected (device tree
#     properties qcom,spss-*-firmware-name and the read-only sysfs file
#     firmware_name), plus every "firmware: attempted" request in dmesg/logcat
#  4. look for spss1p*/spu*/spss* images in the other partitions (imagefv,
#     bluetooth, dsp, abl, xbl, tz, hyp, keymaster, aop) and copy whatever is
#     found into /vendor/firmware_mnt/image
# Everything is logged to /tmp/mars-fw-mount.log.
LOG=/tmp/mars-fw-mount.log
TARGET=/vendor/firmware_mnt/image

try_mount() {	# $1 device, $2 mountpoint -> 0 on success
	# audit fix: label the firmware files like the vendor tree does.  The audit
	# showed "avc: denied { search } for ... scontext=u:r:ueventd:s0
	# tcontext=u:object_r:vfat:s0 tclass=dir permissive=1" because the modem image
	# was mounted without context=; harmless while recovery is permissive, but
	# firmware loading would break once SELinux is enforcing.  Fall back to a
	# plain mount if the kernel rejects the option.
	mkdir -p "$2" 2>/dev/null
	for ctx in "ro,context=u:object_r:firmware_file:s0" "ro"; do
		for fs in vfat ext4; do
			if mount -t "$fs" -o "$ctx" "$1" "$2" 2>>"$LOG"; then
				return 0
			fi
		done
	done
	return 1
}

{
	echo "=== mars-fw-mount $(date 2>/dev/null) ==="
	echo "--- /proc/cmdline:"; cat /proc/cmdline

	suf="$(getprop ro.boot.slot_suffix 2>/dev/null)"
	for w in $(cat /proc/cmdline 2>/dev/null); do
		case "$w" in
			androidboot.slot_suffix=*) suf="${w#androidboot.slot_suffix=}" ;;
		esac
	done
	echo "--- suffix='$suf' (getprop='$(getprop ro.boot.slot_suffix 2>/dev/null)')"

	# ---------------------------------------------------------------- 1) modem
	echo "--- by-name entries (modem/firmware/imagef*):"
	ls -l /dev/block/by-name/ 2>&1 | grep -iE "modem|firmware|imagefv|image"
	mdev=""
	for s in "$suf" _a _b ""; do
		for c in "/dev/block/by-name/modem$s" "/dev/block/bootdevice/by-name/modem$s"; do
			if [ -e "$c" ] && try_mount "$c" /firmware; then mdev="$c"; break; fi
		done
		[ -n "$mdev" ] && break
	done
	if [ -z "$mdev" ] && [ -d /firmware/image ]; then
		mdev="(already mounted)"
	fi
	echo "--- modem image mounted at /firmware: '$mdev'"
	ls /firmware/image 2>&1 | head -8

	# --------------------------------------------------- 2) writable image dir
	umount /vendor/firmware_mnt 2>/dev/null
	rm -rf /vendor/firmware_mnt 2>/dev/null
	mkdir -p "$TARGET" 2>/dev/null
	if [ -d /firmware/image ]; then
		n=0
		for f in /firmware/image/*; do
			[ -e "$f" ] || continue
			ln -sf "$f" "$TARGET/$(basename "$f")" 2>/dev/null && n=$((n + 1))
		done
		echo "--- symlinked $n files from /firmware/image into $TARGET"
	fi
	ls "$TARGET" 2>&1 | head -5
	echo "--- target writable: $( (touch "$TARGET/.wtest" 2>/dev/null && echo yes && rm -f "$TARGET/.wtest") || echo no)"

	# ------------------------------------------ 2b) SPU non-volatile memory
	# The vendor ROM's init mounts this vfat partition at /mnt/vendor/spunvm
	# (init.target.rc).  The SPU stack (fingerprint/gatekeeper) expects it.
	for s2 in "$suf" _a _b; do
		dev="/dev/block/by-name/spunvm$s2"
		if [ -e "$dev" ]; then
			mkdir -p /mnt/vendor/spunvm 2>/dev/null
			if mount -t vfat -o rw,context=u:object_r:vendor_spunvm_file:s0 "$dev" /mnt/vendor/spunvm 2>>"$LOG" ||
			   mount -t vfat -o rw "$dev" /mnt/vendor/spunvm 2>>"$LOG"; then
				echo "--- spunvm mounted: $dev -> /mnt/vendor/spunvm ($(ls /mnt/vendor/spunvm 2>/dev/null | head -3 | tr '\n' ' '))"
			else
				echo "--- spunvm mount failed for $dev"
			fi
			break
		fi
	done

	# ------------------------------------------------- 3) which firmware name?
	echo "--- device tree spss firmware names:"
	for p in /proc/device-tree/soc*/qcom,spss*/qcom,spss-*-firmware-name \
	         /proc/device-tree/soc*/qcom,spss_utils*/qcom,spss-*-firmware-name; do
		[ -e "$p" ] && echo "    $p = $(tr -d '\000' < "$p" 2>/dev/null)"
	done
	echo "--- spss driver sysfs:"
	for d in /sys/devices/platform/soc/*spss* /sys/devices/platform/*spss*; do
		[ -e "$d/firmware_name" ] && echo "    $d/firmware_name = $(cat "$d/firmware_name" 2>/dev/null)"
	done
	echo "--- firmware requests seen by ueventd (dmesg):"
	dmesg 2>/dev/null | grep -iE "firmware: attempted|spss|spu" | tail -25
	echo "--- same, from logcat (if any):"
	logcat -d 2>/dev/null | grep -iE "firmware: attempted|spss|spu" | tail -25

	# ------------------------------------- 4) hunt for the missing spss images
	echo "--- searching other partitions for spss/spu images:"
	mkdir -p /tmp/fwprobe
	for p in imagefv bluetooth dsp abl xbl tz hyp keymaster aop; do
		for s in "$suf" _a _b; do
			dev="/dev/block/by-name/$p$s"
			[ -e "$dev" ] || continue
			mp="/tmp/fwprobe/$p$s"
			if try_mount "$dev" "$mp"; then
				echo "    [$p$s] mounted; top level: $(ls "$mp" 2>/dev/null | head -6 | tr '\n' ' ')"
				hits="$(ls "$mp" 2>/dev/null | grep -iE 'spss|spu')"
				hits2="$(ls "$mp"/image 2>/dev/null | grep -iE 'spss|spu')"
				hits3="$(find "$mp" -maxdepth 3 -iname '*spss*' 2>/dev/null | head -5) $(find "$mp" -maxdepth 3 -iname 'spu*' 2>/dev/null | head -5)"
				[ -n "$hits$hits2$hits3" ] && echo "    [$p$s] MATCHES: $hits $hits2 $hits3"
				# copy anything that looks like the SPU image into place
				for f in "$mp"/image/*spss* "$mp"/image/spu* "$mp"/*spss* "$mp"/spu*; do
					[ -f "$f" ] || continue
					cp -f "$f" "$TARGET/" 2>>"$LOG" && echo "    copied $(basename "$f") from $p$s"
				done
				umount "$mp" 2>/dev/null
			fi
		done
	done

	# ------------------------------------------------------------- final state
	echo "--- final $TARGET (spss/spu related):"
	ls -la "$TARGET" 2>/dev/null | grep -iE "spss|spu|total"
	echo "--- final count: $(ls "$TARGET" 2>/dev/null | wc -l) entries"
	echo "--- /dev/spss_utils: $(ls -l /dev/spss_utils 2>&1)"
	echo "=== mars-fw-mount done ==="
} >> "$LOG" 2>&1
