# CI build status

Track record of the `Build OrangeFox recovery (mars)` workflow.
Updated by hand after each run.

## Run 1

| field | value |
| --- | --- |
| date (UTC) | 2026-10-08 |
| commit | *(see the run)* |
| trigger | `workflow_dispatch` |
| runner | `ubuntu-22.04` |
| status | see the repository's Actions tab |
| artifacts | — |
| notes | First run, cold cache. Expected duration 1.5–2.5 h (sync 30–60 min + build 30–60 min). No cache exists yet, so `Restore .repo cache` is a guaranteed miss. |

### What to look at if it fails

| symptom | likely cause | action |
| --- | --- | --- |
| `No space left on device` during sync or build | I1 in `KNOWN_ISSUES.md` | re-run with `runner: ubuntu-latest-4-cores` (or any 150 GB runner) |
| `repo init` / `repo sync` failure | upstream manifest or network flake | re-run; the sync is `--force-sync` and resumable |
| `Failed to patch the twrp-14 minimal manifest` | upstream `build/make` moved; the OrangeFox patch no longer applies | bump to a newer `master` of `OrangeFox/sync` (it applies the same patches) |
| `error: ... not found` for `libdisplayconfig.qti` / `vendor.display.config@*` | manifest does not build those from source | add the missing project to the sync, or drop those entries from `TARGET_RECOVERY_DEVICE_MODULES` |
| build fails inside `vendor/recovery/OrangeFox_A14.sh` with `abort 100` | the build system was not patched (wrong sync route) | verify `scripts/fox-sync.sh` was used — not `repo init -b fox_14.1` |
| `lunch: twrp_mars-eng not found` | device tree not in `device/xiaomi/mars` | check the "Install device tree" step log |
