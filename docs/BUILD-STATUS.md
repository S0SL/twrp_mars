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

**Fixed.** The target is now the three-part `twrp_mars-bp2a-eng`:

* `AndroidProducts.mk` declares `twrp_mars-bp2a-eng` / `twrp_mars-bp2a-userdebug`.
* The CI probes `bp2a ap2a ap3a udc trunk_staging` and lunches the first combo
  that works, so a release-token rename does not need a code change.
* `scripts/check-tree.sh` fails if any declared choice is not three-part.

`bp2a` is the Android 14 QPR3 release token used by this manifest; OrangeFox's
own fox_16.0 README documents `lunch twrp_mondrian-bp2a-eng`, and the sync
script pins `android14-qpr3-release`.

## Run 5

| field | value |
| --- | --- |
| trigger | push of the lunch-combo fix |
| caches | warm (sync ~10 min) |
| expectation | first run that reaches a real compile: 30–60 min for `mka recoveryimage` |

### What to look at if run 5 fails

| symptom | likely cause | action |
| --- | --- | --- |
| `No space left on device` | I1 in `KNOWN_ISSUES.md` | re-run with `runner: ubuntu-latest-4-cores` |
| `repo init` / `repo sync` failure | upstream manifest or network flake | re-run; the sync is `--force-sync` and resumable |
| `Failed to patch the twrp-14 minimal manifest` | upstream `build/make` moved and the OrangeFox patch no longer applies | bump the `OrangeFox/sync` clone (it applies the same patches) |
| missing `libdisplayconfig.qti` / `vendor.display.config@*` | no CAF display project in the manifest | already guarded (I16); supply the `.so` files as prebuilts if the display stays dark |
| `vendor/recovery/OrangeFox_A14.sh` aborts with `abort 100` | build system not patched (wrong sync route) | verify `scripts/fox-sync.sh` was used, never `repo init -b fox_14.1` |
| any valid combo is rejected | release token renamed upstream | add candidates to the probe list in the workflow |

### Aborted attempts before run 1

Two runs were started at 10:07 UTC and both ended `cancelled`, because a
`workflow_dispatch` run and a `push` run share the concurrency group
(`${{ github.workflow }}-${{ github.ref }}`) and `cancel-in-progress: true`
made them kill each other. Cancelling the loser left neither running.

Consequences, both applied:

* `concurrency.cancel-in-progress` is now **`false`**: for a ~2 hour build it is
  much better for a new push to queue behind the running build than to silently
  destroy it. GitHub keeps only the newest pending run per group, so repeated
  pushes do not pile up.
* **Do not push while a build is running** unless you intend to queue another
  one, and use `[skip ci]` in the commit message for documentation-only fixes
  (`docs/**` and `**.md` are already in `paths-ignore`).

### What to look at if it fails

| symptom | likely cause | action |
| --- | --- | --- |
| `No space left on device` during sync or build | I1 in `KNOWN_ISSUES.md` | re-run with `runner: ubuntu-latest-4-cores` (or any 150 GB runner) |
| `repo init` / `repo sync` failure | upstream manifest or network flake | re-run; the sync is `--force-sync` and resumable |
| `Failed to patch the twrp-14 minimal manifest` | upstream `build/make` moved; the OrangeFox patch no longer applies | bump to a newer `master` of `OrangeFox/sync` (it applies the same patches) |
| `error: ... not found` for `libdisplayconfig.qti` / `vendor.display.config@*` | manifest does not build those from source | add the missing project to the sync, or drop those entries from `TARGET_RECOVERY_DEVICE_MODULES` |
| build fails inside `vendor/recovery/OrangeFox_A14.sh` with `abort 100` | the build system was not patched (wrong sync route) | verify `scripts/fox-sync.sh` was used — not `repo init -b fox_14.1` |
| `lunch: twrp_mars-eng not found` | device tree not in `device/xiaomi/mars` | check the "Install device tree" step log |
