# 小米 11 Pro（mars）OrangeFox v4 — `/data` 解密（FBE）+ recovery USB 修复 + 状态栏挖孔校准

产物：`/root/mi11/work/v4-dist/boot-v4.img`（= `/root/mi11/work/twrp-dist/boot-v4.img`，并复制到手机 `/sdcard/Download/`）

| 项目 | 值 |
| --- | --- |
| 大小 | **201 326 592 字节（192 MiB）** |
| sha256 | **`40d74db0ff5ee5efbfe5e84151738f012dec74c2cf2137c046df570de0853657`** |
| 内核 | LineageOS 23.2 stock `5.4.302-qgki-g7ede20c8692e`（与 v3 相同） |
| ramdisk | **GZIP**（与 v3 相同；内核只有 `CONFIG_RD_GZIP`/`LZ4`） |
| boot header cmdline | 完整串（含 `androidboot.usbcontroller=a600000.dwc3`、`androidboot.selinux=permissive`、`twrpfastboot=1`）——v3 这里**只有** `twrpfastboot=1` |
| 构建 | `~/fox_14.1`，`MARS_JOBS=12` → 实际执行 `mka -j12 bootimage`，`--skip-sync`（本次 4m48s） |
| 版本标记 | `TW_DEVICE_VERSION := mars-2`（用户可在"设置/关于"里确认） |

v4 = v3 + 四组改动：
1. **`/data` FBE 解密打开**（主线）
2. **recovery USB 修复**（用户已实测：关掉 MTP 就能连 adb → 病根是 gadget 缺 MTP 功能；已补 QTI USB init）
3. **解密 rc 的 import 补上**（构建系统没做，缺了它解密服务根本不存在）
4. **状态栏挖孔 + 屏幕几何校准**

---

## 1. `/data` 解密（FBE）— v4 主线

### 1.1 配置改动（以 OrangeFox `fox_14.1` 源码为准）

`device.mk`（替换原"PHASE 1: DISABLED"整块）：

```make
TW_USE_FSCRYPT_POLICY := 2          # → USE_FSCRYPT_POLICY_V2（/data 是 :v2+wrappedkey_v0）
TW_INCLUDE_CRYPTO := true           # fox_14.1 里这一个开关就够
TW_INCLUDE_CRYPTO_FBE := true       # 源码会自动置 true，这里写出来是为了意图明确
TW_INCLUDE_FBE_METADATA_DECRYPT := true
PRODUCT_PACKAGES += qcom_decrypt qcom_decrypt_fbe

PLATFORM_VERSION := 99.87.36
PLATFORM_VERSION_LAST_STABLE := $(PLATFORM_VERSION)
PLATFORM_SECURITY_PATCH := 2099-12-31
VENDOR_SECURITY_PATCH := $(PLATFORM_SECURITY_PATCH)
```

依据（逐条对源码）：

* `bootable/recovery/Android.mk:348-375`：只要 `TW_INCLUDE_CRYPTO == true`，就自动
  `TW_INCLUDE_CRYPTO_FBE := true`、加 `-DTW_INCLUDE_CRYPTO/-DUSE_FSCRYPT/-DTW_INCLUDE_FBE/
  -DTW_INCLUDE_FBE_METADATA_DECRYPT`，并把 **keystore2 全套**链进 recovery。
* `bootable/recovery/prebuilt/Android.mk:165-267`：`libkeymaster4support`、`libkeymaster4_1support`、
  `libpuresoftkeymasterdevice`、`libsoftkeymaster`、`android.hardware.keymaster@4.0/4.1.so`、
  `android.hardware.gatekeeper@1.0.so`、`libion`、`libxml2` 都自动进 ramdisk。
  ⇒ **`docs/PHASE2-CRYPTO.md` 里那条 `TARGET_RECOVERY_DEVICE_MODULES += libkeymaster4
  libpuresoftkeymasterdevice` 不需要**（A11 时代配方；vayu fox_14.1 也没写）。
* `BOARD_USES_QCOM_FBE_DECRYPTION := true` 已在 `BoardConfig.mk`（第一阶段就有）。
* `PLATFORM_SECURITY_PATCH` 放 `device.mk`：`build/make/core/version_util.mk:53` 有
  `ifdef PLATFORM_SECURITY_PATCH → $(error …)`，但那只是**该文件解析时**的限制；`envsetup.mk:369`
  先加载 product config（`device.mk`）、`:386` 才加载 board config → 合法且生效（构建日志
  `PLATFORM_VERSION=99.87.36`、无报错）。意义：TEE 的 anti-rollback 会拒绝"比密钥更旧"的客户端。

### 1.2 关键坑：decrypt rc 必须自己 import（构建系统不做）

`device/qcom/twrp-common/Android.mk` 的 post-install 本应把
`import /init.recovery.qcom_decrypt.rc` 追加到 `init.recovery.qcom.rc`，它只试
`TARGET_ROOT_OUT`、`TARGET_RECOVERY_ROOT_OUT`、以及一个**相对 recipe cwd** 的路径——在本构建系统
里三处都没生效（追加上去的文件随后被 ramdisk 组装覆盖）。**结果：ramdisk 里有
`init.recovery.qcom_decrypt.rc`，但没有任何 rc import 它 → init 不解析 → `qseecomd` /
`keymaster-4-1-qti` / `gatekeeper-1-0-qti` 三个服务根本不存在 → FBE 解密必然失败。**

**修法**：在设备树 `recovery/root/init.recovery.qcom.rc` 里写死
`import /init.recovery.qcom_decrypt.rc`（v4 已加，注释写明原因）。已核对最终 ramdisk：
`import /init.recovery.qcom_decrypt.rc` 在第 22 行 ✓，且
`init.recovery.qcom_decrypt.rc` 保留 `prepdecrypt/qseecomd/keymaster-4-1-qti`、
`.fbe.rc` 保留 `gatekeeper-1-0-qti/keystore_auth/keystore`
（`service_cleanup.bash` 只删掉了用不到的 keymaster 3.0/4.0/citadel 等 ✓）。

### 1.3 TEE/keymaster 厂商 blob（免用户手动 pull）

来源：**`TheMuppets/proprietary_vendor_xiaomi_sm8350-common` 分支 `lineage-23.2`**（`proprietary/…`），
与 LOS `android_device_xiaomi_sm8350-common` 的 `proprietary-files.txt` 逐条对应；该文件头部写明
blob 抽取自 **star `OS2.0.7.0.UKAMIXM`** —— 正是用户设备 **vendor 分区**的来源，所以 ABI 匹配、
不存在"跨 ROM blob 不匹配"。

放入设备树，构建时原样进 recovery ramdisk：

| 目标路径 | 文件 |
| --- | --- |
| `system/bin/` | `qseecomd`、`android.hardware.keymaster@4.1-service-qti`、`android.hardware.gatekeeper@1.0-service-qti` |
| `vendor/lib64/hw/` | `android.hardware.gatekeeper@1.0-impl-qti.so` |
| `vendor/lib64/` | `libQSEEComAPI` `libGPreqcancel` `libGPreqcancel_svc` `libdrmfs` `libdrmtime` `libdiag` `libkeymasterdeviceutils` `libkeymasterprovision` `libkeymasterutils` `libops` `libqcbor` `libqisl` `libqtikeymaster4` `librpmb` `libspcom` `libspl` `libssd` `libtime_genoff` `.so` |

（`recovery/root/vendor/lib64/` 里另有 v2 就从真机拉的三个显示库，保持不变。）

**验证（对 v4 最终 ramdisk 与 `recovery/root` 逐个 `ls`/`readelf`）**：

* 18 项全部就位：`init.recovery.qcom_decrypt.rc/.fbe.rc`、`qseecomd`、keymaster@4.1-service-qti、
  gatekeeper@1.0-service-qti、gatekeeper impl、`keystore2`、`libkeymint_support`、
  `libpuresoftkeymasterdevice`、`libkeymaster4support`、`libkeymaster4_1support`、
  `android.hardware.keymaster@4.1.so`、`android.hardware.gatekeeper@1.0.so`、`libxml2`、`libion` ✓
* 依赖核对（对 ramdisk 的 `/system/lib64`、`/vendor/lib64`、`/vendor/lib64/hw` 求闭包）：
  唯一未解析的是 `libops.so → libdrm.so`，而**没有任何我们需要的库依赖 libops**（vayu 有它，
  只作对齐），所以无害。
* 用户的 v3 日志也印证了方向：`Keymaster_Ver::Unable to find vendor manifest on the device …
  Checking the ramdisk manifest` → `Using keymaster version '4.x'`，即 keymaster HAL/库**必须**打进
  recovery ramdisk ✓（v4 就是这么做）。
* `frameworks` 侧走 AIDL keystore2 → `libkm_compat*` 把厂商的 HIDL keymaster@4.1 当 KeyMint 用
  ✓ 与 we ship 的 `android.hardware.keymaster@4.1-service-qti` 对得上。

### 1.4 一套配置同时服务 LOS 23.2（A16）与 HyperOS 2

`docs/FSTAB-DIFF.md` 已逐字比对：`/data` 的 FBE 参数在 TW-A11 / FOX-A13 / FOX-A14-VAYU / LOS-A16
四棵树完全一致；OrangeFox 对 sm8350 的唯一功能性改动是给 `/metadata` 加 `wrappedkey`（本树已有）。
用户 v3 的 `/tmp/recovery.log` 也印证 fstab 参数被正确解析：
`FBE contents 'aes-256-xts', filenames 'aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0'`、
`Metadata contents 'aes-256-xts', filenames 'wrappedkey_v0'`、
`setting Key_Directory to: /metadata/vold/metadata_encryption` ✓
**没有发现任何两代之间不同的加密参数** → v4 的 fstab/crypto 配置对两个 ROM 通用。

---

## 2. recovery USB（adb/MTP/sideload）— 根因与修复

### 2.1 结论（含用户实测）

**病根：gadget 里缺 MTP 功能（`functions/mtp.gs0` + `os_desc`）→ 任何含 `mtp` 的组合
（`sys.usb.config=mtp,adb`）整组绑定失败 → 主机侧看不到任何 USB 设备 → adb/MTP 全废；
只写 `adb` 就能绑上。** 用户实测：**关闭 MTP 后 adb 立刻可用** ✓ 完全对上。

为什么缺：我们照抄了 vayu 的 `TW_EXCLUDE_DEFAULT_USB_INIT := true`，却**没有**把 vayu 同时提供的
QTI configfs `init.recovery.usb.rc` 放进树里。TWRP 自己的 `init.rc` 虽然会建
`/config/usb_gadget/g1` 和 `ffs.adb`，但它**不建 `mtp.gs0`、也不建 `os_desc`**，更没有
`sys.usb.config=mtp,adb` 的 configfs 触发器 → MTP 组合永远配不起来。而 TWRP 的 `init.rc` 里本来
就有一行 **`import /init.recovery.usb.rc`**（文件不存在时等于一直在报导入失败）。

**sideload 卡死**是同一根因的下游：`twrpinstall/adb_install.cpp:317-345` 的
`SetUsbConfig("sideload")` → `WaitForProperty("sys.usb.state","sideload")`，**没有超时**；
gadget 起不来就永久阻塞 → "正在启用/正在取消 ADB Sideload" 卡住。

### 2.2 v4 的修复

| 改动 | 位置 | 作用 |
| --- | --- | --- |
| 新增 `recovery/root/init.recovery.usb.rc` | 设备树 | QTI configfs gadget（与 `OrangeFox/device/vayu` **逐字节相同**，sha256 `bacf6b892889cee51aa1f775484426ca64b00f6beee95fcf42f661347d302a5a`）：建 `/config`、`ffs.adb`、**`mtp.gs0` + `os_desc(MSFT100)`**、`configs/b.1`，并为 `none/adb/mtp,adb/mtp/mass_storage,adb` 各写 UDC + `setprop sys.usb.state`。**这就是"关 MTP 才能用 adb"的对症修复** |
| `BOARD_MKBOOTIMG_ARGS += --cmdline "$(BOARD_KERNEL_CMDLINE) twrpfastboot=1"` | `BoardConfig.mk` | **另一个真实缺陷**：v3 镜像的 boot header cmdline **恰好只有** `twrpfastboot=1`，设备树里那一整串 `BOARD_KERNEL_CMDLINE` 全被丢掉了（在这棵构建系统里 RBC 路径会 strip `BOARD_KERNEL_CMDLINE`，见 `board_config.mk:27/240-263`、`308`）。丢掉的包括 `androidboot.selinux=permissive`（recovery 本该 permissive）和 `video=vfb:…`。**注意：`sys.usb.controller` 有值（`a600000.dwc3`，bootloader 会补），所以它不是本次 adb 失效的原因**，但这类参数丢失迟早会咬人 |
| `on init … setprop sys.usb.controller a600000.dwc3` | `init.recovery.qcom.rc` | 兜底（与 `ro.boot.usbcontroller` 同值），防止将来 cmdline 再丢 |

### 2.3 v4 的验证要点（给用户）

```
getprop sys.usb.config      # 期望 mtp,adb（MTP 保持开启）
getprop sys.usb.state       # 期望 mtp,adb
termux-adb devices          # 期望能看到设备（MTP 开着）
cat /proc/cmdline           # 期望含 androidboot.usbcontroller=… androidboot.selinux=permissive twrpfastboot=1
# sideload：进 ADB Sideload 界面再取消，应立刻回到主界面（不再卡死）
```

---

## 3. 逻辑分区（super）`unable to update logical partition` — 根因已查明，**v4 未改**（建议 v5）

`partitionmanager.cpp:4661-4684`（`Prepare_Super_Volume`）：

```cpp
#ifdef AB_OTA_UPDATER
    blk_device_partition = bare_partition_name + Get_Active_Slot_Suffix();  // "system_a"
#else
    blk_device_partition = bare_partition_name;                            // "system"  ← 我们走这条
#endif
    if (!fs_mgr_update_logical_partition(&fstabEntry)) { /* unable to update logical partition */ }
```

而 `fs_mgr_update_logical_partition`（`system/core/fs_mgr/fs_mgr.cpp:1117`）只是
`DeviceMapper::GetDmDevicePathByName(entry->blk_device, …)`——**按名字查 dm 设备、不会创建**。
真机 `/dev/block/mapper` 里的名字是 `system_a/product_a/vendor_a/…`，TWRP 查的是 `system/product/…`
→ 查不到 → 7 个逻辑分区全部被从 TWRP 分区表里删掉。**与 `-cow`（vAB 快照残留）无关**。

根因是我们树里**故意没设** `AB_OTA_UPDATER`（`KNOWN_ISSUES I15` 的老问题：`OF_AB_DEVICE` 已废弃，
`FOX_AB_DEVICE=1` 会让 `orangefox.mk:170` 给 `KATI_READONLY` 的 `AB_OTA_UPDATER` 赋值 → kati 报错）。

**正确修法（v5，需要单独一轮）**：`BoardConfig.mk` 早期设 `AB_OTA_UPDATER := true`（+`AB_OTA_PARTITIONS`）
→ `orangefox.mk:169` 为假、170 不执行，同时拿回 A/B 感知。但注意 `AB_OTA_UPDATER=true` 会让
`bootable/recovery/prebuilt/Android.mk:278-281` 多拷 4 个文件（`system/bin/update_engine_sideload`、
`vendor/.../hw/android.hardware.boot@1.0/1.1/1.2-service`），这些在我们树/厂商 blob 列表里都没有 →
**会直接构建失败**；所以要么给这几行加 wildcard 守卫，要么补 `boot@1.2-service` + `libboot_control`
blob。**影响面**：在那之前，"刷要写逻辑分区的 ROM/vendor zip"会失败；刷 boot/dtb/vbmeta、
备份/恢复 data/boot、刷只改 /data/boot 的 zip 正常。

---

## 4. 状态栏挖孔 + 屏幕几何（v4）

`fox_mars.mk`：

```make
OF_SCREEN_H := 2400          # 原 3200
OF_STATUS_H := 137           # 原 90
OF_STATUS_INDENT_LEFT := 216 # 原 48
OF_STATUS_INDENT_RIGHT := 48
OF_HIDE_NOTCH := 1
OF_CLOCK_POS := 1
```

依据：

* **用户的 v3 日志直接证实了几何问题**：`I:Scaling theme width 1.333333x and height 0.975000x,
  offsets x: 0 y: 80 w: 0 h: -80` → 横向 1.333、纵向 0.975（差 37%，画面被横向拉长）。
  改成 2400 后 `scale_h = (3200-80)/2400 = 1.30`，与 1.333 基本一致 ✓（0.975 是因为 fb 是
  1440×3200 而 OF_SCREEN_H 写成面板原生高度）。
* **挖孔几何**（设备自己的 overlay）：`config_mainBuiltInDisplayCutout = "M 0,0 H 208 V 137 H 0 V 0 Z @left"`、
  `status_bar_height_portrait = 137px` ⇒ 左上角 208×137 px 挖孔、系统状态栏 137 px。
* 主题默认时钟在**左**（`vars.xml: center_clock = 2`），x = `status_indent_left`、y = `status_info_y`；
  原 48 正好压在挖孔里 ✗ → 216（>208）移到挖孔右侧 ✓。
* `OF_STATUS_H = 137` 与 ROM 自己的状态栏高度一致；主题还用 `cutout_w = status_h - 72` 给内容留内边距。
* `TW_Y_OFFSET/TW_H_OFFSET = 80/-80` 保留（整套 sm8350 树的既有值，日志里也证实 offset y=80）。

**运行时临时调整**：Fox 设置 → 状态栏/界面（`ext_custom_status`）→ **时钟位置** 左/中/右
（默认左），旁边还有"隐藏刘海"开关。

---

## 5. 截图里其它信息的判读

| 截图信息 | 结论 | 影响 |
| --- | --- | --- |
| `Unable to find partition for path '/system_root'`（×7） | TWRP 把 fstab 的 `/system` 内部改名为 `/system_root`（`partition.cpp:477-488`），另有一些旧路径查询按 `/system_root` 找不到就报这句（`partitionmanager.cpp:951`） | **不影响**；TWRP 本来就把 system 设成 `Can_Be_Backed_Up=false`，不做 system 备份 |
| `* Storage is not encrypted` | v3 是 `TW_INCLUDE_CRYPTO := false`，`partition.cpp:698-780` 整段被编译掉、走 `#else` | v4 后会变成 `Storage is encrypted` 并进解密 |
| `E:Unknown MTP message type: 1` | `partitionmanager.cpp:3270`：请求 `MTP_MESSAGE_ADD_STORAGE`(=1) 但 `Part::Is_Mounted()` 为假 → 落到 `else` | v4 解密后消失（请求的就是未解密的 /data） |
| `Unhandled flag: 'sysfs_path=…ufshc'` | TWRP 的 fstab 解析器不认识这个 flag，只打日志、继续（该 flag 是 vold/fs_mgr 用的） | 无害；**不必删**（保留它与 ROM 侧 fstab 一致更安全） |
| `init: Service 'logd' … received signal 6` | recovery 里的 logd 崩溃 abort，常见于精简 ramdisk（不影响属性/日志落盘：`/tmp/recovery.log` 一直有内容） | 低优先级；若 v4 仍有可再看 |
| `Fingerprint … OS2.0.7.0.UKAMIXM` | vendor 分区（HyperOS 底层）残留；用户系统是 LOS 23.2 | 不影响解密 |

---

## 6. 产物与取回

* 容器：`/root/mi11/work/v4-dist/boot-v4.img`
* 手机：`/sdcard/Download/boot-v4.img`（`gzip -9` 后 48.4 MB < 桥的 64 MiB 上限 →
  `/app/export` → 设备侧 `cp` → 用户 Termux 里 `gunzip`）
* sha256/大小：见文首表格；同内容写入 `BUILD-INFO-v4.txt`
* 设备树改动：服务器 `~/twrp-mars`，commit/push 带 `[skip ci]`（不触发云构建）

## 7. 用户测试步骤

```sh
# 不刷写，只启动
fastboot boot boot-v4.img
```

1. **USB/adb（保持 MTP 开启）**：`getprop sys.usb.config` / `sys.usb.state` 应为 `mtp,adb`；
   `termux-adb devices` 应能看到设备；`cat /proc/cmdline` 应含完整串。
2. **解密**：应出现解密/密码界面。输入锁屏密码 → `/data` 挂上、内部存储可见：
   ```sh
   termux-adb -s <SN> shell 'ls /sdcard'
   termux-adb -s <SN> shell 'grep -iE "decrypt|crypt|fbe|keymaster|qseecom" /tmp/recovery.log'
   ```
3. **刷 zip**：把 zip `termux-adb push` 到 `/tmp/`，再用 Install 选择它（不依赖内部存储）。
4. **回滚**：`fastboot boot` 不写分区；刷回 ROM 的 stock boot.img 即恢复。

## 8. 未决 / 风险

* 解密能否一次成功必须真机验证（`wrappedkey` 需要 TEE 真解包）。失败时按第 9 节抓日志。
* 逻辑分区（第 3 节）：v4 **未改**，刷 ROM/vendor 类 zip 仍会失败 → 建议 v5 处理。
* `PLATFORM_SECURITY_PATCH := 2099-12-31` 只改 recovery 自己的
  `ro.build.version.security_patch`；`BOARD_AVB_BOOT_ROLLBACK_INDEX` 不受影响。

## 9. 若还需要诊断：OrangeFox Terminal 命令清单

```
cat /proc/cmdline
getprop | grep -iE "usb|adb"                    # sys.usb.config / state / ffs.ready
getprop | grep -iE "crypto|fbe|keymaster|keystore|vold"
ps -A | grep -iE "adbd|minadbd|qseecomd|keymaster|gatekeeper|keystore"
ls -l /dev/qseecom /dev/ion /dev/usb-ffs/adb/ /dev/block/mapper
mount | grep -E "configfs|functionfs|metadata|data"
ls -l /metadata /metadata/vold 2>&1
dmesg | tail -40
```
