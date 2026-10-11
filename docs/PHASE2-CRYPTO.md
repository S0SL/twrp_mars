# Phase 2 — decrypting `/data`

> **v4: RESOLVED.** Phase 2 is implemented in v4 (`boot-v4.img`, `TW_DEVICE_VERSION
> mars-2`).  What actually had to change is recorded in
> [V4-REPORT.md](V4-REPORT.md); the short version:
>
> * `device.mk`: `TW_USE_FSCRYPT_POLICY := 2`, `TW_INCLUDE_CRYPTO := true`
>   (fox_14.1 then turns on FBE + metadata decrypt + the keystore2 stack by
>   itself, `bootable/recovery/Android.mk:348-375`), `PRODUCT_PACKAGES +=
>   qcom_decrypt qcom_decrypt_fbe`, plus the `PLATFORM_VERSION` /
>   `PLATFORM_SECURITY_PATCH` overrides in *device.mk* (version_util.mk:53 only
>   rejects them before that file is parsed; envsetup.mk loads the product
>   config first).
> * **`TARGET_RECOVERY_DEVICE_MODULES += libkeymaster4 libpuresoftkeymasterdevice`
>   from §2 below is NOT needed on fox_14.1** — that is the Android 11 recipe.
>   `bootable/recovery/prebuilt/Android.mk:165-267` already copies
>   `libkeymaster4support`, `libkeymaster4_1support`, `libpuresoftkeymasterdevice`,
>   `libsoftkeymaster`, `android.hardware.keymaster@4.0/4.1.so`,
>   `android.hardware.gatekeeper@1.0.so`, `libion` and `libxml2` into the recovery
>   ramdisk once `TW_INCLUDE_CRYPTO` is on.
> * The QCOM TEE blobs came from **TheMuppets/proprietary_vendor_xiaomi_sm8350-common
>   `lineage-23.2`** (not from a device dump): qseecomd, keymaster@4.1-service-qti,
>   gatekeeper@1.0-service-qti (+ its `hw/` impl) and 18 `vendor/lib64/*.so`.
>   Their list matches LineageOS' own `proprietary-files.txt`, whose header says
>   the blobs were extracted from `star OS2.0.7.0.UKAMIXM` — the same vendor the
>   user's device runs, so the "blob/ROM mismatch" risk in §4 did not
>   materialise.
> * §4's other risks: `wrappedkey` on `/metadata` was already in the fstab; the
>   AVB chaining question (F1/F2) is moot for this recovery because it mounts
>   /vendor with the plain `avb` entry that the ROM family installed here uses.

Phase 1 deliberately ships with `TW_INCLUDE_CRYPTO := false`.
This file records exactly what has to change, and why.

## 1. What we know already (from `FSTAB-DIFF.md`)

mars uses **FBE with hardware-wrapped keys**:

```
fileencryption      = aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0
metadata_encryption = aes-256-xts:wrappedkey_v0
keydirectory        = /metadata/vold/metadata_encryption
```

These parameters are **identical in the 2021 Android 11 TWRP tree, the Android 13
OrangeFox tree and the Android 16 LineageOS tree**, so the same crypto code path
should serve both HyperOS 2 (Android 14) and LineageOS 23.2 (Android 16).

The only sm8350-specific fstab change OrangeFox ever made is adding `wrappedkey`
to the `/metadata` line — this repo already carries it.

## 2. Board/product changes to make

In `device.mk`:

```make
TW_INCLUDE_CRYPTO := true
TW_INCLUDE_CRYPTO_FBE := true
TW_INCLUDE_FBE_METADATA_DECRYPT := true

PRODUCT_PACKAGES += \
    qcom_decrypt \
    qcom_decrypt_fbe

TARGET_RECOVERY_DEVICE_MODULES += \
    libkeymaster4 \
    libpuresoftkeymasterdevice

RECOVERY_LIBRARY_SOURCE_FILES += \
    $(TARGET_OUT_SHARED_LIBRARIES)/libkeymaster4.so \
    $(TARGET_OUT_SHARED_LIBRARIES)/libpuresoftkeymasterdevice.so

# TWRP needs to look "newer" than the ROM for the TEE blobs to cooperate
PLATFORM_SECURITY_PATCH := 2099-12-31
VENDOR_SECURITY_PATCH := 2099-12-31
PLATFORM_VERSION := 99.87.36
PLATFORM_VERSION_LAST_STABLE := $(PLATFORM_VERSION)
```

`BOARD_USES_QCOM_FBE_DECRYPTION := true` is already in `BoardConfig.mk`.

## 3. The blocking piece: QCOM TEE blobs

Decryption needs the vendor's TEE/keystore stack, which is **not buildable from
source**. `OrangeFox/device/vayu` ships it prebuilt under
`recovery/root/vendor/lib64/`; the equivalent list for mars still has to be
extracted.

Starting list (from the vayu tree, all under `recovery/root/vendor/lib64/`
unless noted):

```
android.hardware.gatekeeper@1.0-impl-qti.so   (hw/ subdir)
libGPreqcancel.so            libGPreqcancel_svc.so
libQSEEComAPI.so             libSecureUILib.so
libStDrvInt.so               libdiag.so
libdisplayconfig.qti.so      libdrm.so
libdrmfs.so                  libdrmtime.so
libkeymasterdeviceutils.so   libkeymasterprovision.so
libkeymasterutils.so         libkeystore-engine-wifi-hidl.so
libkeystore-wifi-hidl.so     libops.so
libqcbor.so                  libqdutils.so
libqisl.so                   libqservice.so
libqtikeymaster4.so          librpmb.so
libsecureui.so               libsecureui_svcsock.so
libspcom.so                  libspl.so
libssd.so                    libtime_genoff.so
vendor.display.config@1.0.so vendor.display.config@2.0.so
vendor.qti.hardware.tui_comm@1.0.so
vendor.qti.hardware.wifi.keystore@1.0.so
```

plus these executables / init:

```
recovery/root/system/bin/android.hardware.gatekeeper@1.0-service-qti
recovery/root/system/bin/android.hardware.keymaster@4.1-service-qti
recovery/root/system/bin/qseecomd
recovery/root/system/bin/postrecoveryboot.sh
recovery/root/init.recovery.qcom_decrypt.rc   (imported by init.recovery.qcom.rc)
recovery/root/system/etc/vintf/manifest.xml   + the per-HAL manifest fragments
recovery/root/vendor/etc/vintf/manifest.xml   + the per-HAL manifest fragments
```

**How to get the mars versions:** pull them from a mars device running the ROM
you care about (`adb pull /vendor/lib64/...`, `/vendor/bin/hw/...`,
`/vendor/etc/vintf/`), or extract them from the ROM's `vendor` partition. They
are the ROM's own blobs, so they are ABI-matched to that ROM's keymaster HAL —
which is also why cross-ROM decryption is genuinely hard.

## 4. Risks specific to phase 2

| risk | why |
| --- | --- |
| Blob/ROM mismatch | The keymaster HAL version differs between HyperOS 2 and LOS 23.2. A recovery carrying one ROM's blobs may fail to unwrap the keys of the other. |
| `wrappedkey_v0` needs TEE | Wrapped keys cannot be software-derived; without a working qseecomd path TWRP can only offer "format data". |
| AVB chaining (`avb=vbmeta` vs `avb`) | See `FSTAB-DIFF.md` F1/F2 — if `fs_mgr` cannot verify `vendor`, it may not even reach the crypto stage. |
| `metadata` layout | `keydirectory=/metadata/vold/metadata_encryption` must be readable *before* `/data` can be decrypted; that in turn needs `wrappedkey` on `/metadata`. |
| Anti-rollback | `PLATFORM_SECURITY_PATCH := 2099-12-31` is the usual workaround, but it can interact badly with ROM OTA logic. |

## 5. Suggested order of work

1. Get phase 1 booting and confirm the UI, MTP and ADB on hardware.
2. Dump the mars `vendor` blobs for the target ROM (start with LineageOS 23.2,
   since the kernel used here is built from the LOS 23.2 source).
3. Add the blobs + the `TW_INCLUDE_CRYPTO*` block, build, and check whether
   TWRP offers "Decrypt with password/PIN".
4. Only then try the other ROM (HyperOS 2) and see whether the same blobs work.
5. If cross-ROM decryption is impossible with one blob set, ship two recovery
   variants (`mars-lineage` / `mars-hyperos`) rather than fighting it.
