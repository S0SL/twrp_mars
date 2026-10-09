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

## Run 6 — RESULT: failed at `lunch`; cause 6 found and fixed

Run: <https://github.com/S0SL/twrp_mars/actions/runs/37773718753> (commit `dbe3283`)

| step | outcome |
| --- | --- |
| 1–7 | ✅ |
| 8 Sync OrangeFox fox_14.1 | ✅ |
| 9 Save prebuilts cache | ✅ |
| 10 Save .repo cache | ✅ |
| 11 Fetch prebuilt kernel Image | ✅ |
| 12 Install device tree into `device/xiaomi/mars` | ✅ |
| 13 Build recoveryimage (→ boot.img) | ❌ after ~1 min |
| 14–17 | log only / skipped |

Polling stopped at 12:17 UTC when this container lost outbound network access;
the job log was retrieved after it came back (`completed failure`, 12:53).

The verbose probe answered the open question, and the answer was neither of the
two candidates: it is **not** a release-token problem and **not** a
product-discovery problem. `ap2a` — the only release this manifest defines —
got all the way into the product config and failed there:

```
-- not a valid combo here: twrp_mars-ap2a-eng
     | In file included from build/make/core/envsetup.mk:386:
     | In file included from build/make/core/board_config.mk:241:
     | device/xiaomi/mars/BoardConfig.mk:124: error: BOARD_BUILD_SYSTEM_ROOT_IMAGE is obsolete.
     | 12:19:48 dumpvars failed with: exit status 1
     | Device mars not found. Attempting to retrieve device repository from TeamWin Github ...
     | ** Don't have a product spec for: 'twrp_mars'
```

So `** Don't have a product spec` was fallout, not the cause: `dumpvars` died
first, `check_product` therefore reported the device as missing (which is what
sends `lunch` off to `roomservice.py` and its TeamWin GitHub lookup), and
`build_build_var_cache` then failed for the same reason. The AndroidProducts
diagnostic printed "does not exist" simply because Soong never got far enough to
write `out/.module_paths/AndroidProducts.mk.list`.

### Cause 6 — an obsolete board variable is a hard error in this build system

`build/make/core/config.mk:174` contains

```make
$(KATI_obsolete_var BOARD_BUILD_SYSTEM_ROOT_IMAGE)
```

and Kati turns *any* assignment of a variable declared that way into a hard
error. `BoardConfig.mk:124` still carried
`BOARD_BUILD_SYSTEM_ROOT_IMAGE := false` — a leftover from the 2021 TeamWin
tree; Android 14 system-as-root needs nothing there.

**Fixed** by deleting the line (and the deprecated
`TARGET_USES_64_BIT_BINDER := true`, which the same log flagged).

To avoid spending another run on the same class of error, the complete obsolete
list was extracted from the fork's `build/make`
(`core/*.mk`, every `$(KATI_obsolete_var ...)` including its multi-line forms) and
cross-checked against every `*.mk` in this tree: **148 names, exactly one of them
set — the one above**. That list is now `scripts/obsolete-build-vars.txt`, and
`scripts/check-tree.sh` fails if any of them reappears (negative-tested: putting
the line back makes the checker fail).

**The "product discovery" question is closed:** the tree *is* discovered — the
run printed `device/xiaomi/mars/AndroidProducts.mk` in the listing and
`dumpvars` failed on the board variable, not on the product. No
`TARGET_PRODUCT`-env workaround is needed.


## Offline work while runs 6/7 could not be polled (12:17 UTC onwards)

The build container lost all outbound network access at ~12:17 UTC, so CI could
not be polled. The following was prepared locally in that window; none of it
changes what CI builds until the kernel-side release exists.

| item | evidence |
| --- | --- |
| `TW_LOAD_VENDOR_MODULES` corrected to LineageOS' eleven-name mars list, `msm_drm.ko` added | every name resolved in this kernel's Makefiles: `qti_battery_charger_main.ko` (`drivers/power/supply/Makefile:95`), `hwid.ko` (`drivers/misc/Makefile:68`), `xiaomi_touch.ko` / `fts_touch_spi.ko` (their `Makefile:2`); display is a module for lahaina (`techpack/display/config/gki_lahainadisp.conf:12`), and TWRP loads modules before `gui_init()` (`twrp.cpp:539` vs `:549`) |
| Measured: the ROM's modules can never load into our `Image` | `CONFIG_LOCALVERSION_AUTO=y` → stock LOS `…-g7ede20c8692e` vs our `…-g797c093f5b52`; `CONFIG_MODVERSIONS=y`; `MODULE_FORCE_LOAD` unset; the AnyKernel3 releases ship no modules |
| Shipping design fixed: `.ko` + depmod output in `recovery/root/lib/modules`, **no** `modules.load*` | first-stage init `LOG(FATAL)`s on the first unloadable entry in `modules.load.recovery` (`first_stage_init.cpp` + `libmodprobe` `LoadListedModules`), which would break the OrangeFox-installer path; TWRP's loader tolerates failures and falls through to the ROM's modules |
| Kernel change prepared, dry-run verified, **not pushed** | `docs/kernel-prep/`: `git apply --check` passes; applying it and running the config merge gives a full `.config` diff of exactly the two touch symbols; the kernel checkout was then reverted byte-clean |
| Recovery-side fetch prepared, unused | `scripts/fetch-modules.sh` (verifies the three modules and the `vermagic` against `prebuilt/Image`, stages into `recovery/root/lib/modules`, refuses to write either load list) |
| Artifact publication prepared | `scripts/publish-release.sh` (resolves the 302 to a signed URL before fetching, so the token never goes to `objects.githubusercontent.com`) |

## GitHub run 9 (`37780545560`, commit `e003562`) — RESULT: killed by the runner 15 s into the build

This is the 7th build attempt and **the first one whose `lunch` succeeded**.

| step | outcome |
| --- | --- |
| 1–12 | ✅ (sync ~19 min with warm caches, caches saved, kernel + device tree installed) |
| 13 Build recoveryimage | ❌ **after 15 seconds, killed from outside** |
| 14–17, post steps | skipped — the runner was gone, so even `if: always()` log upload never ran |

The build step's own output:

```
-- lunching: twrp_mars-ap2a-eng              <- product config is now VALID
[  0% ... ] ... [ 99% 1161/1162] cp /home/runner/fox_14.1/out/host/linux-x86/bin/soong_build
##[error]The runner has received a shutdown signal. This can happen when the
          runner service is stopped, or a manually started runner is canceled.
##[error]Process completed with exit code 143.
```

`mka recoveryimage` started at **13:22:04Z** and the shutdown arrived at
**13:22:19Z**; exit code 143 is `128+15` (SIGTERM). It died during Soong's own
host-tool bootstrap, i.e. **before a single Android target was compiled**, so
this run carries no information about the device tree at all.

Two things worth recording:

* **The obsolete-variable fix is confirmed.** `-- lunching: twrp_mars-ap2a-eng`
  is the line this project has been trying to reach for six rounds: the product
  spec resolves, `dumpvars` succeeds, and `mka` runs.
* **No device-tree action follows from this.** It is an environment failure —
  the runner was reclaimed/stopped mid-job — not a build error. Per the decision
  to move to the user's own server, nothing was changed in response, no new
  cloud run was triggered, and the cloud workflow is now only a fallback.

Disk at the moment the build started: 146 GB total, **118 GB used / 28 GB free**
(the same reading as run 8), which is the number behind the server sizing advice
in [BUILD-ON-SERVER.md](BUILD-ON-SERVER.md).

After this run no further GitHub builds were started; the primary path is
`scripts/build-local.sh` on the user's server.

## Server build 1 (the user's own server) — RESULT: IN PROGRESS, blocked on server access

First run of the documented server path (`scripts/build-local.sh` on the user's
Ubuntu machine) instead of a GitHub runner. **Nothing was flashed, no kernel
repository was touched, and no cloud build was triggered.**

### Environment measured

| item | value |
| --- | --- |
| OS / kernel | Ubuntu 22.04.5 LTS, `6.8.0-40-generic`, x86_64 |
| CPU / RAM | 4 cores / 15 GB RAM (~14.2 GB available) + 2 GB swap |
| disk | `/dev/sda3` 294 GB with **268 GB free** at the start; `/home` is on `/` |
| network | reached over IPv6 through a relay (`lkv6.shen-hub.top:35671`) |
| hostname | `shen-Standard-PC-Q35-ICH9-2009` |

Directory layout used on the server (all work stayed inside these):

| path | what |
| --- | --- |
| `~/twrp-mars` | device tree working copy, `git clone https://github.com/S0SL/twrp_mars.git`, HEAD `2a9c092` — verified identical to the local copy |
| `~/fox_14.1` | the AOSP/OrangeFox build tree (`scripts/fox-sync.sh` target) |
| `~/bin/repo` | Google's `repo` launcher 2.65 (the apt one is too old) |
| `~/logs/` | `build.log`, `resource.log` (30 s RAM/disk sampler), plus per-attempt logs |

`scripts/check-tree.sh` passes on the server copy (`ALL CHECKS PASSED`).

### Phase timings (measured, UTC)

| phase | elapsed | notes |
| --- | --- | --- |
| apt dependencies (3 tiers) | **9 m 33 s** | tier 1 base 7 m 00 s, tier 2 i386 multilib 2 m 33 s, tier 3 repo launcher ~1 s. Splitting the tiers is what keeps this fast — see the table row in BUILD-ON-SERVER.md |
| preflight + ccache | 3 s | |
| `repo sync` attempt 1 | 82 m (killed) | reached 36 GB, then the international path stalled for 15 min (S1) |
| `repo sync` attempt 2 | 64 m | reached 79 GB, then failed on two projects (S2) |
| sync repair / re-verification | in progress | |
| `mka recoveryimage` | not reached | |

Disk peaked at **120 GB used** during the failed attempts, of which **54 GB was
failed-fetch `tmp_pack_*` garbage** that was reclaimed (72 GB used afterwards).
Lowest `MemAvailable` observed ≈ 13 GB; load peaked ≈ 10 on 4 cores; **no OOM kill
was observed in the logs**. `--jobs 4` was used throughout.

### Failure S1 — the international path died for ~15 minutes

At ~16:44 UTC every connection to `github.com`, `android.googlesource.com` and
`1.1.1.1` completed the TCP handshake but transferred **0 bytes**, while
`raw.githubusercontent.com`, `gitlab.com` and all domestic mirrors stayed usable.
It recovered by itself at ~17:04. `git fetch` has no transfer timeout, so the hung
fetches had to be killed by hand; no progress was lost (`repo sync` resumes).

Two mitigations, both kept:

* `http.lowSpeedLimit=200` + `http.lowSpeedTime=900` so a stalled transfer aborts
  instead of hanging forever;
* the AOSP bulk is fetched from the Tsinghua mirror —
  `git config --global url."https://mirrors.tuna.tsinghua.edu.cn/git/AOSP/".insteadOf "https://android.googlesource.com/"`.
  This only changes where the bytes come from; git verifies object SHAs, so the
  revision is identical. Measured **39 MB/s vs ~1 MB/s** (~20×). GitHub and GitLab
  stay on their origin hosts.

### Failure S2 — `repo` silently drops `--depth=1`, turning a 1 GB fetch into a 20 GB one

The real reason the sync kept dying:

```
error: Unable to fully sync the tree
error: Downloading network changes failed.
GitCommandError: 'fetch ... tag android-14.0.0_r67 ...' on platform/prebuilts/clang/host/linux-x86 failed
stdout: error: RPC failed; curl 56 GnuTLS recv error (-9): Error decoding the received TLS packet.
GitCommandError: ... on platform/prebuilts/rust failed
```

`~/fox_14.1/.repo/repo/project.py:1886`:

```python
if depth and not is_new and not self._HasShallow():
    depth = None          # existing project -> --depth is dropped -> FULL history
```

`repo init --depth=1` does write `repo.depth = 1`, but repo applies it **only to
projects it considers new**. As soon as a project directory exists from a failed
attempt, every later fetch pulls the complete history: `prebuilts/rust`
accumulated a **10.2 GB** single pack and `clang/host/linux-x86` **9.4 GB**, and
both directories held *only* failed `tmp_pack_*` files — no usable pack, no refs,
so every retry restarted from zero. That this was tree-wide is confirmed by
**zero `shallow` files** anywhere under `.repo/project-objects`.

**Fix (verified):** delete the failed project directory
(`rm -rf ~/fox_14.1/.repo/project-objects/<name>.git`) so repo treats it as new —
the fetch command then literally becomes `git fetch --depth=1 ...`. Runbook for a
retry: `scripts/`-adjacent helper `fix-giants.sh` in the operator's `~/`, which
repairs those projects and then re-verifies the whole tree.

### Failure S3 — self-inflicted: the low-speed guard fired while the mirror was still packing

```
curl 28 Operation too slow. Less than 1000 bytes/sec transferred the last 60 seconds
```

The first version of the stall guard (`lowSpeedTime=60`) killed large fetches
*before they started*: when a big pack is requested, the mirror spends minutes
generating it server-side and sends nothing meanwhile. Relaxed to
`lowSpeedLimit=200` / `lowSpeedTime=900`.

### Then the server became unreachable (open blocker)

From 19:38 UTC the SSH endpoint stopped working, and the failure mode is
diagnostic:

| probe | result |
| --- | --- |
| ports 22 / 35670 / 35672 / 35673 / 8080 / 443 | `Connection refused` |
| port **35671** | TCP connect succeeds (0.04 s), **no bytes are ever sent**, and the peer closes cleanly after **~3.4 s** |
| 8 passive banner reads (30 s each) | 8/8 zero bytes |

An sshd sends its `SSH-2.0-...` banner immediately on accept, and that banner is a
few dozen bytes — independent of bandwidth and MTU. A silent accept followed by a
clean close is the signature of a **relay/tunnel endpoint whose backend has gone
away** (`lkv6.shen-hub.top` is a tunnelled name). The machine behind it lost its
tunnel — most likely because its outbound connection dropped, or because the
resource-heavy full-history fetches that S2 describes caused memory pressure and
the tunnel client (possibly sshd too) was killed.

The machine has to be reached by the operator: restart the tunnel client, verify
the host itself still has network (a static-IP change to `192.168.101.209/24` was
made on it shortly before, so an address conflict is worth ruling out), or reboot
it. Nothing in this repository can fix that, and no further cloud run was started.

### Hardware note for the next run

Because `repo init --depth=1` is not honoured for pre-existing projects, a
from-scratch sync of this manifest downloads **full history** and peaks around
120 GB *before* `out/`. Budget 200 GB+, and whenever a project fails, delete its
`.repo/project-objects/<name>.git` directory so the retry is shallow rather than
another full-history transfer.

### Failure S4 — `lunch` died silently (and why there was no error line)

The build reached `mka` for the first time and then stopped dead:

```
== 6. build ==
including device/xiaomi/mars/vendorsetup.sh
   release candidates:  ap2a ap3a bp2a
[2026-10-09T03:41:35Z] build failed (exit 1) -- exiting non-zero so systemd retries
```

Nothing after "release candidates" — not even the first `-- lunch` line, and no
error message anywhere. Reproduced by hand:

```
build/envsetup.sh: line 185: BUILD_VAR_CACHE_READY: unbound variable
```

`build-local.sh` calls envsetup's `destroy_build_var_cache` while `set -u` is
still active, and that function does `for v in $cached_vars` — variables that do
not exist until the build-var cache has been built. Under `set -u` bash **exits
the whole shell** on the first such dereference, and because the call is written
`destroy_build_var_cache 2>/dev/null || true`, the message is thrown away: the
script dies silently. (Bash does flush already-buffered stdout before exiting on
an unbound variable, which is why the missing lines themselves are the proof that
it died before the first `echo`.)

Fix: move `set +u` above the cache calls and leave nounset off for the rest of the
script (`scripts/build-local.sh`). `lunch twrp_mars-ap2a-eng` then reports

```
TARGET_PRODUCT=twrp_mars  TARGET_BUILD_VARIANT=eng  TARGET_ARCH=arm64
BUILD_ID=AP2A.240905.003  OUT_DIR=/home/shen/fox_14.1/out
```

### S5 — a false "the memory guard deadlocked the build" alarm

The guard logs one line when it pauses and nothing afterwards, and Soong's
analysis phase prints no progress at all (its progress display stays at
`[99% 1161/1162] cp .../soong_build` for hours while it writes
`out/soong/build.twrp_mars.ninja`). Together those two facts look exactly like a
hung build: *"last log line is the MEM GUARD SIGSTOP, no new lines since,
soong_build apparently gone"*.

It was a false alarm, and the evidence is worth recording because the same
question will come up again:

| check | result |
| --- | --- |
| `ps -eo pid,stat,comm \| awk '$2 ~ /^T/'` | **empty** — nothing was ever stopped |
| `pgrep -f 'soong_build --top'` | present, `S`, ~26–39 % of a core |
| `out/soong/build.twrp_mars.ninja` | growing monotonically — 1 157 627 904 → 1 179 279 360 bytes in 60 s |
| `out/` | growing (2.6 GB → 2.7 GB) |
| `mka` errors | 0 |

Nothing ever matched the guard's pattern, because it only ever selected
network/fetch processes (`git-remote-https`, `index-pack`, `git fetch`,
`main.py.*sync`) and **no fetch was running during the compile** — so `pkill
-STOP` stopped nothing. But the design was genuinely unsafe, so it was rewritten:

* **resume on whichever comes first** — memory recovering *or* a hard timeout
  (`MARS_MEM_STOP_MAX`, default 90 s). A stopped process keeps holding its pages,
  so waiting for the high watermark alone can never terminate: that is a real
  deadlock, and it is now impossible by construction;
* **only ever stops network/fetch processes**, and additionally refuses any pid
  whose `comm` is a build tool (`soong_build`, `soong_ui`, `ninja`, `nsjail`,
  `mka`, `make`, `cc1plus`, `clang*`, `bash`, `sh`, …), so a pattern mistake
  cannot freeze the compile chain either;
* **logs a heartbeat** every `MARS_MEM_HEARTBEAT_S` (default 300 s) with
  MemAvailable, free swap and the soong/ninja/cc1plus/out state, so the log can
  never look hung again;
* `MARS_MEM_GUARD=0` turns the whole thing off — with 8 GB of extra swap in place
  and zero OOM kills, swapping is the safer fallback.

Deployed with `install … .new && mv -f .new`, never by overwriting in place: bash
reads a script incrementally, so replacing a file that is *currently executing*
can corrupt a running build. `mv` swaps the directory entry and the running shell
keeps reading the old inode.

### Memory: 8 GB of extra swap

`soong_build` peaked at ~15.0 GB RSS on a 15.6 GB machine, with the original 2 GB
swap **100 % used** and ~120 MB/s of swap traffic. An 8 GB `/swapfile-mars`
(`fallocate` + `mkswap` + `swapon`, not in `/etc/fstab`) was added for headroom.
It is non-destructive and removable with `swapoff /swapfile-mars`. Result: **zero
OOM kills** throughout the compile.

### S6 — our own tree set an OrangeFox-obsolete variable (`OF_AB_DEVICE`)

Once Soong analysis finally completed, the build died in the **kati (legacy Make)**
stage:

```
[ 95% 1031/1080] including bootable/recovery/Android.mk
FAILED:
In file included from bionic/tests/Android.mk:33:
In file included from bootable/recovery/Android.mk:156:
bootable/recovery/orangefox.mk:597: error: "OF_AB_DEVICE" is obsolete. Use "export FOX_AB_DEVICE=1" instead.
18:05:55 ckati failed with: exit status 1
```

This is the same *class* as Cause 6 (`KATI_obsolete_var` hard errors), but the
check lives in OrangeFox's own `orangefox.mk` — 12 names there raise
`$(error ...)`. Our tree set `OF_AB_DEVICE := 1` in three places
(`fox_mars.mk`, `device.mk`, `vendorsetup.sh`).

`scripts/obsolete-build-vars.txt` now also lists the twelve OrangeFox names and
`scripts/check-tree.sh` scans `vendorsetup.sh` as well (it previously looked at
`.mk` files only, which is exactly where one of the three occurrences hid). A
negative test confirms the validator fails on the old spelling and passes on the
new one — so this class of bug now costs ten seconds instead of a 25-minute
build.

### S7 — the "obvious" rename then hits `AB_OTA_UPDATER`, which is `KATI_READONLY`

Renaming to `FOX_AB_DEVICE` immediately produced a second kati stop:

```
bootable/recovery/orangefox.mk:170: error: cannot assign to readonly variable: AB_OTA_UPDATER
```

The relevant OrangeFox code is:

```make
167| ifeq ($(FOX_AB_DEVICE),1)
168|     LOCAL_CFLAGS += -DFOX_AB_DEVICE='"1"'
169|     ifneq ($(AB_OTA_UPDATER),true)
170|         AB_OTA_UPDATER := true            <-- hard error
```

and `build/make/core/board_config.mk:923-924` does

```make
AB_OTA_UPDATER ?=
.KATI_READONLY := TARGET_RECOVERY_UPDATER_LIBS AB_OTA_UPDATER
```

so any later assignment to it is fatal, whatever its value. The author's original
combination — A/B flag on, `AB_OTA_UPDATER` unset (KNOWN_ISSUES I15) — **is no
longer expressible**: `OF_AB_DEVICE` is rejected outright, and `FOX_AB_DEVICE`
forces the assignment.

Two ways out, recorded with their trade-offs:

* **(chosen, first validation build)** leave the A/B flag off entirely
  (`a8ad1e9`). The image still boots; A/B *mounting* still comes from the
  `slotselect` flags in `recovery/root/system/etc/recovery.fstab`. What is lost is
  OrangeFox's A/B awareness (`-DFOX_AB_DEVICE=1`) and `bootctl`, i.e. slot-aware
  flashing in the UI.
* **(the proper fix, for a later round)** declare the device A/B to the whole
  build system by setting `AB_OTA_UPDATER := true` (plus `AB_OTA_PARTITIONS`)
  early in `BoardConfig.mk`. That makes line 169 false, so line 170 never runs,
  and the A/B flag comes back. It is a bigger semantic change and exactly what
  KNOWN_ISSUES I15 warns about, so it deserves its own build round rather than
  being smuggled into the first one.
