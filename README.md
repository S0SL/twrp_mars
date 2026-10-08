# twrp_mars — OrangeFox recovery for the Xiaomi Mi 11 Pro (mars)

Device tree + cloud CI for an **OrangeFox Recovery** build (base: `fox_14.1`)
for the **Xiaomi Mi 11 Pro**, codename **`mars`**, SoC **Qualcomm sm8350
(Snapdragon 888)**, **A/B**, **no dedicated recovery partition**.

> Status: **phase 1** — build the recovery, get the UI up, flash zips,
> back up / restore partitions, MTP + ADB.
> **Decrypting `/data` is explicitly out of scope** (that is phase 2, see
> [docs/PHASE2-CRYPTO.md](docs/PHASE2-CRYPTO.md)).

Nothing in this repository flashes anything to a device by itself.

---

## 1. What you get

The recovery is built **into `boot.img`** (`BOARD_USES_RECOVERY_AS_BOOT`),
because mars has no `recovery` partition. `vendor_boot` is left untouched.

Artifacts of a successful build (`out/target/product/mars/`):

| file | what it is |
| --- | --- |
| `boot.img` | kernel + OrangeFox recovery ramdisk — this is the image you flash |
| `recovery.img` | side product of the same ramdisk (do **not** flash on mars) |
| `OrangeFox-<ver>-<type>-mars.img` | OrangeFox's copy of `boot.img` |
| `OrangeFox-<ver>-<type>-mars.zip` | OrangeFox's flashable installer zip |

Flash (unlocked bootloader):

```sh
fastboot flash boot boot.img
# or, from within an existing recovery:
#   install OrangeFox-*-mars.zip
```

---

## 2. Repository layout

This repository **is** the device tree. That follows the TWRP convention, so
`repo`/`git clone` can drop it straight into `device/xiaomi/mars`:

```
BoardConfig.mk           # board config: A/B, recovery-as-boot, prebuilt kernel, TW_ switches
twrp_mars.mk             # PRODUCT_NAME := twrp_mars   (lunch: twrp_mars-ap2a-eng)
fox_mars.mk              # OrangeFox OF_* switches
device.mk                # product config: recovery modules, touch firmware, crypto off
AndroidProducts.mk       # PRODUCT_MAKEFILES + COMMON_LUNCH_CHOICES
Android.mk
vendorsetup.sh           # OrangeFox environment (FOX_BUILD_DEVICE=mars, ...)
board-info.txt
manifest.xml             # retained from the 2021 TWRP tree; NOT wired up in phase 1
modules.load.recovery    # reference list of modules the recovery wants; NOT wired up in phase 1
firmware/                # FTS touch panel firmware (also staged into the ramdisk below)
recovery/root/           # merged into the recovery ramdisk root
  system/etc/recovery.fstab   # TARGET_RECOVERY_FSTAB
  system/etc/twrp.flags       # backup / flash / display flags
  ueventd.qcom.rc
  init.recovery.qcom.rc
  lib/firmware/st_fts_k2*.ftb # touch firmware inside the ramdisk
prebuilt/                # kernel Image lands here at build time (git-ignored)
scripts/fetch-kernel.sh  # downloads / extracts the prebuilt kernel Image
scripts/fetch-modules.sh # (prepared) downloads the matching touch/display .ko set
scripts/fox-sync.sh      # the CORRECT fox_14.1 sync procedure
scripts/check-tree.sh    # static validation of the tree (no AOSP needed)
docs/                    # provenance, fstab diff, known issues, phase-2 notes
docs/RAMDISK-MODULES.md  # plan: build touch/display .ko into the recovery ramdisk (I7/I11)
.github/workflows/build-recovery.yml
```

`recovery/root/` is picked up automatically: the TWRP-patched build system uses
`$(TARGET_DEVICE_DIR)/recovery/root` when `TARGET_RECOVERY_DEVICE_DIRS` is unset
(`build/make/core/Makefile`, `recovery_root_private`).

---

## 3. Building

### 3.1 On CI (recommended)

`.github/workflows/build-recovery.yml`, manual trigger:

* **Actions → "Build OrangeFox recovery (mars)" → Run workflow**

Inputs: `fox_branch` (fixed to `14.1`), `kernel_url`, `build_type`, `runner`.

Timing on a stock `ubuntu-22.04` GitHub runner:

| stage | expected |
| --- | --- |
| apt + `repo` install | 2–4 min |
| `repo sync` (cold, no cache) | **30–60 min** |
| device tree + kernel install | < 1 min |
| `mka recoveryimage` | **30–60 min** |
| **total** | **~1.5–2.5 h cold**, ~1 h warm |

Job timeout is set to 350 minutes. The first run has no cache, so budget the
full number above.

### 3.2 Static checks (no AOSP tree needed)

```sh
./scripts/check-tree.sh
```

Validates that every file the build system looks for exists, that
`recovery.fstab` is a well-formed fs_mgr fstab with only known flags, that
`twrp.flags` is well-formed, that makefile conditionals balance, that the
workflow is valid YAML, and that no build-host path or wrong codename leaked in.

### 3.3 Locally

You need ~120 GB free and a Linux box; a full Android 14 tree is involved.

```sh
export FOX_DIR=$HOME/fox_14.1
./scripts/fox-sync.sh "$FOX_DIR"

./scripts/fetch-kernel.sh "" "$FOX_DIR/device/xiaomi/mars/prebuilt/Image"
rsync -a --exclude '.git/' --exclude '.github/' --exclude 'scripts/' \
         --exclude 'docs/' ./ "$FOX_DIR/device/xiaomi/mars/"

cd "$FOX_DIR"
export LC_ALL=C FOX_BUILD_DEVICE=mars FOX_BUILD_TYPE=Unofficial
export ALLOW_MISSING_DEPENDENCIES=true
source build/envsetup.sh
lunch twrp_mars-ap2a-eng
mka recoveryimage
# -> out/target/product/mars/boot.img
```

### 3.4 Why `scripts/fox-sync.sh` and not `repo init -b fox_14.1`

`git ls-remote --heads https://gitlab.com/OrangeFox/sync.git` returns **only
`refs/heads/master`** — there is no `fox_14.1` branch on the sync repo, so

```sh
repo init -u https://gitlab.com/OrangeFox/sync.git -b fox_14.1   # FAILS
```

is not a valid command. `fox_14.1` is a *legacy* OrangeFox branch: the
supported flow is `orangefox_sync.sh --branch 14.1`, which this repository
wraps in `scripts/fox-sync.sh`. See [docs/PROVENANCE.md](docs/PROVENANCE.md) §4.

### 3.5 The lunch target

```sh
lunch twrp_mars-ap2a-eng
```

**Three parts are mandatory.** The `build/make` fork that fox_14.1 uses
(`nebrassy/android_build`, `android-14`) enforces this at the top of `lunch()`:

```sh
# This must be <product>-<release>-<variant>
IFS="-" read -r product release variant <<< "$selection"
if [[ -z "$product" ]] || [[ -z "$release" ]] || [[ -z "$variant" ]]
then
    echo "Invalid lunch combo: $selection"
    echo "Valid combos must be of the form <product>-<release>-<variant>"
    return 1
fi
```

So the historical two-part `twrp_mars-eng` splits into
`product=twrp_mars, release=eng, variant=<empty>` and is **always rejected**.
This is why OrangeFox's own fox_16.0 documentation says
`lunch twrp_mondrian-bp2a-eng`, and why `OrangeFox/device/vayu`'s
`COMMON_LUNCH_CHOICES := twrp_vayu-eng` (fox_14.1) is stale — that entry cannot
work on this build system either.

`ap2a` is this manifest's release token (the OrangeFox sync
script pins `android14-qpr3-release` for the projects it re-clones). The CI
probes `bp2a ap2a ap3a udc trunk_staging` before giving up, so a rename in a
future manifest will not need a code change.

Despite the OrangeFox branding, `PRODUCT_NAME` stays `twrp_<device>` — the
reference tree `OrangeFox/device/vayu` (branch `fox_14.1`) declares
`PRODUCT_NAME := twrp_vayu`.

---

## 4. Kernel and dtb

The kernel is **prebuilt** (`TARGET_PREBUILT_KERNEL := prebuilt/Image`), taken
from the companion kernel project
[S0SL/android_kernel_xiaomi_sm8350](https://github.com/S0SL/android_kernel_xiaomi_sm8350).
`scripts/fetch-kernel.sh` either extracts `Image` from an AnyKernel3 release zip
or downloads a raw `Image`.

**No dtb or dtbo is required.** `boot` header v3 has no dtb field — on mars the
dtb lives in `vendor_boot`, which this project never touches. Verified: the
official LineageOS 23.2 `boot.img` unpacks to exactly `kernel` + `ramdisk.cpio`
with `HEADER_VER [3]`. Consequently `BOARD_INCLUDE_DTB_IN_BOOTIMG` is
deliberately **not** set.

---

## 5. Current progress

| item | state |
| --- | --- |
| Device tree synthesised | done |
| `recovery.fstab` / `twrp.flags` | done, mars-specific |
| CI workflow | done |
| Pushed to GitHub | see the workflow run linked in the release/README history |
| First CI build | see [docs/BUILD-STATUS.md](docs/BUILD-STATUS.md) |
| Touch/display `.ko` in the ramdisk (I7/I11) | plan written, **not applied** — needs a kernel-repo change: [docs/RAMDISK-MODULES.md](docs/RAMDISK-MODULES.md) |
| Verified booting on hardware | **not yet** — nothing was flashed |
| `/data` decryption | not started (phase 2) |

---

## 6. Known issues (short list)

1. **Touch firmware is borrowed from `venus`.** `st_fts_k2*.ftb` came from the
   OrangeFox venus tree; they have not been confirmed against a mars ROM dump.
2. **Touch/display modules come from the installed ROM**, because the kernel is
   prebuilt and no `.ko` is compiled. They only load if the ROM's modules match
   the kernel (`CONFIG_MODVERSIONS` / vermagic) — which is exactly why
   cross-ROM (HyperOS 2 ↔ LineageOS 23.2) flashing is the riskiest goal.
   Building and embedding the modules is the fix; see
   [docs/RAMDISK-MODULES.md](docs/RAMDISK-MODULES.md).
3. **⚠ Never ship a `modules.load.recovery` (or `modules.load`) inside the
   recovery ramdisk that lists more modules than are actually present and
   loadable.** In recovery mode AOSP's first-stage init
   (`system/core/init/first_stage_init.cpp`) prefers `modules.load.recovery`,
   and `libmodprobe` returning `false` for a single module makes init
   `LOG(FATAL) << "Failed to load kernel modules"` — the image then does not
   boot at all. TWRP's own loader tolerates failures; init's does not.
   Concretely: derive any load list from the packaged `.ko` set, and prefer the
   no-load-list design in [docs/RAMDISK-MODULES.md](docs/RAMDISK-MODULES.md)
   §3.1, which also keeps the OrangeFox-installer path (recovery running on the
   *ROM's* kernel) working.
4. **No haptics** in phase 1 (`TW_NO_HAPTICS := true`), to avoid pulling in the
   sm8350 AIDL vibrator HAL.
5. **No crypto**: `/data` will show as unencrypted-but-unmountable. By design.
6. `.repo` cache save is best-effort; GitHub's 10 GB per-repo cache limit may
   reject it.

Full list and the risk table: [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md).

---

## 7. Documentation index

* [docs/PROVENANCE.md](docs/PROVENANCE.md) — per-file origin (LineageOS /
  TeamWin / OrangeFox / newly written) and every open question.
* [docs/FSTAB-DIFF.md](docs/FSTAB-DIFF.md) — LineageOS vs TWRP diffs for the
  same-named files, and the crypto-relevant differences.
* [docs/PHASE2-CRYPTO.md](docs/PHASE2-CRYPTO.md) — what phase 2 has to solve.
* [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) — risks and open questions.
* [docs/RAMDISK-MODULES.md](docs/RAMDISK-MODULES.md) — plan for building the
  touch/display `.ko` into the recovery ramdisk (I7/I11), with the kernel-side
  patch prepared in [docs/kernel-prep/](docs/kernel-prep/README.md).
* [docs/BUILD-STATUS.md](docs/BUILD-STATUS.md) — CI run history.
