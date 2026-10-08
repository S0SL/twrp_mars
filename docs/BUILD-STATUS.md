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

## Run 2

| field | value |
| --- | --- |
| trigger | push of the run-1 fixes |
| runner | `ubuntu-22.04` |
| caches | prebuilts **hit**, `.repo` **hit** |
| expectation | sync 5–10 min (warm), build 30–60 min |
| status | see the Actions tab |

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
