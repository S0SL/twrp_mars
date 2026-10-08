# `recovery.fstab` and crypto: LineageOS vs TWRP differences

This is the phase-2 starting point: what changed between the LineageOS (LAS)
tree and the two TWRP/OrangeFox trees, for **same-named files** and for the
crypto-relevant parts of the fstab.

Compared artefacts:

| short name | file |
| --- | --- |
| **LOS-A16** | `LineageOS/android_device_xiaomi_sm8350-common` (`lineage-23.2`) → `rootdir/etc/fstab.qcom` |
| **TW-A11** | `TeamWin/android_device_xiaomi_sm8350-common` (`android-11`) → `rootdir/etc/fstab.qcom` |
| **TW-A11-REC** | same tree → `twrp/recovery/root/system/etc/recovery.fstab` |
| **TW-A11-FLAGS** | same tree → `twrp/recovery/root/system/etc/twrp.flags` |
| **FOX-A13** | `kotah81/OrangeFox_device_xiaomi_sm8350-common` (`tiramisu`) → `twrp/recovery/root/system/etc/recovery.fstab` + `twrp.flags` |
| **FOX-A14-VAYU** | `OrangeFox/device/vayu` (`fox_14.1`) → `recovery/root/system/etc/recovery.fstab` + `twrp.flags` |

> Note: LOS-A16 has **no** `recovery.fstab`. It points `TARGET_RECOVERY_FSTAB` at
> the *same* `rootdir/etc/fstab.qcom` that the vendor image uses:
>
> ```make
> # LOS-A16 BoardConfigCommon.mk
> TARGET_RECOVERY_FSTAB := $(COMMON_PATH)/rootdir/etc/fstab.qcom
> ```
>
> TW-A11 **comments that line out** and ships a dedicated `recovery.fstab`
> instead:
>
> ```make
> # TW-A11 BoardConfigCommon.mk
> #TARGET_RECOVERY_FSTAB := $(COMMON_PATH)/rootdir/etc/fstab.qcom
> ```

---

## 1. `fstab.qcom`: LOS-A16 vs TW-A11

Full `diff -u` reduces to these semantic changes (licence header noise omitted):

```
 system        /system      ext4  ... wait,slotselect,avb=vbmeta_system,logical,first_stage_mount,avb_keys=...
-system_ext    /system_ext  ext4  ... wait,slotselect,avb,logical,first_stage_mount
-product       /product     ext4  ... wait,slotselect,avb,logical,first_stage_mount
-vendor        /vendor      ext4  ... wait,slotselect,avb=vbmeta,logical,first_stage_mount
-vendor_dlkm   /vendor_dlkm ext4  ... wait,slotselect,avb,logical,first_stage_mount
+system_ext    /system_ext  ext4  ... wait,slotselect,avb=vbmeta_system,logical,first_stage_mount
+product       /product     ext4  ... wait,slotselect,avb=vbmeta_system,logical,first_stage_mount
+vendor        /vendor      ext4  ... wait,slotselect,avb,logical,first_stage_mount
 odm           /odm         ext4  ... (identical)
 /dev/block/by-name/metadata          /metadata  (identical)
 /dev/block/bootdevice/by-name/persist /mnt/vendor/persist (identical)
 /dev/block/bootdevice/by-name/userdata /data    (identical except nodiscard)
 /dev/block/bootdevice/by-name/misc   /misc      (identical)
-/devices/platform/soc/8804000.sdhci/mmc_host*      /storage/sdcard1 ...
-/devices/platform/soc/1da4000.ufshc_card/host*     /storage/sdcard1 ...
 /devices/platform/soc/*.ssusb/*.dwc3/xhci-hcd.*.auto* /storage/usbotg (identical)
 /dev/block/bootdevice/by-name/modem  /vendor/firmware_mnt (identical)
 /dev/block/bootdevice/by-name/dsp    /vendor/dsp          (identical)
+/dev/block/bootdevice/by-name/vm-bootsys /vendor/vm-system
 /dev/block/bootdevice/by-name/bluetooth /vendor/bt_firmware (identical)
-/dev/block/bootdevice/by-name/qmcs   /mnt/vendor/qmcs  ... noatime,nosuid,nodev,...
+/dev/block/bootdevice/by-name/qmcs   /mnt/vendor/qmcs  ... nosuid,nodev,...
+/dev/block/bootdevice/by-name/spunvm /mnt/vendor/spunvm
```

### What actually matters here

| # | difference | impact |
| --- | --- | --- |
| **F1** | `vendor`: LOS-A16 uses `avb=vbmeta` (AVB chained to the **`vbmeta`** partition), TW-A11 uses plain `avb` | **Crypto-adjacent and boot-critical.** Different AVB chaining changes which vbmeta governs `vendor`. Phase 2's fstab must match the ROM family actually installed, or `fs_mgr` will refuse to verify/mount `vendor`. |
| **F2** | `system_ext` / `product`: LOS-A16 uses `avb`, TW-A11 uses `avb=vbmeta_system` | Same class of problem as F1, for the `vbmeta_system` chain. |
| **F3** | `vendor_dlkm` is present in LOS-A16, absent in TW-A11 | LOS-A16 splits `vendor_dlkm` out of `vendor`; older trees fold it in. A recovery that cannot mount `vendor_dlkm` will not find the kernel modules → **directly related to touch/display modules (see KNOWN_ISSUES I2)**. |
| **F4** | `/storage/sdcard1` (two `mmc_host`/`ufshc_card` sources) only exists in LOS-A16 | mars has no microSD slot; LOS carries these generically. Dropped in this tree. |
| **F5** | `/vendor/vm-system` (`vm-bootsys` partition) only in TW-A11 | Present on mars. Not mounted by this tree's `recovery.fstab` (OrangeFox handles it via `twrp.flags`); worth re-adding if `vm-system` content is ever needed. |
| **F6** | `/mnt/vendor/spunvm` + different `qmcs` mount options | Small; follows the ROM generation. |
| **F7** | **The `/data` line is byte-identical** (modulo `nodiscard`) | **The best possible news for phase 2**, see below. |

---

## 2. Crypto-related differences (the phase-2 critical part)

### 2.1 `/data` — identical FBE scheme across all four trees

LOS-A16 (`fstab.qcom`), TW-A11 (`fstab.qcom` and `recovery.fstab`),
FOX-A13 and FOX-A14-VAYU all agree on:

```
fileencryption      = aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0
metadata_encryption = aes-256-xts:wrappedkey_v0
keydirectory        = /metadata/vold/metadata_encryption
```

Literal `/data` lines (whitespace trimmed), to make the agreement obvious:

```
# LOS-A16 (fstab.qcom)
/data  f2fs  noatime,nosuid,nodev,discard,inlinecrypt,reserve_root=32768,resgid=1065,fsync_mode=nobarrier
       latemount,wait,check,formattable,fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0,
       keydirectory=/metadata/vold/metadata_encryption,metadata_encryption=aes-256-xts:wrappedkey_v0,
       quota,reservedsize=128M,sysfs_path=/sys/devices/platform/soc/1d84000.ufshc,checkpoint=fs

# TW-A11-REC (recovery.fstab)                       # identical except: nodiscard
       ... noatime,nosuid,nodev,nodiscard,inlinecrypt, ...

# FOX-A13 (recovery.fstab)                          # differences:
       ... noatime,nosuid,nodev,discard,...,inlinecrypt
       latemount,wait,formattable,...               # <- 'check' REMOVED
       metadata_encryption=...  keydirectory=...    # <- order swapped, same values

# FOX-A14-VAYU (recovery.fstab)                     # differences:
       ... inlinecrypt                              # <- 'check' REMOVED, sysfs_path REMOVED
```

**Conclusion:** mars' FBE parameters did not change between the 2021 (Android 11)
era and Android 16. A phase-2 implementation can use the same crypto parameters
for both HyperOS 2 (Android 14) and LineageOS 23.2 (Android 16).

### 2.2 `/metadata` — the one real functional difference

```
# LOS-A16 & TW-A11 (both files)
/metadata  ext4  noatime,nosuid,nodev,discard  wait,check,formattable,first_stage_mount
                                                 ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
# FOX-A13  (and this repo)
/metadata  ext4  noatime,nosuid,nodev,discard  wait,check,formattable,wrappedkey,first_stage_mount
                                                                      ^^^^^^^^^^^ ADDED
```

`wrappedkey` on `/metadata` is the OrangeFox addition. It is what tells the
recovery that metadata encryption uses **hardware-wrapped keys**, so that the
key can be unwrapped via the QCOM keymaster/TEE rather than derived in software.
**This is the single most important line for phase 2.** This repo already
carries it.

### 2.3 `twrp.flags`: `/data` and `/metadata` entries

```
# TW-A11-FLAGS
/metadata  ext4  /dev/block/bootdevice/by-name/metadata   flags=display="Metadata"
/data      ext4  /dev/block/bootdevice/by-name/userdata   fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0,keydirectory=/metadata/vold/metadata_encryption

# FOX-A13-FLAGS   (and this repo)
/metadata  ext4  /dev/block/bootdevice/by-name/metadata   flags=display="Metadata";backup=1;wrappedkey
/data      f2fs  /dev/block/bootdevice/by-name/userdata   flags=fileencryption=...,metadata_encryption=aes-256-xts:wrappedkey_v0,keydirectory=/metadata/vold/metadata_encryption
```

Differences:

| # | difference | impact |
| --- | --- | --- |
| **F8** | TW-A11-FLAGS declares `/data` as **`ext4`**; FOX-A13 declares **`f2fs`** | mars formats `/data` as f2fs. The TW-A11 value is stale/wrong for a modern ROM. This repo uses **f2fs**. |
| **F9** | FOX-A13 adds `metadata_encryption=...` to the `twrp.flags` `/data` line | TWRP needs it there too (not only in `recovery.fstab`) for wrapped-key metadata decryption. This repo carries it. |
| **F10** | FOX-A13 adds `wrappedkey` + `backup=1` to `/metadata` | Allows backing up the metadata partition, and enables wrapped keys. This repo carries `wrappedkey` and `backup=1`. |
| **F11** | TW-A11-FLAGS has `/firmware ... mounttodecrypt;fsflags=ro` | `mounttodecrypt` is a legacy flag; dropped. |

### 2.4 `TARGET_RECOVERY_FSTAB` and crypto build flags

| item | LOS-A16 | TW-A11 | FOX-KOTAH-C (A13) | this repo (phase 1) |
| --- | --- | --- | --- | --- |
| `TARGET_RECOVERY_FSTAB` | `rootdir/etc/fstab.qcom` | *commented out* | `$(DEVICE_PATH)/recovery/root/system/etc/recovery.fstab` (FOX-VAYU) | `recovery/root/system/etc/recovery.fstab` |
| `TW_INCLUDE_CRYPTO` | n/a (not a recovery tree) | `true` | `true` | **`false`** |
| `TW_INCLUDE_CRYPTO_FBE` | n/a | `true` | `true` | **`false`** |
| `TW_INCLUDE_FBE_METADATA_DECRYPT` | n/a | `true` | `true` | **`false`** |
| `BOARD_USES_QCOM_FBE_DECRYPTION` | n/a | `true` | `true` | `true` (inert while crypto is off) |
| `PRODUCT_PACKAGES += qcom_decrypt qcom_decrypt_fbe` | n/a | `true` | `true` | **commented out** |
| `TARGET_RECOVERY_DEVICE_MODULES` crypto libs | n/a | `libandroidicu`, `libdisplayconfig.qti`, `libion`, `vendor.display.config@*` | `+ libkeymaster4`, `libpuresoftkeymasterdevice` | only the display/ion subset |
| `PLATFORM_SECURITY_PATCH` override | n/a | `2099-12-31` | `2099-12-31` | not overridden (phase 1) |
| `PLATFORM_VERSION` override | n/a | `127` | `99.87.36` | not overridden (phase 1) |

The `PLATFORM_SECURITY_PATCH = 2099-12-31` / `PLATFORM_VERSION = 127` overrides
in TW-A11 and FOX-KOTAH-C are the classic TWRP trick: they make the recovery
claim a newer security patch than the ROM, which is needed so the crypto blobs
accept the recovery as a "new enough" client. **They are likely required in
phase 2** and are recorded here for that reason.

### 2.5 `init.recovery.qcom.rc`: LOS-A16 vs TW-A11

```
 on fs
     wait /dev/block/platform/soc/${ro.boot.bootdevice}
     symlink /dev/block/platform/soc/${ro.boot.bootdevice} /dev/block/bootdevice
-    # Load ADSP firmware for PMIC
-    mkdir /firmware
-    mount vfat /dev/block/bootdevice/by-name/modem${ro.boot.slot_suffix} /firmware ro context=u:object_r:firmware_file:s0
 
 on init
     setprop sys.usb.configfs 1
 
 on property:ro.boot.usbcontroller=*
     setprop sys.usb.controller ${ro.boot.usbcontroller}
     write /sys/class/udc/${ro.boot.usbcontroller}/device/../mode peripheral
-
-on property:dev.mnt.blk.firmware=*
-    write /sys/kernel/boot_adsp/boot 1
-
-on property:init.svc.fastbootd=running
-    umount /firmware
```

(there is no `init.recovery.qcom.rc` difference other than this — the LOS-A16
file is a superset). This repo uses the **LOS-A16 superset**, because on lahaina
the ADSP firmware has to be mounted for the PMIC to come up.

The `fastbootd` addition is also relevant to phase 2/3: `fastbootd` is what lets
you `fastboot flash` logical partitions, and it needs `/firmware` to be
unmounted first.

---

## 3. Summary for phase 2

1. The `/data` FBE parameters are **stable across Android 11 → 16**; reuse them.
2. Add `wrappedkey` to `/metadata` — already done here (this is the single
   change OrangeFox made to the sm8350 fstab).
3. Flip `TW_INCLUDE_CRYPTO` / `_FBE` / `_FBE_METADATA_DECRYPT` to `true`, add
   `qcom_decrypt` + `qcom_decrypt_fbe`, and add the keymaster libraries.
4. Provide the QCOM crypto blobs under `recovery/root/vendor/lib64/`
   (`libQSEEComAPI.so`, `libkeymasterdeviceutils.so`, `librpmb.so`,
   `libssd.so`, `libtime_genoff.so`, `qseecomd`, …) — the list used by
   `FOX-A14-VAYU` is the best starting point; extract the mars equivalents from
   a mars ROM dump.
5. Re-add the `PLATFORM_SECURITY_PATCH` / `PLATFORM_VERSION` overrides.
6. Decide F1/F2 (`avb=` chaining) per ROM family: `avb=vbmeta` for
   LOS-23.2-flavoured fstabs vs plain `avb` for the older ones.
