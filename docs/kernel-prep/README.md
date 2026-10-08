# Kernel-repository preparation (NOT pushed, NOT applied)

This directory contains the *prepared* change to
`S0SL/android_kernel_xiaomi_sm8350` that makes the kernel build produce the
kernel modules the recovery needs to bring up touch and the panel. **Nothing
here has been pushed, and the kernel repository is untouched** (the local
checkout was used for a dry run and reverted byte-for-byte — `git status` is
empty, `git apply --check` on the patch passes).

The recovery-side half of the plan is
[../RAMDISK-MODULES.md](../RAMDISK-MODULES.md).

## Why this is needed

Two measurements, both from real artifacts (see
[../RAMDISK-MODULES.md](../RAMDISK-MODULES.md) §1.1):

* the ROM's `/vendor/lib/modules` can never load into our prebuilt `Image` —
  `CONFIG_LOCALVERSION_AUTO=y` bakes the build commit into `vermagic`
  (`5.4.302-qgki-g7ede20c8692e` for stock LineageOS 23.2 vs
  `5.4.302-qgki-g797c093f5b52` for our BakaSU `Image`), and
  `CONFIG_MODVERSIONS=y` with `# CONFIG_MODULE_FORCE_LOAD is not set`;
* the current kernel build produces **no mars touch driver at all**:
  `vendor/xiaomi_QGKI.config` sets `# CONFIG_TOUCHSCREEN_ST is not set` /
  `# CONFIG_TOUCHSCREEN_FTS is not set` and never enables
  `CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE`.

So `fastboot boot boot.img` (the way the first image will be tested) can have
touch/display only from modules built **in the same run as that `Image`**.

## What the change is

| file | change |
| --- | --- |
| `arch/arm64/configs/vendor/mars_recovery_touch.config` | **new**, 2 symbols: `CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI=m`, `CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE=m` |
| `ci/build-kernel.sh` | merge the new fragment; `MAKE_TARGET` default `Image` → `Image modules` |
| `ci/package-modules.sh` | **new**: `modules_install` + `dist/kernel-modules-<kver>.tar.gz`, and it hard-fails if `fts_touch_spi.ko`, `xiaomi_touch.ko` or `msm_drm.ko` is missing |
| `.github/workflows/build-kernel.yml` | run the packaging step and upload `dist/kernel-modules-*.tar.gz` with the existing assets |

### Measured side effect: none on the built-in kernel

The same merge chain `ci/build-kernel.sh` performs (base
`vendor/lahaina-qgki_defconfig`, then `vendor/debugfs.config` +
`vendor/xiaomi_QGKI.config`, then the new fragment, `olddefconfig` after each
step) was run with `O=/tmp/kout` — nothing in the kernel tree was modified. The
**complete** diff between the resulting `.config` before and after adding the
fragment is:

```diff
-# CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI is not set
+CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI=m
-# CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE is not set
+CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE=m
```

No `=y` symbol changes and no `select` is triggered: both Kconfig entries are
plain `tristate` with `depends on I2C` / `depends on INPUT_TOUCHSCREEN` (already
satisfied). The drivers are currently absent and supplied by the ROM; making
them `=m` only means **our** build also produces two `.ko` files. The built-in
part of `Image` is unaffected.

## How to apply (after approval)

```sh
git clone https://github.com/S0SL/android_kernel_xiaomi_sm8350
cd android_kernel_xiaomi_sm8350

# option A -- the patch
git am /path/to/0001-mars-touch-modules.patch        # or: git apply + commit

# option B -- the script (idempotent; --revert undoes it)
/path/to/docs/kernel-prep/apply-kernel-prep.sh --target .
git diff --stat && git add -A && git commit
```

Then push. The existing kernel CI (`.github/workflows/build-kernel.yml`) builds
`Image modules` and uploads `kernel-modules-<kver>.tar.gz` next to the
AnyKernel3 zip and the fastboot-flashable `boot.img`.

## How to verify the run

```sh
# after the kernel CI run, on the artifact:
tar tzf kernel-modules-*.tar.gz | grep -E 'fts_touch_spi\.ko|xiaomi_touch\.ko|msm_drm\.ko'
tar xzf kernel-modules-*.tar.gz
strings fts_touch_spi.ko | grep vermagic      # must equal the Image's version
strings Image | grep -m1 'Linux version'
```

The two version strings must be identical — that is exactly what makes the
modules loadable into the `Image` produced by the same run.

## Follow-up in this repository (not written yet, by design)

Once the tarball exists:

1. `scripts/fetch-modules.sh` — download the tarball next to the kernel
   `Image`, verify the `.ko` count and the `vermagic` string.
2. CI: `depmod -b <staging> <kver>` over the extracted tree.
3. Copy the `.ko` files **and** `modules.dep` / `modules.alias` /
   `modules.softdep` into `recovery/root/lib/modules/` — deliberately **no**
   `modules.load` and **no** `modules.load.recovery`, so first-stage init never
   tries to load them and TWRP's tolerant loader can fall back to the ROM's
   modules when the recovery runs on a ROM kernel (the OrangeFox installer
   path). See [../RAMDISK-MODULES.md](../RAMDISK-MODULES.md) §3.1 and the
   warning in the top-level README.
