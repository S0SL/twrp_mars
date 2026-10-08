# CI build status

Track record of the `Build OrangeFox recovery (mars)` workflow.
Updated by hand after each run.

## Run 1

| field | value |
| --- | --- |
| date (UTC) | 2026-10-08 |
| run | <https://github.com/S0SL/twrp_mars/actions/runs/37761738123> |
| commit | `3f65e53` (`main`) |
| trigger | `workflow_dispatch` |
| runner | `ubuntu-22.04` |
| status | **in progress** at the time of writing |
| artifacts | — |
| notes | First run, cold cache. Expected duration 1.5–2.5 h (sync 30–60 min + build 30–60 min). No cache exists yet, so `Restore .repo cache` is a guaranteed miss. |

### Run 1 — step log so far

| step | outcome |
| --- | --- |
| 1 Set up job | ✅ |
| 2 Free up disk space | ✅ (but see below — it was slow) |
| 3 Checkout device tree | ✅ |
| 4 Prepare build environment | ✅ |
| 5 Install build dependencies | ✅ (apt + Google's `repo` launcher) |
| 6 Restore prebuilts cache | ✅ miss (expected, first run) |
| 7 Restore .repo cache | ✅ miss (expected, first run) |
| 8 **Sync OrangeFox fox_14.1** | ▶️ running (30–60 min expected) |
| 9–17 | pending |

The fact that step 8 started at all is already a meaningful result: it proves the
corrected sync route (`scripts/fox-sync.sh` → `orangefox_sync.sh --branch 14.1`)
is accepted, and that the `repo init -b fox_14.1` in the original plan would
have been the wrong call.

**Fix applied after this observation:** the "Free up disk space" step originally
ended with `du -xh --max-depth=1 /`, which walks the entire runner filesystem and
took several minutes for no benefit. It was removed; `df -h` is enough. (This is
why step 2 looked slow in run 1.)

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
