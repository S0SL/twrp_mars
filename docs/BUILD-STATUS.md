# CI build status

Track record of the `Build OrangeFox recovery (mars)` workflow.
Updated by hand after each run.

## Run 1 — RESULT: build failed, diagnosed and fixed

Full run: <https://github.com/S0SL/twrp_mars/actions/runs/37761738123> (commit `3f65e53`)

| step | outcome | duration |
| --- | --- | --- |
| 1 Set up job | ✅ | |
| 2 Free up disk space | ✅ | ~3 min (had the slow `du`; removed afterwards) |
| 3 Checkout device tree | ✅ | |
| 4 Prepare build environment | ✅ | |
| 5 Install build dependencies | ✅ | ~1 min |
| 6 Restore caches | ✅ miss (first run) | |
| 7 **Sync OrangeFox fox_14.1** | ✅ | **~19 min** (10:14 → 10:33) |
| 8 Save prebuilts cache | ✅ | ~5 min |
| 9 Save .repo cache | ✅ | ~5 min |
| 10 Fetch prebuilt kernel Image | ✅ | |
| 11 Install device tree | ✅ | |
| 12 **Build recoveryimage** | ❌ | ~5 min |
| 13–17 | skipped / log only | |

### What worked

* The corrected sync route is confirmed: `scripts/fox-sync.sh` →
  `orangefox_sync.sh --branch 14.1` synced the whole tree, applied the
  `build/make`, `system/vold`, `remove-minimal.xml` and `system/update_engine`
  patches, cloned OrangeFox's recovery + vendor trees, `device/qcom/common`,
  `device/qcom/twrp-common` and `external/se_omapi` — **in 19 minutes**, much
  faster than the 30–60 min estimate.
* No disk-space failure: the `ubuntu-22.04` runner was enough for the sync.
* Both caches saved successfully (so run 2 starts warm).
* `prebuilt/Image` was fetched from the kernel project's AnyKernel3 release and
  passed the arm64-magic check.
* The device tree installed into `device/xiaomi/mars` correctly.

### Failure 1 — `set -u` broke AOSP's envsetup (the immediate cause of the failure)

```
build/envsetup.sh: line 21: TOP: unbound variable
```

`build/envsetup.sh` (and much of AOSP's shell code) dereferences unset
variables. The build step used `set -euo pipefail`, so sourcing it aborted
immediately — before `lunch`, before any compile. The build "failed" in 5
minutes because it never started.

**Fixed:** the build step now uses `set -eo pipefail` (no `-u`), tolerates
`envsetup.sh`'s return value, and then explicitly verifies that `lunch` exists
and that `lunch twrp_mars-eng` succeeds. `scripts/check-tree.sh` now has a
regression guard that parses the option cluster (note: `"-u"` is *not* a
substring of `"-euo"`, which is why the first version of the guard silently
passed — both cases are now covered).

### Failure 2 — upstream `orangefox_sync.sh` looks for the vendor/twrp patch in the wrong place

```
./orangefox_sync.sh: line 248: /tmp/tmp.../sync/patch-vendor-twrp-fox_14.1.diff: No such file or directory
-- Error! Failed to patch the twrp-14 vendor/twrp !
```

`update_environment()` sets `PATCH_VENDOR_TWRP="$BASE_DIR/patch-vendor-twrp-$FOX_DEF_BRANCH.diff"`
but the file ships in `$BASE_DIR/patches/`. `init_script()` only validates
`$PATCH_FILE`, so this is a **silent** failure: the script prints the error and
continues with `vendor/twrp` unpatched.

That patch is not cosmetic — it adds

```make
include bootable/recovery/orangefox_soong.mk
```

to `vendor/twrp/config/BoardConfigSoong.mk`, i.e. it is what pulls OrangeFox's
Soong configuration into the build, and it also registers the `tw_no_haptics`
Soong variable that `TW_NO_HAPTICS := true` relies on.

**Fixed:** `scripts/fox-sync.sh` now copies
`patches/patch-vendor-twrp-fox_14.1.diff` to where the script looks for it
before running it (upstream is not modified), and then *verifies* the result:
it fails fast if `orangefox_soong.mk` is not included, or if
`bootable/recovery/orangefox.mk`, `vendor/recovery/OrangeFox_A14.sh`,
`vendor/twrp/config/common.mk`, `device/qcom/common`, `device/qcom/twrp-common`
or `external/se_omapi` are missing.

## Runs 2, 3 and 4

| run | commit | outcome |
| --- | --- | --- |
| 2 | `1042923` | **cancelled on purpose.** It carried the `envsetup -u` and vendor/twrp-patch fixes but not the display-lib guard; it then stalled 10+ minutes in `Install build dependencies`, so it was cancelled to free the runner for run 4, which had every fix. |
| 3 | `b16ac85` | **cancelled** — it was still pending when run 4 was pushed, and GitHub keeps only the newest pending run per concurrency group. |
| 4 | `38e8a50` | **build failed again — diagnosed and fixed (see below).** All 12 steps before the build passed. |

### Run 4 — what the previous fixes achieved

| step | outcome | note |
| --- | --- | --- |
| 5 Install build dependencies | ✅ | **~50 s** once the apt list was split into tiers (was 10+ min stalled in run 2) |
| 8 Sync OrangeFox fox_14.1 | ✅ | **~10 min** |
| 9/10 Save caches | ✅ | |
| 11 Fetch prebuilt kernel | ✅ | |
| 12 Install device tree | ✅ | |
| 13 Build recoveryimage | ❌ | see below |

So the `set -u` fix worked — `build/envsetup.sh` sourced cleanly and defined
`lunch()` — as did the vendor/twrp patch workaround and the display-lib guard.

### Failure 3 — `lunch` requires THREE parts, so `twrp_mars-eng` can never work

```
including device/xiaomi/mars/vendorsetup.sh
Invalid lunch combo: twrp_mars-eng
Valid combos must be of the form <product>-<release>-<variant>
ERROR: 'lunch twrp_mars-eng' failed.
```

`build/make/envsetup.sh` in the fox_14.1 fork (`nebrassy/android_build`,
`android-14`) enforces this at the top of `lunch()`:

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

`twrp_mars-eng` yields `product=twrp_mars, release=eng, variant=<empty>`, so it
is rejected **before** the product is even looked up. This was not a device-tree
bug: the ticket's suggested target (and OrangeFox's own `twrp_vayu-eng` in
`OrangeFox/device/vayu` fox_14.1, and even the test build inside
`orangefox_sync.sh`) is wrong for this build system.

**Fixed.** The target is now the three-part `twrp_mars-ap2a-eng`:

* `AndroidProducts.mk` declares `twrp_mars-ap2a-eng` / `twrp_mars-ap2a-userdebug`.
* The CI probes `bp2a ap2a ap3a udc trunk_staging` and lunches the first combo
  that works, so a release-token rename does not need a code change.
* `scripts/check-tree.sh` fails if any declared choice is not three-part.

`bp2a` is the Android 14 QPR3 release token used by this manifest; OrangeFox's
own fox_16.0 README documents `lunch twrp_mondrian-bp2a-eng`, and the sync
script pins `android14-qpr3-release`.

## Run 5 — RESULT: failed, two more causes found

Run: <https://github.com/S0SL/twrp_mars/actions/runs/37769569262> (commit `b376e67`)

Steps 1–12 all passed again (sync ~19 min, caches saved). The build step failed
in ~30 s.

```
-- not a valid combo here: twrp_mars-bp2a-eng
-- not a valid combo here: twrp_mars-ap2a-eng
-- not a valid combo here: twrp_mars-ap3a-eng
-- not a valid combo here: twrp_mars-udc-eng
-- not a valid combo here: twrp_mars-trunk_staging-eng
ERROR: no valid <product>-<release>-<variant> combo for twrp_mars.
build/make/core/release_config.mk:145: error: No release config found for
    TARGET_RELEASE: bp2a. Available releases are: ap2a.
** Don't have a product spec for: 'twrp_mars'
```

### Cause 4 — the release token is `ap2a`, not `bp2a`

The error message names it outright. Release names come from
`release_config_map.mk` files discovered as
`build/release/release_config_map.mk` or
`device/*/*/release/release_config_map.mk` (`core/release_config.mk`), and this
manifest's set is just `ap2a` (Android 14 QPR2).

`bp2a` was my inference from OrangeFox's **fox_16.0** README
(`lunch twrp_mondrian-bp2a-eng`) — correct for Android 16, wrong here.
`ap2a` is now the first candidate and the value declared in
`COMMON_LUNCH_CHOICES`.

### Cause 5 — the release list was guessed; now it is probed *and reported*

Run 5's probe redirected each attempt to `/dev/null`, so the real error for the
valid release (`ap2a`) was thrown away — only `bp2a`'s error survived. The probe
now captures and prints the tail of every failed attempt, and additionally
prints:

* the number of entries in `out/.module_paths/AndroidProducts.mk.list` and any
  `xiaomi`/`mars` entry in it — this is how the build system discovers
  `AndroidProducts.mk` (`core/product_config.mk`:
  `$(file <$(OUT_DIR)/.module_paths/AndroidProducts.mk.list)`), so a missing
  entry means the device tree is invisible to the build;
* a listing of `device/xiaomi/mars/`.

The `** Don't have a product spec for: 'twrp_mars'` line is **not yet
explained**: it may be a mere consequence of the `bp2a` release error, or it may
mean the product is not being registered. Run 6 will tell us which, because it
now prints the discovery list. If the list has no mars entry, the next fix is to
make the tree visible to Soong (and `COMMON_LUNCH_CHOICES` would then also have
raised "contains products(s) not defined in this file" — worth watching for).

## Run 6 — in flight when the build container lost network

Run: <https://github.com/S0SL/twrp_mars/actions/runs/37773718753> (commit `dbe3283`)

| step | outcome |
| --- | --- |
| 1–7 | ✅ |
| 8 Sync OrangeFox fox_14.1 | ✅ |
| 9 Save prebuilts cache | ✅ |
| 10 Save .repo cache | ✅ (per the 12:12:51 poll) |
| 11–13 | not observed: **this container lost all network access at ~12:17 UTC** (`curl https://api.github.com` → `000`, `example.com` → `000`), so the run could not be polled any further |

**Please check the run page directly.** The interesting output is at the
`Build recoveryimage` step: it now prints, before attempting any lunch combo,

* the line count of `out/.module_paths/AndroidProducts.mk.list` and any
  `xiaomi`/`mars` entry in it,
* a listing of `device/xiaomi/mars/`,
* the tail of every failed `lunch twrp_mars-<release>-eng` attempt,

with `ap2a` tried first. That answers the one open question: whether
`** Don't have a product spec for: 'twrp_mars'` was merely fallout from the wrong
release token, or whether the device tree is not being discovered at all.

### If the product is confirmed missing

Then `core/product_config.mk` is not reading this tree, because
`android_products_makefiles` only contains
`$(file <$(OUT_DIR)/.module_paths/AndroidProducts.mk.list)` — a list produced by
Soong's finder. Next things to try, in order:

1. run `mka` once with `--dumpvars-mode` / check whether the finder prunes
   `device/` in this manifest;
2. compare against a device tree known to build on fox_14.1
   (`OrangeFox/device/mondrian` on fox_16.0, or any fox_14.1 tree) to see whether
   something else registers the product;
3. as a fallback, set `TARGET_PRODUCT`/`TARGET_RELEASE`/`TARGET_BUILD_VARIANT`
   explicitly instead of relying on `lunch` — but `lunch` is the documented
   interface, so this is a workaround, not a fix.

