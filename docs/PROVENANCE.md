# Provenance — where every file comes from, and what is still uncertain

Reference sources cloned during the synthesis:

| tag | repository | branch |
| --- | --- | --- |
| **LOS** | `LineageOS/android_device_xiaomi_mars` | `lineage-23.2` |
| **LOS-common** | `LineageOS/android_device_xiaomi_sm8350-common` | `lineage-23.2` |
| **TW** | `TeamWin/android_device_xiaomi_mars` | `android-11` |
| **TW-common** | `TeamWin/android_device_xiaomi_sm8350-common` | `android-11` |
| **NEB** | `nebrassy/device_xiaomi_mars-TWRP` | `android-11` |
| **FOX-KOTAH** | `kotah81/OrangeFox_device_xiaomi_venus` | `tiramisu` |
| **FOX-KOTAH-C** | `kotah81/OrangeFox_device_xiaomi_sm8350-common` | `tiramisu` |
| **FOX-VAYU** | `OrangeFox/device/vayu` | `fox_14.1` |
| **FOX-SYNC** | `gitlab.com/OrangeFox/sync` | `master` |
| **FOX-VENDOR** | `gitlab.com/OrangeFox/vendor/recovery` | `main` |
| **A14-MK** | `nebrassy/android_build` | `android-14` (the `build/make` fork fox_14.1 uses) |

## 1. File inventory

| file in this repo | origin | notes |
| --- | --- | --- |
| `BoardConfig.mk` | **newly written** | Partition sizes / cmdline / architecture from LOS-common; recovery-as-boot + `TW_*` from TW-common and FOX-KOTAH-C; AVB + `BUILD_BROKEN_*` from FOX-VAYU + FOX-KOTAH-C; prebuilt-kernel block modelled on FOX-VAYU. |
| `device.mk` | **newly written** | `TARGET_RECOVERY_DEVICE_MODULES` / `RECOVERY_LIBRARY_SOURCE_FILES` / `TW_LOAD_VENDOR_MODULES` from FOX-KOTAH-C; touch-firmware copy from FOX-KOTAH; crypto block from TW-common/FOX-KOTAH-C but commented out for phase 1. |
| `twrp_mars.mk` | **newly written**, structure from **FOX-VAYU** `twrp_vayu.mk` | `PRODUCT_NAME := twrp_mars`, inherits `base.mk` + `core_64_bit.mk` + `vendor/twrp/config/common.mk` + `device.mk` + `fox_mars.mk`. |
| `fox_mars.mk` | **newly written**, option set from **FOX-VAYU** `fox_vayu.mk` | Screen geometry adjusted to mars' 1440×3200. |
| `AndroidProducts.mk` | **newly written**, format from **FOX-VAYU** + **FOX-KOTAH** | `COMMON_LUNCH_CHOICES := twrp_mars-ap2a-eng twrp_mars-ap2a-userdebug` — three parts, see U11. |
| `Android.mk` | **TW** (trimmed) | The 2021 tree used `all-subdir-makefiles`; removed so that `scripts/` and `docs/` are never parsed. |
| `vendorsetup.sh` | **FOX-KOTAH** (adapted) | Same `fox_get_target_device` shape as FOX-VAYU, `FDEVICE=mars`, 1440×3200-aware. |
| `board-info.txt` | **newly written** | `require board=mars`. |
| `manifest.xml` | **TW** | mars HIDL manifest. **Retained but not referenced** — `ODM_MANIFEST_FILES` is deliberately not set in phase 1. |
| `modules.load.recovery` | **FOX-KOTAH** | Reference list only: `BOARD_VENDOR_RAMDISK_RECOVERY_KERNEL_MODULES_LOAD` is **not** set, because the kernel is prebuilt and no `.ko` is compiled. |
| `firmware/st_fts_k2.ftb`, `firmware/st_fts_k2_htp.ftb` | **FOX-KOTAH** | FTS touch panel firmware. See uncertainty U1. |
| `recovery/root/lib/firmware/st_fts_k2*.ftb` | copy of the above | Staged inside the recovery ramdisk at `/lib/firmware/` so touch does not depend on `TARGET_COPY_OUT_VENDOR_RAMDISK`. |
| `recovery/root/system/etc/recovery.fstab` | **newly written** from **TW-common** + **FOX-KOTAH-C** + **LOS-common** | See `FSTAB-DIFF.md`. This is `TARGET_RECOVERY_FSTAB`. |
| `recovery/root/system/etc/twrp.flags` | **newly written** from **FOX-KOTAH-C** + **TW-common** + **FOX-VAYU** | mars adaptations: dropped `/recovery` and MicroSD, added `/vendor_boot`. |
| `recovery/root/ueventd.qcom.rc` | **TW** | Verbatim from `twrp/recovery/root/ueventd.qcom.rc`. |
| `recovery/root/init.recovery.qcom.rc` | **TW-common** + **LOS-common** | Union: TW-common's USB/`by-name` block plus LOS-common's ADSP firmware mount. |
| `scripts/fetch-kernel.sh` | **newly written** | Style modelled on the kernel repo's `ci/make-bootimg.sh`. |
| `scripts/fox-sync.sh` | **newly written** | Wraps `FOX-SYNC`'s `orangefox_sync.sh --branch 14.1`. |
| `.github/workflows/build-recovery.yml` | **newly written** | Style modelled on the kernel repo's `.github/workflows/build-kernel.yml` (free-disk step, cache, artifact upload). |
| `prebuilt/Image` | **not committed** | Downloaded by CI from the kernel project's release. |

## 2. Design decisions worth recording

**D1 — self-contained tree, no `sm8350-common`.**
`device/xiaomi/mars` does not `include device/xiaomi/sm8350-common/*`. Everything
recovery needs was folded in, exactly like `FOX-VAYU`, which builds on
`fox_14.1` with no common tree at all. This means CI only has to fetch one
repository, and there is no risk of mixing an Android 16 common tree into an
Android 14 build system (the LOS-common tree is `lineage-23.2` and cannot be
used here).

**D2 — `BOARD_USES_RECOVERY_AS_BOOT := true`, no vendor_boot recovery.**
mars has no recovery partition and the requirement is a flashable `boot.img`.
With `BOARD_USES_RECOVERY_AS_BOOT=true` the build system's `recoveryimage`
target emits `boot.img` instead of `recovery.img`
(`build/make/core/Makefile`, `ifeq ($(BOARD_USES_RECOVERY_AS_BOOT),true)` →
`$(INSTALLED_BOOTIMAGE_TARGET): $(recoveryimage-deps)`).
`BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT` is explicitly `false` so
`OrangeFox_A14.sh` cannot mistake this for a vendor_boot-recovery device.

**D3 — no dtb.**
See README §4. `BOARD_INCLUDE_DTB_IN_BOOTIMG` is intentionally unset; with it
set, `recoveryimage-deps` would depend on `$(INSTALLED_DTBIMAGE_TARGET)`
(`dtb.img`) and the build would fail unless a real `BOARD_PREBUILT_DTBIMAGE_DIR`
existed.

**D4 — OrangeFox picks `boot.img` on the recovery-as-boot path.**
`OrangeFox_A14.sh` decides with
`if FOX_VENDOR_BOOT_RECOVERY=1 || BOARD_INCLUDE_RECOVERY_RAMDISK_IN_VENDOR_BOOT=true || BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT=true || -n "$INSTALLED_VENDOR_BOOTIMAGE_TARGET"`.
The Makefile hook for recovery-as-boot (`ORANGEFOX_CALLING_CARD=3.0`) does
**not** pass `INSTALLED_VENDOR_BOOTIMAGE_TARGET`, and D2 keeps the other three
clauses false, so `COMPILED_IMAGE_FILE="boot.img"`.

**D5 — phase 1 has crypto off.**
`TW_INCLUDE_CRYPTO := false`. The alternative (crypto on) requires QCOM
keymaster / `qseecomd` / `rpmb` blobs under `recovery/root/vendor/lib64/` that
this repo does not carry. The fstab metadata is nevertheless complete, because
it is phase 2's starting point.

**D6 — repository root is the device tree.**
Matches how `repo`/LineageOS device trees are laid out, so this repo can be
cloned directly to `device/xiaomi/mars`. The CI rsyncs it there while excluding
`.git/`, `.github/`, `scripts/`, `docs/`, `dist/`.

## 3. Uncertainties

| id | item | why it is uncertain | how to resolve |
| --- | --- | --- | --- |
| **U1** | `firmware/st_fts_k2*.ftb` touch firmware | Taken from the **venus** OrangeFox tree. mars and venus share the FTS touch family but may use different panel firmware. | Dump `/vendor/firmware/` from a mars device (`adb pull`) and diff. |
| **U2** | Kernel modules at runtime | Kernel is prebuilt ⇒ `TW_LOAD_VENDOR_MODULES` insmods `xiaomi_touch.ko` / `fts_touch_spi.ko` from the **installed ROM's** `/vendor/lib/modules`. Works only if vermagic matches. | Also build the modules in the kernel project and copy them into the recovery ramdisk (`BOARD_VENDOR_RAMDISK_RECOVERY_KERNEL_MODULES_LOAD` + `BOARD_VENDOR_RAMDISK_KERNEL_MODULES`). |
| **U3** | `TW_MAX_BRIGHTNESS := 4095` / `TW_DEFAULT_BRIGHTNESS := 1640` / `TW_FRAMERATE := 120` | Copied from FOX-VAYU (different panel) and FOX-KOTAH-C. Not measured on mars. | Read `/sys/class/backlight/panel0-backlight/max_brightness` on the device. |
| **U4** | `OF_SCREEN_H := 3200` / `OF_STATUS_H := 90` | GUI geometry, no mars reference available. | Adjust after the first boot and screenshot. |
| **U5** | `TW_NO_HAPTICS := true` | Phase-1 shortcut; the sm8350 AIDL vibrator HAL is not in this manifest. | Add the HAL packages + blobs, then drop the flag. |
| **U6** | `/cust` partition in `twrp.flags` | Taken from the 2021 sm8350 flags; not confirmed to exist on every mars SKU. | Check `/dev/block/by-name/` on the device. |
| **U7** | AVB settings (`--flags 3`, sha256_rsa2048 test key) | Copied from FOX-VAYU / LOS-common. The device is unlocked, so this only affects the hash footer in the produced image. | Not blocking; revisit if flashing complains. |
| **U8** | `AB_OTA_UPDATER` not set | Deliberately omitted (FOX-KOTAH-C does the same); setting it to `true` makes A14 require `AB_OTA_PARTITIONS` (`Makefile`: `$(error AB_OTA_PARTITIONS must be defined when using AB_OTA_UPDATER)`). | Not needed for a recovery-only build. |
| **U9** | Disk usage of the fox_14.1 sync | The `nebrassy` twrp-14 manifest is a near-full AOSP 14 manifest (143 KB) with `remove-minimal.xml` pruning. Exact post-prune size not measured. | Watch the first CI run; if it fills the runner, use a larger runner (the workflow has a `runner` input). |
| **U11** | The `<release>` token in the lunch combo | fox_14.1's `lunch()` requires `<product>-<release>-<variant>`, but no manifest in this tree publishes its release names (there is no `build/release/release_configs/` in `nebrassy/android_build`). `bp2a` is inferred from OrangeFox's own fox_16.0 instructions (`lunch twrp_mondrian-bp2a-eng`) and the sync script's `android14-qpr3-release` pin. | The CI probes `bp2a ap2a ap3a udc trunk_staging` and uses the first combo that lunches, so a wrong guess costs a few seconds, not a failed run. |
| **U10** | Two option names copied from the **FOX-KOTAH** reference do not exist in fox_14.1 | `OF_NO_HAPTICS` and `OF_IGNORE_LOGICAL_MOUNT_ERRORS` are not read anywhere in `OrangeFox/bootable/Recovery` (fox_14.1) or `OrangeFox/vendor/recovery` (main). kotah81's `vendorsetup.sh` exported the latter, but nothing consumes it. | Both were **removed** from `fox_mars.mk`. Haptics are disabled with the real switch, `TW_NO_HAPTICS := true` in `BoardConfig.mk` (checked: `bootable/recovery/Android.mk` uses `ifeq ($(TW_NO_HAPTICS), true)`). `scripts/check-tree.sh` now guards against re-introducing them. |

## 4. Why the fox_14.1 sync does not work the way the ticket assumed

```
$ git ls-remote --heads https://gitlab.com/OrangeFox/sync.git
53a303ecfb622c516082d3e61dbaa7d9f02f0120  refs/heads/master
```

Only `master` exists. `fox_14.1` is a **legacy** branch handled by
`orangefox_sync.sh` (`do_fox_141()`), which for `--branch 14.1` sets:

```
MIN_MANIFEST="https://github.com/nebrassy/platform_manifest_twrp_aosp.git"
FOX_BRANCH="fox_14.1"   TWRP_BRANCH="twrp-14"
DEVICE_BRANCH="android-14"   TW_DEVICE_BRANCH="android-14.1"
```

and then executes, in order:

1. `repo init --depth=1 -u $MIN_MANIFEST -b twrp-14`
2. `repo sync --force-sync -c -j$(nproc --all) --no-clone-bundle --no-tags`
3. patch `build/make` (`patch-manifest-fox_14.1.diff`), `system/vold`,
   `.repo/manifests/remove-minimal.xml`, `system/update_engine`,
   `vendor/twrp`
4. clone `device/qcom/common` (TW `android-14.1`),
   `device/qcom/twrp-common` (TW `android-14`)
5. clone `external/se_omapi` (OrangeFox `fox_14.1`)
6. replace `bootable/recovery` with `OrangeFox/bootable/Recovery` `fox_14.1`
7. replace `vendor/recovery` with `OrangeFox/vendor/recovery` `main`

It aborts on the first failure and does **not** run a test build
(`test_build` is commented out in `WorkNow()`).

`fox_16.0` is different: it uses the complete OrangeFox manifest
(`gitlab.com/OrangeFox/Manifest.git -b fox_16.0`) with plain
`repo init`/`repo sync` and is no longer legacy-patched. Switching this project
to 16.0 later would mean replacing `scripts/fox-sync.sh` with that two-command
flow.
