# 备份与救砖指南（mars / 小米 11 Pro）

> 背景：本机 `/data` 是 **metadata + FBE（凭据加密）**。v4.5 的 recovery 已经能解开 **metadata** 层，
> 但**用户的 CE（凭据级）存储仍需 gatekeeper 校验**（详见 [`V4.6-PLAN.md`](V4.6-PLAN.md) §2）。
> 因此在 recovery 修好之前，**"能开机时"备份是唯一能拿到明文数据、且跨设备可用的方式**。

---

## A. 在 Android 里备份（已 root 的系统，推荐）★

前提：手机正常开机、已 root（Magisk / KernelSU）、电脑上有 `adb`。

### A1. 媒体与用户文件（不需要 root）

```bash
adb pull /data/media/0  ./backup-media      # 照片/视频/下载/文档 = 内部存储
adb pull /data/media/0/Download ./backup-downloads   # 只取下载目录
```
（Android 11+ 的 `Android/data`、`Android/obb` 用 adb 拉不动，需要 root，见 A2。）

### A2. 应用数据与系统数据（需要 root）

**流式打包到电脑**（不占用手机存储，最稳）：

```bash
# 应用数据 + 系统设置 + wifi/keystore/蓝牙等 + 厂商数据
adb exec-out su -c 'tar -C /data -cf - --numeric-owner data system misc vendor user_de user' \
  > data-plain.tar

# 只备份应用数据（体积可控）
adb exec-out su -c 'tar -C /data -cf - --numeric-owner data' > data-app.tar

# 顺带把 Android/data、Android/obb 里的应用外部数据也带上（可选）
adb exec-out su -c 'tar -C /data/media/0 -cf - Android' > data-android-ext.tar
```
说明：
* `tar` 通过 `adb exec-out` 直接写到电脑，手机端不落盘 → 不会因为手机存储不足失败。
* 体积参考：纯应用数据常见 5-30 GB，`/data/media` 另算；USB 3 口下几十分钟量级。
* 想同时保留 SELinux 上下文可以加 `--selinux --xattrs`，但**跨 ROM 恢复时不要依赖它**（见 A4）。

### A3. 分区镜像（root，救砖必备；都很小）

```bash
for p in boot dtbo vendor_boot persist metadata modem; do
  adb exec-out su -c "dd if=/dev/block/by-name/$p bs=4M" > "$p.img"
done
# 想连 super（系统分区，十几 GB）一起备份的话：
adb exec-out su -c 'dd if=/dev/block/by-name/super bs=4M' > super.img
```
`persist`（传感器/校准、部分 keystore 状态）与 `metadata`（包裹 /data 密钥的 blob）**一定要备**。

### A4. 恢复（在 Android 里）

```bash
adb push data-plain.tar /sdcard/
adb shell su -c 'cd / && tar -C /data -xf /sdcard/data-plain.tar'
adb reboot
```
注意事项：
* **只在同一 ROM / 同一 Android 大版本上恢复**；跨版本恢复应用数据容易触发崩溃或 key 失效。
* 恢复后系统会在开机时重打 SELinux 标签；个别应用（银行/DRM）可能需要重新登录。
* 分区镜像恢复用 `fastboot`（`boot`/`dtbo`/`vendor_boot`）或 recovery（见 B4）。

---

## B. 在 recovery 里备份（v4.5 已可用，**无需解密 /data**）

recovery 能解开 metadata，所以**整盘密文镜像**是可以备份/恢复的；只是镜像本身是密文，
**只有同一台设备、TEE 与 `/persist`、`metadata` 完好时才能恢复后解密**。

### B1. 小分区镜像（推荐，几十 MB）

```bash
for p in boot dtbo vendor_boot persist metadata modem; do
  adb exec-out "dd if=/dev/block/by-name/$p bs=4M" > "$p.img"
done
```

### B2. `/data` 整盘裸镜像（密文，体积=你的 /data 实际占用）

```bash
adb exec-out 'dd if=/dev/block/by-name/userdata bs=4M' > userdata-raw.img
```
* 也可以取 TWRP 解开的 dm 设备（内容等价）：`/dev/block/mapper/userdata`。
* 想在机上直接落盘，请插 **OTG U 盘**并把镜像写到那里（`/tmp` 是内存盘，装不下）。
* 恢复：
  ```bash
  adb shell 'dd of=/dev/block/by-name/userdata bs=4M' < userdata-raw.img
  ```
  （流式写入，不需要手机上有空间。）

### B3. TWRP 自带的 Backup

* `Boot`、`DTBO`、`Persist`、`Metadata` 等分区备份正常可用。
* `Data`（文件级）备份在未解密 CE 时**只能拿到密文文件**，不要指望它能跨设备还原明文；
  需要 /data 内容时用 B2 的裸镜像，或在 Android 里用 A2 的明文备份。

### B4. 救砖常规顺序

1. `fastboot flash boot boot.img`（+ `dtbo`、`vendor_boot`，如果也刷过）
2. 仍起不来 → 重刷当前 ROM 的完整包（**不要**执行 `fastboot -w` / recovery 的 Factory Reset，否则 /data 被清）
3. /data 挂了但有 B2 的裸镜像 → 进 recovery，按 B2 恢复 `userdata`，并把 `metadata`、`persist` 一并恢复
4. 恢复后第一次开机可能较慢（系统重建 cache），属正常

### B5. 限制（务必知道）

* 裸镜像是**密文**：丢失 TEE/`/persist`、或换到另一台设备，镜像**无法解密**。
  所以"能跨设备保全数据"的只有 A2 的**明文**备份。
* `/data` 裸镜像里包含你的锁屏凭据、指纹、Wi-Fi、应用数据；请存放在加密盘或可信介质上。
* 备份/恢复过程中**不要断电**，尤其写入 `userdata`、`metadata`、`persist` 时。

---

## C. 一次性做完的推荐组合

| 内容 | 命令/位置 | 体积 |
| --- | --- | --- |
| 明文媒体 | A1 `adb pull /data/media/0` | 视照片视频 |
| 明文应用+系统数据 | A2 `data-plain.tar` | 5-30 GB |
| boot/dtbo/vendor_boot/persist/metadata/modem | A3 或 B1 | < 200 MB |
| `/data` 整盘裸镜像（兜底） | B2 `userdata-raw.img` | = /data 占用 |
| ROM 指纹与版本 | `getprop ro.build.fingerprint`、`getprop ro.build.display.id` | 文本 |

> 建议顺序：先在 Android 里做 A1+A2+A3（明文 + 小分区），再进 recovery 做 B2（裸镜像兜底）。
> A2 才是"换机/救砖后还能用"的那一份。
