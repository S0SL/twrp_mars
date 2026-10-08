#!/usr/bin/env bash
#
# Static checks for the mars recovery device tree.
#
# There is no AOSP tree locally (by design - it would not fit), so this is what
# can be verified without one:
#
#   1. every file the build system will look for actually exists
#   2. recovery.fstab parses as a well-formed fs_mgr fstab, with every
#      fs_mgr flag in the known-good set
#   3. twrp.flags parses as a well-formed TWRP flags file
#   4. makefiles have balanced conditionals and no recipe lines (tabs)
#   5. the workflow is valid YAML and references existing scripts
#   6. shell scripts pass `bash -n`
#   7. no stray absolute build-host paths
#   8. the device codename is consistent
#
# Usage: ./scripts/check-tree.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FAIL=0
pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$1"; }
hdr()  { printf '\n== %s ==\n' "$1"; }

# ---------------------------------------------------------------------------
hdr "1. required files"
REQUIRED=(
	BoardConfig.mk
	device.mk
	twrp_mars.mk
	fox_mars.mk
	AndroidProducts.mk
	Android.mk
	vendorsetup.sh
	board-info.txt
	modules.load.recovery
	manifest.xml
	firmware/st_fts_k2.ftb
	firmware/st_fts_k2_htp.ftb
	recovery/root/system/etc/recovery.fstab
	recovery/root/system/etc/twrp.flags
	recovery/root/ueventd.qcom.rc
	recovery/root/init.recovery.qcom.rc
	recovery/root/lib/firmware/st_fts_k2.ftb
	recovery/root/lib/firmware/st_fts_k2_htp.ftb
	scripts/fetch-kernel.sh
	scripts/fox-sync.sh
	.github/workflows/build-recovery.yml
	README.md
	docs/PROVENANCE.md
	docs/FSTAB-DIFF.md
	docs/PHASE2-CRYPTO.md
	docs/KNOWN_ISSUES.md
	docs/BUILD-STATUS.md
)
for f in "${REQUIRED[@]}"; do
	[ -f "$f" ] && pass "$f" || fail "$f is missing"
done

# ---------------------------------------------------------------------------
hdr "2. recovery.fstab"
FSTAB=recovery/root/system/etc/recovery.fstab

# fs_mgr flags accepted by Android 14's fs_mgr (superset of what we use).
KNOWN_FS_MGR_FLAGS="wait check checkatboot nofail slotselect slotselect_other logical first_stage_mount latemount formattable avb avb=vbmeta avb=vbmeta_system avb_keys wrappedkey keydirectory metadata_encryption fileencryption quota reservedsize checkpoint sysfs_path defaults voldmanaged encryptable length readonly recoveryonly"
# flag=value forms that are valid for fs_mgr
KNOWN_FS_MGR_KV="avb avb_keys fileencryption keydirectory metadata_encryption reservedsize sysfs_path checkpoint"
KNOWN_MOUNT_OPTS="ro rw noatime nosuid nodev nodiscard discard barrier inlinecrypt context uid gid dmask fmask shortname reserve_root resgid fsync_mode max_batch_time force_fsync errors defaults"

n=0
while IFS= read -r line; do
	n=$((n + 1))
	# strip comments / blanks
	case "$line" in
		''|'#'*) continue ;;
	esac
	read -r -a cols <<<"$line"
	if [ "${#cols[@]}" -ne 5 ]; then
		fail "fstab line $n has ${#cols[@]} columns, expected 5: $line"
		continue
	fi
	src="${cols[0]}"; mnt="${cols[1]}"; type="${cols[2]}"; opts="${cols[3]}"; flags="${cols[4]}"
	case "$type" in
		ext4|f2fs|erofs|vfat|emmc|auto) ;;
		*) fail "fstab line $n: unknown fstype '$type'" ;;
	esac
	case "$mnt" in
		/*) ;;
		*) fail "fstab line $n: mount point '$mnt' is not absolute" ;;
	esac
	# every fs_mgr flag must be known
	IFS=',' read -r -a fl <<<"$flags"
	for f in "${fl[@]}"; do
		ok=0
		for k in $KNOWN_FS_MGR_FLAGS; do [ "$f" = "$k" ] && ok=1 && break; done
		# allow avb_keys=..., or the reserved-root/fileencryption style key=value
		if [ "$ok" != 1 ]; then
			kb="${f%%=*}"
			for k in $KNOWN_FS_MGR_KV; do [ "$f" != "$kb" ] && [ "$kb" = "$k" ] && ok=1 && break; done
		fi
		[ "$ok" = 1 ] || fail "fstab line $n: unknown fs_mgr flag '$f'"
	done
	# mount options must be known
	IFS=',' read -r -a ol <<<"$opts"
	for o in "${ol[@]}"; do
		[ -z "$o" ] && continue
		base="${o%%=*}"
		ok=0
		for k in $KNOWN_MOUNT_OPTS; do [ "$base" = "$k" ] && ok=1 && break; done
		[ "$ok" = 1 ] || warn "fstab line $n: unrecognised mount option '$o'"
	done
done <"$FSTAB"
[ "$n" -gt 0 ] && pass "recovery.fstab parsed ($n lines)"

# /data must carry the mars FBE attributes
grep -q 'fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0' "$FSTAB" \
	&& pass "/data keeps the mars fileencryption scheme" \
	|| fail "/data lost its fileencryption= scheme"
grep -q 'metadata_encryption=aes-256-xts:wrappedkey_v0' "$FSTAB" \
	&& pass "/data keeps metadata_encryption" || fail "/data lost metadata_encryption"
grep -qE '^/dev/block/(bootdevice/)?by-name/metadata[[:space:]]+/metadata[[:space:]]+.*wrappedkey' "$FSTAB" \
	&& pass "/metadata has the wrappedkey flag (phase-2 requirement)" \
	|| fail "/metadata is missing the wrappedkey flag"

# ---------------------------------------------------------------------------
hdr "3. twrp.flags"
FLAGS=recovery/root/system/etc/twrp.flags
m=0
while IFS= read -r line; do
	m=$((m + 1))
	case "$line" in ''|'#'*) continue ;; esac
	read -r -a cols <<<"$line"
	# <mount point> <fstype> <device> [device2] <flags...>
	if [ "${#cols[@]}" -lt 4 ]; then
		fail "twrp.flags line $m has ${#cols[@]} columns: $line"
		continue
	fi
	case "${cols[0]}" in
		/*) ;;
		*) fail "twrp.flags line $m: mount point '${cols[0]}' is not absolute" ;;
	esac
	printf '%s\n' "${cols[@]}" | grep -q '^flags=' \
		|| warn "twrp.flags line $m has no flags= token"
done <"$FLAGS"
[ "$m" -gt 0 ] && pass "twrp.flags parsed ($m lines)"

grep -q '^/boot ' "$FLAGS" && pass "/boot present in twrp.flags" || fail "/boot missing from twrp.flags"
grep -q '^/vendor_boot ' "$FLAGS" && pass "/vendor_boot present in twrp.flags" || warn "/vendor_boot missing"
if grep -qE '^/recovery\s' "$FLAGS"; then
	fail "/recovery is listed in twrp.flags but mars has no recovery partition"
else
	pass "no /recovery entry (correct for mars)"
fi

# ---------------------------------------------------------------------------
hdr "4. makefiles"
for f in BoardConfig.mk device.mk twrp_mars.mk fox_mars.mk AndroidProducts.mk Android.mk; do
	o=$(grep -cE '^[[:space:]]*(ifeq|ifneq|ifdef|ifndef)' "$f")
	c=$(grep -cE '^[[:space:]]*endif' "$f")
	[ "$o" = "$c" ] && pass "$f conditionals balanced ($o)" \
		|| fail "$f has $o conditional openers and $c endif"
done
# product name / lunch target consistency
grep -q '^PRODUCT_NAME := twrp_\$(PRODUCT_RELEASE_NAME)' twrp_mars.mk \
	&& pass "twrp_mars.mk sets PRODUCT_NAME := twrp_mars" \
	|| fail "twrp_mars.mk PRODUCT_NAME is not twrp_\$(PRODUCT_RELEASE_NAME)"
grep -q 'COMMON_LUNCH_CHOICES' AndroidProducts.mk \
	&& pass "AndroidProducts.mk declares COMMON_LUNCH_CHOICES" \
	|| fail "AndroidProducts.mk has no COMMON_LUNCH_CHOICES"
# fox_14.1's lunch() requires <product>-<release>-<variant>: a 2-part combo is
# rejected with "Valid combos must be of the form <product>-<release>-<variant>"
# (that is what killed CI run 4).  Every declared choice must have 3 parts.
BADCHOICE=""
for c in $(sed -n '/COMMON_LUNCH_CHOICES/,/^$/p' AndroidProducts.mk \
           | grep -oE 'twrp_mars[a-z0-9_-]*'); do
	[ "$(printf '%s' "$c" | awk -F- '{print NF}')" = 3 ] || BADCHOICE="$BADCHOICE $c"
done
if [ -z "$BADCHOICE" ] && grep -q 'twrp_mars-[a-z0-9_]*-eng' AndroidProducts.mk; then
	pass "lunch choices are 3-part (product-release-variant)"
else
	fail "non 3-part lunch choice(s):$BADCHOICE -- fox_14.1 lunch() rejects them"
fi
grep -q 'TARGET_PREBUILT_KERNEL' BoardConfig.mk \
	&& pass "BoardConfig.mk uses TARGET_PREBUILT_KERNEL" \
	|| fail "BoardConfig.mk does not use TARGET_PREBUILT_KERNEL"
if grep -qE '^BOARD_INCLUDE_DTB_IN_BOOTIMG' BoardConfig.mk; then
	fail "BOARD_INCLUDE_DTB_IN_BOOTIMG must stay unset (header v3 boot has no dtb)"
else
	pass "BOARD_INCLUDE_DTB_IN_BOOTIMG not set (correct)"
fi
grep -q 'BOARD_USES_RECOVERY_AS_BOOT := true' BoardConfig.mk \
	&& pass "BOARD_USES_RECOVERY_AS_BOOT := true" \
	|| fail "BOARD_USES_RECOVERY_AS_BOOT is not true"
grep -q 'TARGET_RECOVERY_FSTAB' BoardConfig.mk \
	&& pass "TARGET_RECOVERY_FSTAB is set" || fail "TARGET_RECOVERY_FSTAB is not set"
# the fstab path referenced must exist
P=$(grep -oE 'TARGET_RECOVERY_FSTAB := \$\(DEVICE_PATH\)/[^ ]+' BoardConfig.mk | sed 's|.*DEVICE_PATH)/||')
if [ -n "$P" ] && [ -f "$P" ]; then pass "TARGET_RECOVERY_FSTAB -> $P exists"
elif [ -n "$P" ]; then fail "TARGET_RECOVERY_FSTAB -> $P does not exist"; fi

# ---------------------------------------------------------------------------
hdr "5. workflow"
WF=.github/workflows/build-recovery.yml
if python3 -c "import yaml,sys; yaml.safe_load(open('$WF'))" 2>/dev/null; then
	pass "$WF is valid YAML"
else
	fail "$WF is not valid YAML"
fi
for s in scripts/fetch-kernel.sh scripts/fox-sync.sh; do
	grep -q "$s" "$WF" && pass "$WF references $s" || warn "$WF does not reference $s"
done
if grep -vE '^[[:space:]]*#' "$WF" | grep -q 'repo init -u https://gitlab.com/OrangeFox/sync.git -b fox_14.1'; then
	fail "$WF still uses the invalid repo init -b fox_14.1"
else
	pass "$WF does not use the invalid repo init -b fox_14.1 (only in comments)"
fi

# Regression guards for the two failures seen in CI run 37761738123.
# 1) `set -u` breaks AOSP's build/envsetup.sh ("TOP: unbound variable").
#    Checked precisely against the run block of the step that sources it.
#    NB: the option cluster must be parsed, not string-matched -- "-u" is NOT a
#    substring of "-euo".
if python3 - "$WF" <<'PY'
import sys, re, yaml

def enables_nounset(line):
    if not line.startswith("set "):
        return False
    if re.search(r'(^|\s)-[a-zA-Z]*u[a-zA-Z]*(\s|$)', line):
        return True
    if re.search(r'(^|\s)-o\s+nounset(\s|$)', line):
        return True
    if re.search(r'(^|\s)--nounset(\s|$)', line):
        return True
    return False

d = yaml.safe_load(open(sys.argv[1]))
for s in d["jobs"]["build"]["steps"]:
    run = s.get("run", "")
    if "source build/envsetup.sh" not in run:
        continue
    for line in run.splitlines():
        line = line.strip()
        if line.startswith("source build/envsetup.sh"):
            sys.exit(1)                    # reached the source line safely
        if enables_nounset(line):
            sys.exit(0)                    # BAD: nounset is in effect
sys.exit(1)
PY
then
	fail "$WF enables 'set -u' before sourcing build/envsetup.sh (breaks on \$TOP)"
else
	pass "workflow does not enable 'set -u' before build/envsetup.sh"
fi
# 2) the upstream vendor/twrp patch path bug must stay worked around.
if grep -q 'patch-vendor-twrp' scripts/fox-sync.sh; then
	pass "fox-sync.sh works around the vendor/twrp patch path bug"
else
	fail "fox-sync.sh no longer works around the upstream vendor/twrp patch path bug"
fi

# ---------------------------------------------------------------------------
hdr "6. shell scripts"
for f in scripts/*.sh vendorsetup.sh; do
	bash -n "$f" 2>/dev/null && pass "bash -n $f" || fail "bash -n $f"
done

# ---------------------------------------------------------------------------
hdr "7. no build-host paths leaked"
if grep -rn '/root/mi11\|/home/runner/work/twrp_mars/twrp_mars' \
	--include='*.mk' --include='*.sh' --include='*.yml' --include='*.md' . 2>/dev/null \
	| grep -v '^\./docs/' | grep -v '^\./scripts/check-tree.sh'; then
	fail "absolute build-host paths found (see above)"
else
	pass "no absolute build-host paths in the tree"
fi

# ---------------------------------------------------------------------------
hdr "8. codename consistency"
BAD=$(grep -rn 'venus\|star\b\|haydn\|odin' --include='*.mk' --include='*.fstab' \
	--include='twrp.flags' --include='*.rc' . 2>/dev/null | grep -v '^\./docs/' \
	| grep -vE ':[0-9]+:[[:space:]]*#' | cut -d: -f1 | sort -u || true)
if [ -n "$BAD" ]; then
	warn "other codenames mentioned in: $BAD"
else
	pass "no other device codenames in build inputs"
fi
grep -q 'TARGET_OTA_ASSERT_DEVICE := mars' BoardConfig.mk \
	&& pass "TARGET_OTA_ASSERT_DEVICE := mars" \
	|| fail "TARGET_OTA_ASSERT_DEVICE is not mars"

# Regression guard: option names that look plausible but are read by nothing in
# fox_14.1.  See docs/PROVENANCE.md U10.
for bogus in OF_NO_HAPTICS OF_IGNORE_LOGICAL_MOUNT_ERRORS; do
	if grep -rqE "^[[:space:]]*${bogus}[[:space:]]*:?=" ./*.mk; then
		fail "$bogus is not read by fox_14.1 (use TW_NO_HAPTICS in BoardConfig.mk instead)"
	else
		pass "$bogus not used (correct)"
	fi
done
grep -qE '^TW_NO_HAPTICS[[:space:]]*:=[[:space:]]*true' BoardConfig.mk \
	&& pass "TW_NO_HAPTICS := true (the switch OrangeFox actually reads)" \
	|| fail "TW_NO_HAPTICS is not set to 'true' in BoardConfig.mk"

# ---------------------------------------------------------------------------
echo
if [ "$FAIL" -eq 0 ]; then
	printf '\033[32mALL CHECKS PASSED\033[0m\n'
	exit 0
fi
printf '\033[31m%s CHECK(S) FAILED\033[0m\n' "$FAIL"
exit 1
