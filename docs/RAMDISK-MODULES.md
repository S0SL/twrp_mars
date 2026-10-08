# Building the touch / display kernel modules into the recovery ramdisk

**Status: PLAN — nothing in this document has been applied, and nothing in
`S0SL/android_kernel_xiaomi_sm8350` has been touched.**

This is the fix for `KNOWN_ISSUES.md` I7 and I11. It needs two decisions from
the user before anything is committed:

1. a change **in the kernel repository** (a config fragment + a `modules`
   build target + a new release asset), and
2. a change **in this tree** (a guarded `BOARD_VENDOR_RAMDISK_KERNEL_MODULES`
   block, which is a no-op until the modules exist).

Everything below was checked against the real sources, not recalled: the
build-system behaviour against `nebrassy/android_build` `android-14` (the fork
fox_14.1 syncs), the runtime behaviour against OrangeFox's own
`kernel_module_loader.cpp`, and the configs against the kernel checkout.

---

## 1. The problem

The recovery kernel is **prebuilt** (`TARGET_PREBUILT_KERNEL`), so
`mka recoveryimage` compiles no `.ko` at all, and the recovery ramdisk ships
**empty** `/lib/modules`. `device.mk` therefore relies on

```make
TW_LOAD_VENDOR_MODULES := "xiaomi_touch.ko fts_touch_spi.ko fts_touch_spi_k2.ko focaltech_touch.ko adsp_loader_dlkm.ko qti_battery_charger.ko"
```

which makes TWRP `insmod` those modules **from the installed ROM's
`/vendor/lib/modules`** at runtime. That works only when the ROM's modules were
built against the same kernel (`vermagic` + `CONFIG_MODVERSIONS` symbol CRCs).
For the cross-ROM goal (HyperOS 2 *and* LineageOS 23.2 on one recovery image)
that assumption does not hold: the MIUI/HyperOS modules and the LineageOS
modules come from different kernel builds than our prebuilt `Image`.

## 2. What actually consumes `/lib/modules` at runtime

Two independent loaders run in a recovery-as-boot ramdisk. Both were read from
source.

### 2.1 AOSP `init` (first stage) — reads `modules.load.recovery` in recovery mode

Verified in `system/core/init/first_stage_init.cpp` (AOSP 14):

```c
std::string GetModuleLoadList(bool recovery, const std::string& dir_path) {
    auto module_load_file = "modules.load";
    if (recovery) {
        struct stat fileStat;
        std::string recovery_load_path = dir_path + "/modules.load.recovery";
        if (!stat(recovery_load_path.c_str(), &fileStat)) {
            module_load_file = "modules.load.recovery";
        }
    }
    return module_load_file;
}
#define MODULE_BASE_DIR "/lib/modules"
```

So during a recovery boot, first-stage init looks in **`/lib/modules`** and
prefers **`modules.load.recovery`** when that file exists (it iterates
version-matching sub-directories such as `/lib/modules/5.4` first, then falls
back to the flat `/lib/modules`). This is the path that gets the display/touch
modules loaded *before* the recovery binary starts — and it is why the file
name matters: §3 shows which build variable generates which load-list file
(`BOARD_VENDOR_RAMDISK_KERNEL_MODULES_LOAD` → `lib/modules/modules.load`, and
`modules.load.recovery` in the same directory from the module set itself — the
similarly named `BOARD_VENDOR_RAMDISK_RECOVERY_KERNEL_MODULES_LOAD` targets the
*vendor* ramdisk, which this device tree never builds).

**⚠ This path is strict — a bad entry is fatal.** `Modprobe::LoadListedModules`
returns `false` if any listed module cannot be loaded
(`libmodprobe/libmodprobe.cpp`):

```cpp
bool Modprobe::LoadListedModules(bool strict) {
    auto ret = true;
    for (const auto& module : module_load_) {
        if (!LoadWithAliases(module, true)) {
            if (IsBlocklisted(module)) continue;
            ret = false;
            if (strict) break;
        }
    }
    return ret;
}
```

and first-stage init turns that into a panic:

```cpp
    if (!LoadKernelModules(IsRecoveryMode() && !ForceNormalBoot(cmdline, bootconfig), want_console,
                           want_parallel, module_count)) {
        if (want_console != FirstStageConsoleParam::DISABLED) {
            LOG(ERROR) << "Failed to load kernel modules, starting console";
        } else {
            LOG(FATAL) << "Failed to load kernel modules";
        }
    }
```

Consequence: a `modules.load.recovery` that names a module which is **not
present** in the ramdisk, or that fails its `vermagic`/CRC check, does not
merely cost touch — it makes the recovery image fail to boot. The load list
must therefore be derived from the modules actually shipped
(`$(notdir $(wildcard ...))`, §3.1) and the modules must come from the same
build as the `Image` (§6). If a single module has to be excluded, ship a
`modules.blocklist` (`BOARD_RECOVERY_KERNEL_MODULES_BLOCKLIST_FILE`, installed
as `/lib/modules/modules.blocklist`) — blocklisted modules are skipped instead
of failing.

### 2.2 TWRP / OrangeFox — reads `modules.load.twrp`, generated at runtime

`bootable/recovery/kernel_module_loader.cpp` (fox_14.1) is the second loader.
Its search path, in order, is:

```c
#define VENDOR_MODULE_DIR "/vendor/lib/modules"           // mounted ROM vendor
#define VENDOR_BOOT_MODULE_DIR "/lib/modules"             // ramdisk modules  <-- first!
#define VENDOR_DLKM_MODULE_DIR "/vendor_dlkm/lib/modules"
```

```c
	// check /lib/modules (ramdisk vendor_boot)
	// check /lib/modules/N.N (ramdisk vendor_boot)
	// check /lib/modules/N.N-gki (ramdisk vendor_boot)
	// check /vendor/lib/modules (ramdisk)
	// check /vendor/lib/modules/1.1 (ramdisk prebuilt modules)
	// check /vendor/lib/modules/N.N (vendor mounted)
	// check /vendor/lib/modules/N.N-gki (vendor mounted)
	// check /vendor_dlkm/lib/modules (vendor_dlkm mounted)
```

For each directory it writes `modules.load.twrp` — the **intersection** of
`TW_LOAD_VENDOR_MODULES` with the `.ko` files actually present in that
directory — then `libmodprobe`s exactly that list:

```cpp
	for (auto&& requested:kernel_modules_requested) {
		if (kernel_module == requested) {
			kernel_modules.push_back(kernel_module);
```

```cpp
		Modprobe m({module_dir}, "modules.load.twrp", false);
		m.LoadListedModules(false);
```

Consequences that matter for the plan:

* `/lib/modules` inside the **recovery ramdisk is tried first**, so modules we
  ship in the ramdisk win over the ROM's modules — no vendor mount required.
* TWRP only loads the file names listed in `TW_LOAD_VENDOR_MODULES`; anything
  else in `/lib/modules` is copied to tmpfs but not loaded.
* `modules.load.recovery` (AOSP init) and `modules.load.twrp` (TWRP) are
  **different files with different consumers**; shipping modules needs the
  first one generated by the build system and the second one generated at
  runtime by TWRP.

## 3. The build-system wiring (verified line by line)

From `nebrassy/android_build`, `android-14`, `core/Makefile`
(<https://raw.githubusercontent.com/nebrassy/android_build/android-14/core/Makefile>,
7799 lines; line numbers as of this writing):

```make
ifneq ($(BUILDING_VENDOR_BOOT_IMAGE),true)
  # If there is no vendor boot partition, store vendor ramdisk kernel modules in the
  # boot ramdisk.
  BOARD_GENERIC_RAMDISK_KERNEL_MODULES += $(BOARD_VENDOR_RAMDISK_KERNEL_MODULES)
  BOARD_GENERIC_RAMDISK_KERNEL_MODULES_LOAD += $(BOARD_VENDOR_RAMDISK_KERNEL_MODULES_LOAD)
endif
...
ifneq ($(strip $(BOARD_GENERIC_RAMDISK_KERNEL_MODULES)),)
  ifeq ($(BOARD_USES_RECOVERY_AS_BOOT), true)
    BOARD_RECOVERY_KERNEL_MODULES += $(BOARD_GENERIC_RAMDISK_KERNEL_MODULES)
  endif
endif
```

and then, per kernel-module directory (`top`), the RECOVERY directory is filled
straight into the **recovery ramdisk root**:

```make
  $(eval ALL_DEFAULT_INSTALLED_MODULES += $(call build-image-kernel-modules-dir,RECOVERY,$(TARGET_RECOVERY_ROOT_OUT),,modules.load.recovery,$(RECOVERY_STRIPPED_MODULE_STAGING_DIR),$(kmd)))
```

with `modules.load` written by the recovery-as-boot branch:

```make
define build-recovery-as-boot-load
...
  $(if $(BOARD_GENERIC_RAMDISK_KERNEL_MODULES_LOAD$(_sep)$(_kver)),\
    $(call copy-many-files,$(call module-load-list-copy-paths,$(call intermediates-dir-for,PACKAGING,ramdisk_module_list$(_sep)$(_kver)),$(BOARD_GENERIC_RAMDISK_KERNEL_MODULES$(_sep)$(_kver)),$(BOARD_GENERIC_RAMDISK_KERNEL_MODULES_LOAD$(_sep)$(_kver)),modules.load,$(TARGET_RECOVERY_ROOT_OUT))))
endef
```

`build-image-kernel-modules` copies each entry of the module list to
`<output>/lib/modules/<basename>`, runs `depmod`, and writes the load-list file
whose content is the **basename of every entry in the load list**:

```make
  $(foreach module,$(1), ... $(_src):$(2)/lib/modules/$(_dir)$(notdir $(module)))
  $(eval $(call build-image-kernel-modules-depmod,$(1),$(3),$(4),$(5),...))
...
	$(if $(1),\
	  cp $$(PRIVATE_MODULES) $$(PRIVATE_MODULE_DIR)/; \
	  if [ -n "$$(PRIVATE_LOAD_MODULES)" ]; then basename -a $$(PRIVATE_LOAD_MODULES); fi > $$(PRIVATE_LOAD_FILE); \
	)
```

Four practical consequences:

1. For **this** device (`BOARD_USES_RECOVERY_AS_BOOT := true`,
   `BUILDING_VENDOR_BOOT_IMAGE != true`) setting
   `BOARD_VENDOR_RAMDISK_KERNEL_MODULES` is enough: it flows into
   `BOARD_GENERIC_RAMDISK_KERNEL_MODULES` → `BOARD_RECOVERY_KERNEL_MODULES` →
   the recovery ramdisk. **Do not set `BOARD_RECOVERY_KERNEL_MODULES`
   directly**; it is derived, and setting it as well would double-install.
2. `BOARD_VENDOR_RAMDISK_RECOVERY_KERNEL_MODULES_LOAD` lands in the *vendor*
   ramdisk staging dir (`TARGET_VENDOR_RAMDISK_OUT`), which we never build. The
   variable we want for the recovery ramdisk is
   **`BOARD_VENDOR_RAMDISK_KERNEL_MODULES_LOAD`** (it becomes
   `BOARD_GENERIC_RAMDISK_KERNEL_MODULES_LOAD` → `lib/modules/modules.load`),
   and `modules.load.recovery` is generated automatically from the module
   basenames unless `BOARD_RECOVERY_KERNEL_MODULES_LOAD` overrides it.
3. A load-list entry with **no matching `.ko`** is not an error at build time:
   the file is simply not copied, but its name still ends up in
   `modules.load`/`modules.load.recovery`, and first-stage init then treats
   that as a fatal module-load failure (§2.1) — i.e. no boot at all, not just
   missing touch. Keep the list and the module set identical — deriving the
   list with `$(notdir $(wildcard ...))` guarantees that.
4. `depmod` runs at build time (the AOSP host `depmod`, from
   `external/kmod`), so module **order/dependencies do not have to be
   hand-maintained**.

### 3.1 Proposed change to this tree (guarded, no-op today)

`BoardConfig.mk`, next to the `TARGET_PREBUILT_KERNEL` block:

```make
# ---------------------------------------------------------------------------
# Prebuilt kernel modules shipped inside the recovery ramdisk.
#
# Empty until prebuilt/modules/*.ko exists (produced by
# S0SL/android_kernel_xiaomi_sm8350: `MAKE_TARGET="Image modules"`).  The guard
# is deliberate: with no modules the block is a no-op, so this can land before
# the kernel release does.
# ---------------------------------------------------------------------------
MODULES_DIR := $(DEVICE_PATH)/prebuilt/modules
RECOVERY_KO := $(wildcard $(MODULES_DIR)/*.ko)
ifneq ($(RECOVERY_KO),)
  BOARD_VENDOR_RAMDISK_KERNEL_MODULES := $(RECOVERY_KO)
  BOARD_VENDOR_RAMDISK_KERNEL_MODULES_LOAD := $(notdir $(RECOVERY_KO))
endif
```

plus `prebuilt/modules/` in `.gitignore` (like `prebuilt/Image`), a
`scripts/fetch-modules.sh` (same shape as `fetch-kernel.sh`: download, verify
`*.ko` count and `vermagic`, unpack into `prebuilt/modules/`), and
`TW_LOAD_VENDOR_MODULES` extended with `msm_drm.ko` so the display module is
also loadable from the ROM's `/vendor` as a fallback.

Optional alternative (no build-system involvement at all): copy the `.ko`
files into `recovery/root/lib/modules/` — plain ramdisk files. TWRP's loader
finds them (`/lib/modules` is its first candidate), but there is **no
`depmod`**, so dependency order has to be hand-written in
`TW_LOAD_VENDOR_MODULES`, and AOSP init gets no `modules.load.recovery`. Use
this only as a stop-gap for one or two modules.

## 4. Which modules to build — and the blocker in the current config

### 4.1 The reference set (mars, recovery use)

LineageOS' own mars tree already declares exactly what a **recovery/boot
ramdisk** needs on this device
(`ref/los_mars/BoardConfig.mk`, lines 21–33):

```make
BOOT_KERNEL_MODULES := \
    adsp_loader_dlkm.ko \
    apr_dlkm.ko \
    fts_touch_spi.ko \
    hwid.ko \
    mmhardware_sysfs_dlkm.ko \
    msm_drm.ko \
    q6_notifier_dlkm.ko \
    q6_pdr_dlkm.ko \
    qti_battery_charger_main.ko \
    snd_event_dlkm.ko \
    xiaomi_touch.ko
BOARD_VENDOR_RAMDISK_RECOVERY_KERNEL_MODULES_LOAD := $(BOOT_KERNEL_MODULES)
```

This is the list to start from. `docs/modules.load.recovery` (92 names, from
the OrangeFox sm8350 common tree) is a *superset* that also names modules this
recovery never loads (DVB tuners, audio DLKMs, …); it is not a good module
build target list, only a reference.

### 4.2 Touch: `fts_touch_spi.ko` + `xiaomi_touch.ko`

| module | Kconfig symbol | built by |
| --- | --- | --- |
| `fts_touch_spi.ko` | `CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI` | `drivers/input/touchscreen/fts_spi/Makefile:2` |
| `xiaomi_touch.ko` | `CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE` | `drivers/input/touchscreen/xiaomi/Makefile:2` |

mars's own LineageOS config enables both as modules
(`arch/arm64/configs/vendor/star_QGKI.config`, which `ref/los_mars/BoardConfig.mk`
appends via `TARGET_KERNEL_CONFIG`):

```
CONFIG_TOUCHSCREEN_CYPRESS_CYTTSP5=m
CONFIG_TOUCHSCREEN_CYPRESS_CYTTSP5_DEVICE_ACCESS=m
CONFIG_TOUCHSCREEN_CYPRESS_CYTTSP5_I2C=m
CONFIG_TOUCHSCREEN_CYPRESS_CYTTSP5_LOADER=m
CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI=m
CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE=m
```

**⚠ Blocker: the kernel that produced our prebuilt `Image` does not use that
fragment, and explicitly disables the touch driver.**

`ci/build-kernel.sh` merges only two fragments:

```sh
BASE_CONFIG="vendor/lahaina-qgki_defconfig"
FRAGMENTS=(
	"vendor/debugfs.config"
	"vendor/xiaomi_QGKI.config"
)
```

and `arch/arm64/configs/vendor/xiaomi_QGKI.config` says (lines 29–37):

```
CONFIG_QTI_BATTERY_CHARGER=m

# Touchscreen
# CONFIG_TOUCHSCREEN_FTS is not set
# CONFIG_TOUCHSCREEN_NT36XXX is not set
# CONFIG_TOUCHSCREEN_ST is not set
```

So in the shipped `Image`: `CONFIG_TOUCHSCREEN_ST` is off,
`CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI` can never be `m`, and
`CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE` is never selected. **Running
`make modules` against the current configuration therefore produces no mars
touch driver at all** — the modules must be built with the MARS config, in the
same build as the `Image` they will be loaded into.

That also means the current recovery can only get touch from the ROM's
`/vendor/lib/modules` (I7), which is why the cross-ROM goal is blocked today.

### 4.3 Display: `msm_drm.ko`

Display is a module for every lahaina build, and it does not depend on the
fragment above:

* `techpack/display/config/gki_lahainadisp.conf:12` → `CONFIG_DISPLAY_BUILD=m`
* `techpack/display/msm/Makefile:165` → `obj-$(CONFIG_DISPLAY_BUILD) += msm_drm.o`

So `msm_drm.ko` (plus its dependencies, resolved by `depmod`) is available from
any `make modules` of this kernel, including the current config. It is in
LineageOS' `BOOT_KERNEL_MODULES` for a reason: without it the panel never comes
up in recovery.

### 4.4 Everything else in the reference list

`adsp_loader_dlkm.ko`, `apr_dlkm.ko`, `q6_notifier_dlkm.ko`,
`q6_pdr_dlkm.ko`, `snd_event_dlkm.ko` (audio DLKMs used by TWRP's audio/ADSP
paths), `hwid.ko` (`CONFIG_MI_HARDWARE_ID=m`,
`arch/arm64/configs/vendor/xiaomi_QGKI.config:17`),
`mmhardware_sysfs_dlkm.ko` and `qti_battery_charger_main.ko`
(`CONFIG_QTI_BATTERY_CHARGER=m` in both fragments — note the module *file name*
is `qti_battery_charger.ko`, see the caveat in §6). The authoritative way to
settle the exact file names is to run the build and list what it produced; do
not extend this list by guessing.

## 5. The kernel-side work (needs user approval — NOT done)

In `S0SL/android_kernel_xiaomi_sm8350`, in one commit:

```sh
# ci/build-kernel.sh
FRAGMENTS=(
	"vendor/debugfs.config"
	"vendor/xiaomi_QGKI.config"
	"vendor/star_QGKI.config"      # mars/star/venus touch: fts + xiaomi_touchfeature
)
MAKE_TARGET="${MAKE_TARGET:-Image modules}"   # was: Image
```

then package the modules next to the existing release assets:

```sh
# after: MAKE_TARGET="Image modules" ./ci/build-kernel.sh
# (out/ is the O= dir; modules land next to their objects)
find out -name '*.ko' -print | wc -l                     # sanity: non-zero
find out -name '*.ko' -exec install -Dm644 {} modules/{} \;
# the ramdisk only needs the flat basenames, but keeping the tree + a
# modules.dep makes the dependency audit possible:
make -C . O=out ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- \
     INSTALL_MOD_PATH="$PWD/modules_root" modules_install
tar -C modules_root/lib/modules -czf dist/kernel-modules-<tag>.tar.gz .
```

The three touch symbols can be verified without a full build:

```sh
grep -E 'TOUCHSCREEN_ST_FTS_V521_SPI|TOUCHSCREEN_XIAOMI_TOUCHFEATURE' out/.config
# both must be =m
```

Both touch symbols are `tristate` and depend only on `I2C` /
`INPUT_TOUCHSCREEN` (see their `Kconfig` entries), so enabling them is a
one-line-per-symbol change with no dependency work.

## 6. Verification checklist (before this device tree is wired up)

1. **Module set exists and matches**: `tar tzf kernel-modules-*.tar.gz | grep -E
   'fts_touch_spi|xiaomi_touch|msm_drm'` — all three present.
2. **vermagic matches the `Image` we ship**:
   ```sh
   strings fts_touch_spi.ko | grep vermagic
   strings arch/arm64/boot/Image | grep -m1 'Linux version'
   ```
   The release string must be identical (also true for a `CONFIG_MODVERSIONS`
   `__versions` CRC check: a module built in the *same* build as the `Image`
   is automatically consistent).
3. **The ramdisk really contains them** after a CI run:
   ```sh
   magiskboot unpack boot.img          # or: ./scripts/unpack-ramdisk.sh
   ls ramdisk/lib/modules/             # *.ko + modules.load + modules.load.recovery
   cat ramdisk/lib/modules/modules.load.recovery
   ```
4. **The load lists are consistent**: every name in `modules.load.recovery`
   has a `.ko` next to it — a mismatch is fatal for the boot, not cosmetic
   (§2.1, §3 consequence 3).
5. **Runtime**: `adb shell dmesg | grep -iE 'fts|xiaomi_touch|msm_drm'` from
   recovery; TWRP's log (`/tmp/recovery.log`) prints
   `Checking directory: /lib/modules` and `Modules Loaded: N` from the module
   loader — that line is the direct measurement of whether the ramdisk path
   works.

## 7. Risks / open points

| # | risk | mitigation |
| --- | --- | --- |
| R1 | Enabling the mars touch configs changes the `Image` itself, so every existing BakaSU kernel release becomes stale for recovery use. | Build `Image` + modules in the same run, publish both as one release (or a new tag), and point `kernel_url` at it. |
| R1b | **Worst case of this whole plan: `modules.load.recovery` makes first-stage init `LOG(FATAL)` when any listed module cannot be loaded (§2.1), so a single wrong/mismatched `.ko` turns "no touch" into "does not boot".** | Derive the list from the shipped `.ko` set, build modules in the same run as the `Image`, verify the `vermagic` string, and keep `modules.blocklist` as the escape hatch. Keep the *old* recovery image flashable (a bad recovery-as-boot image can be replaced with `fastboot flash boot`). |
| R2 | `prebuilt/modules/*.ko` are GPL kernel modules inside this repo — fine to vendor, but they inflate the tree. | Keep them `.gitignore`d and fetch them in CI, exactly like `prebuilt/Image`. |
| R3 | Ramdisk size: the modules plus `depmod`-generated indexes add a few MB; `boot` is 192 MiB and `OF_USE_LZMA_COMPRESSION=1` already handles the fox ramdisk. | Watch the `boot.img` size in the CI log; drop unused modules from the list. |
| R4 | Module file names in the `device.mk` list are not all confirmed for this kernel (`qti_battery_charger.ko` vs `qti_battery_charger_main.ko`). | Derive the load list from the built files (`$(notdir $(wildcard ...))`) and copy the real names into `TW_LOAD_VENDOR_MODULES`. |
| R5 | Loading a module twice (init from `modules.load.recovery`, then TWRP from `/lib/modules`) is harmless: TWRP de-duplicates against `/proc/modules` before insmod'ing. | none needed |
