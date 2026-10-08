# Known issues, risks and open questions

Severity: **H** = can stop the build or the boot, **M** = degraded function,
**L** = cosmetic.

## Build / CI

| id | sev | issue | mitigation / status |
| --- | --- | --- | --- |
| **I1** | H | **Disk space on the runner.** The `nebrassy` twrp-14 manifest is a near-full AOSP 14 manifest. The workflow frees ~25 GB, but a pruned AOSP 14 tree plus `out/` may still exceed a stock runner. | The workflow has a `runner` input — switch to a larger runner (`ubuntu-latest-4-cores` or similar, 150 GB SSD) if the first run dies with `No space left on device`. |
| **I2** | H | **`repo sync` is slow.** 30–60 min on a cold cache, and it is the step most likely to time out. | `timeout-minutes: 350`; `.repo` caching is enabled but best-effort (see I3). `repo sync --force-sync` is resumable, so re-running the job loses less than it looks. |
| **I3** | M | `.repo` cache save may be rejected — GitHub caps caches at **10 GB per repository**, and `.repo/projects` + `.repo/project-objects` for this tree is likely larger. | The save steps are `continue-on-error: true`, and `prebuilts/` is cached separately (that one usually fits). A cache miss costs time only. |
| **I4** | M | First build is unverified end to end. Nothing has been compiled yet in this environment (the AOSP tree was never synced locally — by design, to protect the 46 GB of free disk). | Watch the first run; `docs/BUILD-STATUS.md` records the outcome. |
| **I5** | M | `openjdk-17` is installed for AOSP 14; if a manifest project still needs an older JDK the build will say so. | `apt-get install openjdk-11-jdk` alongside, or set `JAVA_HOME` to 11 for the offending module. |
| **I6** | L | `apt-get install neofetch` is in the dependency list because OrangeFox's scripts may print a banner with it. | Harmless if it is missing. |

## Device tree correctness

| id | sev | issue | mitigation / status |
| --- | --- | --- | --- |
| **I7** | H | **Kernel modules at recovery runtime.** The kernel is prebuilt, so no `.ko` is built or embedded. `TW_LOAD_VENDOR_MODULES` insmods `xiaomi_touch.ko` / `fts_touch_spi.ko` from the **installed ROM's** `/vendor/lib/modules`. | Works only if the ROM's modules match this kernel (vermagic / `CONFIG_MODVERSIONS`). **This is the main blocker for the cross-ROM goal** (HyperOS 2 ↔ LOS 23.2). Fix verified against the build system and against init: build the modules in `S0SL/android_kernel_xiaomi_sm8350` and ship them **inside the recovery ramdisk** via `BOARD_VENDOR_RAMDISK_KERNEL_MODULES` + `BOARD_VENDOR_RAMDISK_KERNEL_MODULES_LOAD` (not `..._RECOVERY_KERNEL_MODULES_LOAD`, which targets the vendor ramdisk this build never creates). Exact semantics, the config blocker (the current kernel build disables the mars touch driver) and the "a bad load list is fatal" hazard: [RAMDISK-MODULES.md](RAMDISK-MODULES.md). |
| **I8** | H | **Touch firmware borrowed from venus.** `firmware/st_fts_k2*.ftb` came from the OrangeFox venus tree, not from a mars ROM dump. | If touch does not come up, `adb pull /vendor/firmware/` from a mars device and replace the two `.ftb` files (they are also staged into the ramdisk at `recovery/root/lib/firmware/`). |
| **I9** | M | **No haptics** (`TW_NO_HAPTICS := true`), because the sm8350 AIDL vibrator HAL (`vendor.qti.hardware.vibrator.service.xiaomi_sm8350`) is not in this manifest. | Phase 1 acceptance; add the HAL package + blobs later and drop the flag. |
| **I10** | M | **`manifest.xml` is present but not wired** (`ODM_MANIFEST_FILES` unset). | Intentional: a HIDL manifest in a minimal recovery build is a common source of missing-dependency errors. Wire it up only if a HAL needs declaring. |
| **I11** | M | **`modules.load.recovery` is present but not wired**, because there are no built modules to copy. | Same fix as I7 — and note the wiring variable is `BOARD_VENDOR_RAMDISK_KERNEL_MODULES_LOAD`, with the module files supplied through `BOARD_VENDOR_RAMDISK_KERNEL_MODULES`. See [RAMDISK-MODULES.md](RAMDISK-MODULES.md) §3. |
| **I12** | M | **`/cust` partition may not exist** on every mars SKU. | TWRP renders a missing partition as unavailable; harmless. Verify `/dev/block/by-name/` on the device. |
| **I13** | L | **Brightness / GUI geometry values** (`TW_MAX_BRIGHTNESS`, `TW_DEFAULT_BRIGHTNESS`, `TW_FRAMERATE`, `OF_SCREEN_H`, `OF_STATUS_H`) are borrowed from other panels/trees. | Read the real values from the device and adjust. |
| **I14** | L | **No `TW_QCOM_ATS_OFFSET`.** The sm8350 references (TW-common, FOX-KOTAH-C) do not set it either, but vayu does. | If backup file timestamps look wrong, add a measured value. |
| **I15** | L | **`AB_OTA_UPDATER` is intentionally not set.** Setting it to `true` in A14 requires `AB_OTA_PARTITIONS`, otherwise the build errors out. | Not needed for a recovery-only build; the A/B behaviour comes from `slotselect` flags + `OF_AB_DEVICE=1`. |
| **I16** | H | **The QCOM display libraries cannot be built from source in this manifest.** `libdisplayconfig.qti`, `vendor.display.config@1.0`, `vendor.display.config@2.0` live in `vendor/qcom/opensource/commonsys-intf/display` (a CAF project). The fox_14.1 manifest (`nebrassy/platform_manifest_twrp_aosp`, `twrp-14`) has **1357 projects and none under `vendor/qcom`**. | `device.mk` now only adds them to `RECOVERY_LIBRARY_SOURCE_FILES` when `$(wildcard vendor/qcom/opensource/commonsys-intf/display)` is non-empty, and prints a build warning otherwise. Because the copy would otherwise be a hard install error, this is what keeps the build green. **If the recovery display does not come up, these three `.so` files must be extracted from a mars ROM and dropped into `recovery/root/vendor/lib64/`** — that is exactly how `OrangeFox/device/vayu` ships them. |

## Design-level risks

| id | sev | risk | comment |
| --- | --- | --- | --- |
| **R1** | H | **Recovery-as-boot replaces the normal boot ramdisk.** Once this `boot.img` is flashed, the device boots to recovery, not to Android. | This is inherent to "no recovery partition" + the requirement to ship a `boot.img`. To return to Android, re-flash the ROM's stock `boot.img` (or flash a ROM zip from recovery). Use `fastboot boot boot.img` first to try it **without** flashing. |
| **R2** | H | **LineageOS 23.2 itself puts recovery resources in `vendor_boot`**, not in `boot`: LOS-common sets `BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT := true` and does **not** set `BOARD_USES_RECOVERY_AS_BOOT`. | So on an Android 16 ROM the *native* recovery carrier is `vendor_boot`. The approach in this repo follows the 2021 TWRP tree and the explicit requirement to produce a `boot.img`. If `boot.img` recovery misbehaves on an Android 16 base, the fallback is to switch to `BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT := true` + `BOARD_INCLUDE_RECOVERY_RAMDISK_IN_VENDOR_BOOT := true` and flash `vendor_boot.img` — but that means preserving the dtb, which is a bigger change. |
| **R3** | M | **AVB chaining differences** between ROM generations (`avb=vbmeta` in LOS-23.2 vs plain `avb` in the 2021 tree). | See `FSTAB-DIFF.md` F1/F2. Only matters when `fs_mgr` is asked to verify those partitions. |
| **R4** | M | **Cross-ROM flashing is the stated goal but is the hardest part**: HyperOS 2 (Android 14) and LOS 23.2 (Android 16) have different keymaster HALs and different vendor module sets. | Phase 2 note: consider two recovery variants rather than one universal build. |
| **R5** | L | **No signature/keys.** The produced images use AVB test keys. | Fine for an unlocked bootloader; do not use for locked/relocked devices. |

## Non-goals in phase 1

* `/data` decryption (phase 2 — see `PHASE2-CRYPTO.md`).
* Building the kernel or its modules in this repository.
* Modifying `vendor_boot` or `dtbo`.
* Anything that writes to a device: this repo only produces artifacts.
