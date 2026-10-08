# Building the mars recovery on your own server

This is the primary build path from now on: a plain Ubuntu machine you control,
instead of GitHub's runners. The cloud workflow
(`.github/workflows/build-recovery.yml`) stays in the tree and remains valid, but
each cloud round costs 40–70 minutes and is disk-bound, and no round has yet
reached a full compile — the server is faster and easier to iterate on.

`scripts/build-local.sh` implements everything below; this document explains
what it does, what it needs, how long it takes, and what to do when it breaks.

---

## 1. What the server needs

| resource | minimum | recommended | why |
| --- | --- | --- | --- |
| OS | Ubuntu 22.04 x86_64 | Ubuntu 24.04 x86_64 | the tree is built for 22.04+; other distros work but the apt line below is Ubuntu |
| CPU | 4 cores | 8–16 cores | a 5.4 kernel-independent Android 14 tree; `-j$(nproc)` |
| RAM | 16 GB | 32 GB | Soong + ninja linking; 8 GB will OOM with `-j8` (use `--jobs 4`) |
| disk | 150 GB free | **200 GB+ free** | measured: 118 GB used on the CI runner after `repo sync` + caches, with `out/` still to come |
| network | ~40 GB download | — | `repo sync` of the pruned Android 14 manifest |
| time (first build) | ~2 h | ~60–90 min | sync 20–35 min + build 30–60 min |

Nothing here is device-specific to the CI: no Docker, no GitHub token. The only
secrets involved are the Android signing keys the build already carries
(`external/avb/test/data/testkey_rsa2048.pem`, `vendor/recovery/security/miui`).

## 2. One-time setup

```sh
# 2.1 build dependencies (exactly what the CI installs)
sudo apt-get update
sudo apt-get install -y \
  bc bison build-essential ccache cpio curl flex git git-lfs gnupg gperf \
  imagemagick libelf-dev libssl-dev libxml2 libxml2-utils lzop pngcrush \
  rsync schedtool squashfs-tools unzip xsltproc zip zlib1g-dev zstd lz4 \
  python3 patchelf openjdk-17-jdk-headless

# 32-bit multilib (a few tools want it; not fatal if some are unavailable)
sudo dpkg --add-architecture i386 && sudo apt-get update
sudo apt-get install -y gcc-multilib g++-multilib libc6-dev-i386 \
  lib32z1-dev lib32readline-dev lib32ncurses5-dev libncurses5-dev

# 2.2 `repo` -- the apt version is too old; use Google's launcher
mkdir -p ~/bin
curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o ~/bin/repo
chmod a+x ~/bin/repo
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc && export PATH="$HOME/bin:$PATH"
repo --version

# 2.3 git identity (some projects need it) and ccache
git config --global user.name  "mars builder"
git config --global user.email "builder@localhost"
git config --global color.ui false
ccache -M 50G
```

`scripts/build-local.sh` checks all of this and prints the exact `apt-get`
command for whatever is missing.

## 3. Build — the short version

```sh
# 3.1 get this device tree (anywhere; the script copies it into the AOSP tree)
git clone https://github.com/S0SL/twrp_mars.git ~/twrp_mars

# 3.2 build.  First run: sync (20-35 min) + fetch kernel + compile (30-60 min).
~/twrp_mars/scripts/build-local.sh --fox-dir ~/fox_14.1
```

Everything lands in `~/twrp_mars/dist/`:

| file | what it is |
| --- | --- |
| `boot.img` | **the recovery** — kernel + OrangeFox recovery ramdisk (mars has no recovery partition, so this is recovery-as-boot) |
| `recovery.img` | side product of the same ramdisk; do **not** flash it on mars |
| `OrangeFox-*.zip` | the flashable installer, if OrangeFox's scripts produced one |
| `BUILD-INFO.txt` | what was built from what, plus `sha256sum`s |

Nothing in this repository flashes to a device. When you want to try it:

```sh
adb reboot bootloader
fastboot boot boot.img          # boots it once, changes nothing
# only after that works: fastboot flash boot boot.img
```

Useful flags: `--jobs N`, `--skip-sync` (tree already synced), `--skip-kernel`
(Image already in place), `--clean` (drop `out/` first), `--no-ccache`,
`--ccache-dir DIR`, `--build-type Beta|Stable`, `--kernel-url URL`,
`--releases "ap2a"` (lunch release token; see §6).

## 4. Build — the manual version

If you prefer to drive it yourself — or to debug a step in isolation — these are
the exact commands `scripts/build-local.sh` runs:

```sh
export FOX_DIR="$HOME/fox_14.1"
export PATH="$HOME/bin:$PATH"

# 4.1 sync OrangeFox fox_14.1 (20-35 min, ~35 GB)
~/twrp_mars/scripts/fox-sync.sh "$FOX_DIR"
#   - clones OrangeFox/sync and runs ./orangefox_sync.sh --branch 14.1
#   - works around an upstream bug where the vendor/twrp patch is looked up in
#     the wrong directory, and then VERIFIES the patch was applied
#   - refuses to continue if the tree is incomplete

# 4.2 put this device tree where the build expects it
mkdir -p "$FOX_DIR/device/xiaomi/mars"
rsync -a --exclude '.git/' --exclude '.github/' --exclude 'scripts/' \
      --exclude 'docs/' --exclude 'dist/' \
      ~/twrp_mars/ "$FOX_DIR/device/xiaomi/mars/"

# 4.3 fetch the prebuilt kernel Image (no kernel is compiled here)
~/twrp_mars/scripts/fetch-kernel.sh \
    "https://github.com/S0SL/android_kernel_xiaomi_sm8350/releases/download/boot-img-LOS23.2-20260930-bakasu/anykernel3-BakaSU-susfs-v2.3.0-mars.zip" \
    "$FOX_DIR/device/xiaomi/mars/prebuilt/Image"

# 4.4 build
cd "$FOX_DIR"
export LC_ALL=C FOX_BUILD_DEVICE=mars FOX_BUILD_TYPE=Unofficial
export ALLOW_MISSING_DEPENDENCIES=true
export USE_CCACHE=1 CCACHE_DIR="$FOX_DIR/.ccache"

source build/envsetup.sh            # NOTE: do not run this under `set -u`
lunch twrp_mars-ap2a-eng            # three parts: <product>-<release>-<variant>
mka recoveryimage                   # -> out/target/product/mars/boot.img

# 4.5 collect
ls -l out/target/product/mars/{boot.img,recovery.img}
```

**ccache is the single biggest speed-up.** It is configured in step 2.3 and
exported in 4.4; with a warm cache a rebuild after a small device-tree change
takes minutes instead of ~40. Keep `CCACHE_DIR` on a fast disk and give it
50 GB; `ccache -s` shows the hit rate.

## 5. Timings (measured)

| phase | observed | notes |
| --- | --- | --- |
| apt dependencies | ~50 s | once the list is split by tier (a flat list once stalled 10+ min on a cloud runner) |
| `repo sync` | **19 min** (warm cache) / **35 min** (cold) | CI logs, run 1 and run 8 |
| `.repo` cache save | ~5 min | CI only — the server just keeps the tree |
| `fetch-kernel.sh` | seconds | ~20 MB AnyKernel3 zip |
| `mka recoveryimage` | 30–60 min (estimate) | no run has reached a full compile yet; it is a minimal recovery-only build |
| **total, first build** | **~60–100 min** | plus ~40 GB of downloads |

Disk measured on the CI runner (146 GB total): 36 GB used before the sync,
**118 GB after the sync + caches**, 28 GB free at the moment the compile starts.
Budget 200 GB to be comfortable, especially with ccache.

## 6. Troubleshooting — every failure this project has actually hit

| symptom in the log | cause | fix |
| --- | --- | --- |
| `build/envsetup.sh: line 21: TOP: unbound variable` | `set -u` (nounset) around `source build/envsetup.sh` | source it with nounset off (`set +u`), then `set -u` again. `build-local.sh` does |
| `patch-vendor-twrp-fox_14.1.diff: No such file or directory` + `Error! Failed to patch the twrp-14 vendor/twrp` | upstream `orangefox_sync.sh` looks for the patch in the wrong directory, and only warns | `scripts/fox-sync.sh` pre-places it and then verifies `vendor/twrp/config/BoardConfigSoong.mk` includes `orangefox_soong.mk` |
| `Invalid lunch combo: twrp_mars-eng` / `Valid combos must be of the form <product>-<release>-<variant>` | this build/make fork requires three parts | use `twrp_mars-ap2a-eng` (or run `build-local.sh`, which probes) |
| `No release config found for TARGET_RELEASE: bp2a. Available releases are: ap2a` | the release token was guessed | take the token from `ls build/release/release_configs/` — for this manifest it is `ap2a` |
| `device/xiaomi/mars/BoardConfig.mk:124: error: BOARD_BUILD_SYSTEM_ROOT_IMAGE is obsolete` | Kati makes *any* use of a `KATI_obsolete_var` a hard error | already fixed in the tree; `scripts/check-tree.sh` now fails if it comes back (148 obsolete names in `scripts/obsolete-build-vars.txt`) |
| `** Don't have a product spec for: 'twrp_mars'` | almost always *fallout*: `dumpvars` failed earlier | scroll up for the first real error — do not chase the product spec |
| `vendor/qcom/opensource/commonsys-intf/display is not in the manifest` (warning) | that CAF project is not in this manifest | harmless by design; if the display stays dark, drop the three `.so` files into `recovery/root/vendor/lib64/` (see `docs/KNOWN_ISSUES.md` I16) |
| `No space left on device` | disk | free space or move the tree; 200 GB recommended |
| build dies with OOM / `virtual memory exhausted` | RAM | `--jobs 4` (or lower) |
| touch or the panel do not work in the recovery | the kernel's modules are not in the ramdisk and the ROM's modules do not match our kernel | expected before the kernel change lands — see `docs/RAMDISK-MODULES.md`; the ROM's `.ko` files can never load into our prebuilt Image (vermagic includes the build commit) |

Before handing a tree to the build, `scripts/check-tree.sh` validates it without
needing AOSP at all (files present, fstab/flags parse, lunch choices are
three-part, no obsolete build variables, workflow and shell syntax):

```sh
~/twrp_mars/scripts/check-tree.sh
```

## 7. What is deliberately *not* in this path

* **No /data decryption** (`TW_INCLUDE_CRYPTO := false`) — phase 2, see
  `docs/PHASE2-CRYPTO.md`.
* **No CI caches or artifact uploads** — those live only in the GitHub
  workflow; `scripts/fox-sync.sh` is pure build logic and is reused unchanged.
* **No kernel build** — the kernel is prebuilt (`TARGET_PREBUILT_KERNEL`). The
  kernel-repository change that would also ship touch/display modules is
  prepared, dry-run verified, and *not pushed*: `docs/kernel-prep/`.
* **Nothing is flashed** by any script here.

## 8. If the build succeeds

1. Keep `dist/BUILD-INFO.txt` with the images — it records the kernel URL and
   the `sha256sum`s.
2. `fastboot boot dist/boot.img` first; flash only once it boots.
3. Report the recovery's `/tmp/recovery.log` (or `adb shell cat
   /tmp/recovery.log`) for the module-loading lines:
   `Checking directory: /lib/modules`, `Modules Loaded: N` — that is the direct
   measurement of whether touch/display can come up.
