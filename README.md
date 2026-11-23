# PLF110（一加 Ace 5 竞速版）自编内核 + Droidspaces

> **状态：✅ 已实机验证可用（2026-11-23）**
> 自编内核 `6.1.134-g04555ae11869` 在本机成功启动（`boot_completed=1`），root、外设全部正常，
> **Droidspaces 容器（systemd / Azure Linux 3.0）已跑起来**，NAT 网络 + DNS 正常。

| 项目 | 结果 |
|---|---|
| 设备 | OnePlus PLF110 / MT6989 / Android 16（固件 16.0.2.401） |
| 内核 | `6.1.134-g04555ae11869`（CFI 开、LTO=none、KASAN_HW_TAGS，与原厂 ABI 对齐） |
| 内核模块 | 598 / 600 原厂模块加载成功（缺 2 个 OPLUS scx 性能调度模块，无外设影响） |
| root | FolkPatch 0.13.9（`su -c id` → `uid=0(root)`） |
| 外设 | 显示/触摸/按键/指纹/传感器(40)/WiFi/蓝牙/相机/音频/充电/USB/马达 全部验证通过 |
| 容器 | Droidspaces v7.2.0，`systemctl is-system-running` = **running**，容器 IP `172.28.186.11`，外网/DNS 通 |
| 启动耗时 | 开机到 `sys.boot_completed=1` 约 **22.8 秒** |

- 📄 完整技术记录（构建参数 / kABI 处理 / 符号完备性证明 / 实机验证 / 回滚）：**[docs/VERIFIED_BUILD.md](docs/VERIFIED_BUILD.md)**
- 📋 运行日志分析（开机→37 分钟：警告/崩溃/模块状态）：**[docs/RUNTIME_LOG_REPORT.md](docs/RUNTIME_LOG_REPORT.md)**
- 🧪 验证工具与基线数据：**[verify/](verify/)**
- 📦 全部成品镜像：**[Releases › `plf110-6.1.134-droidspaces-v1`](../../releases/tag/plf110-6.1.134-droidspaces-v1)**

---

## 一、直接下载使用（不自己编译）

Release 里一共有 9 个文件：

| 资产 | 内容 | 大小 | sha256（前 16 位） |
|---|---|---|---|
| `boot_run11_6.1.134.img` | **自编内核 + 原厂纯净 ramdisk**（无 root） | 64 MB | `c152ed9bfc5d1545…` |
| `folk_patched_115404_0.13.9_tklj.img` | **自编内核 + FolkPatch root**（推荐直接用） | 64 MB | `e5ef715770342ecc…` |
| `Image` | ARM64 内核镜像（打 boot 用） | 34.2 MB | `4fb42c92d0e3eca3…` |
| `System.map` | 符号表（调试/定位用） | 4.7 MB | `e6a278f3a7cc5f85…` |
| `kernel.config` | 最终内核配置 | 211 KB | `801c6b06217b36cf…` |
| `missing_symbols_run11.txt` | 相对原厂模块的符号缺口（22 个） | 716 B | — |
| `stock_boot_original.img` | **完整原厂 boot**（内核 `6.1.134-android14-11-o-g8f3b9b4f58d8`，零改动） | 64 MB | `16b0b00eb63ef046…` |
| `stock_boot_folkpatch_root.img` | **原厂内核 + FolkPatch root**（最稳救砖镜像） | 64 MB | `224794ed8a2d3aab…` |
| `stock_init_boot_original.img` | **原厂 init_boot**（完整回滚用） | 8 MB | `917dacdf28781f59…` |

> 完整 sha256 见 Release 页面（GitHub 会显示每个资产的 digest），或 `docs/VERIFIED_BUILD.md` 第六节。

### 刷入

```bash
adb reboot bootloader

# 自编内核（无 root）
fastboot flash boot boot_run11_6.1.134.img

# 或者：自编内核 + root（推荐）
fastboot flash boot folk_patched_115404_0.13.9_tklj.img

fastboot reboot
```

刷完验证：

```bash
adb shell uname -r                  # 应显示 6.1.134-g04555ae11869
adb shell getprop sys.boot_completed # 1
adb shell 'su -c id'                # 有 root 版应返回 uid=0(root)
```

### 回滚

```bash
adb reboot bootloader
fastboot flash boot stock_boot_original.img        # 完全原厂
# fastboot flash init_boot stock_init_boot_original.img   # 仅在动过 init_boot 时需要
fastboot reboot
```

⚠️ **本机 `fastboot boot`（临时启动）不支持**，只能 `flash`；解锁状态下校验已关闭，原厂镜像可直接刷。
⚠️ 刷机前请确认自己有可用的救砖镜像（Release 里就有）。

---

## 二、自己编译（GitHub Actions 云端，免费）

一条工作流完成：拉内核源码 + 厂商模块树 → 拉 Android clang → 打补丁 → 生成配置 → `make Image` → 硬断言校验 → 上传产物。

### 2.1 版本与工具链（当前固定）

| 项 | 值 |
|---|---|
| 内核源码 | `OnePlusOSS/android_kernel_oneplus_mt6989` @ `76bcc45d`（PLF110_16.0.3.500，6.1.134） |
| 厂商模块树 | `..._modules_and_devicetree_oneplus_mt6989` @ `efa5a76b`（**必须配套**，内核树有 8 个符号链接指向它） |
| 工具链 | Android clang **r487747c / 17.0.2**（与原厂 vendor 模块构建工具链完全一致） |
| 配置基线 | 本机原厂 `/proc/config.gz` → `config/plf110_stock.config` |

### 2.2 运行

1. 把本仓库内容推到你自己的 GitHub 仓库（Fork 或新建后上传均可，注意 `.github/` 是隐藏目录）
2. 仓库 → **Actions** → 左侧 **Build PLF110 kernel** → 右侧 **Run workflow**

| 输入 | 说明 |
|---|---|
| `lto` | `none`（默认，与原厂一致）；`thin` 为实验项，很慢，不建议 |
| `debug_info` | `false` = 精简构建；**`true` = 与原厂配置完全一致（KASAN_HW_TAGS/BTF/UBSAN 全开）——想兼容原厂 vendor 模块必须用 true** |

> 历史教训：`debug_info=true` 曾被 `config/features.env` 里的同名变量反向覆盖（run10 白编 16 分钟），现在 workflow 里有闸门：`features.env` 出现 `DEBUG_INFO/KABI_BYPASS/LTO_MODE` 会直接失败。

### 2.3 产物

`kernel-PLF110-A16-6.1.134-<序号>` artifact 内含：`Image`、`System.map`、`kernel.config`、`build.log`、`config_check.txt`、`stock_vs_final.diff`、`AK3_*.zip`（AnyKernel3 包，会丢 FolkPatch）。

---

## 三、关键技术点（这版为什么能跑起来）

### 1. 配置基线必须是原厂 `/proc/config.gz`

用 Google `gki_defconfig` 会缺 200+ 个原厂 `=y` 的 MTK/OPLUS 内置驱动 → 第一段 init 挂不上分区 → `Kernel panic: Attempted to kill init`。
原厂 config 里还混有**只存在于厂商模块树**的符号（`UFSFEATURE`、`DEVICE_MODULES_*` 等），GKI 树里没有对应 Kconfig，kconfig 会静默丢弃 —— 所以断言只挑真正的 GKI 符号（如 `ARCH_MEDIATEK`）。

### 2. kABI：CRC 不一致 ≠ ABI 不兼容

本机固件 `16.0.2.401` 的内核源码从未公开；用公开源码构建时，原厂 vendor 模块的 genksyms CRC 与本内核不一致
（51 个符号中 19 个不同，`module_layout` 原厂期望 `0xea759d7f`，本地算出 `0xb1ac0e57`）→ 模块被 `disagrees about version of symbol` 拒绝 → init 起不来。

但 CRC 只是类型摘要文本的哈希。用两个内核的 **BTF 段做全量结构体比对**：

- 10335 个公共结构体，**只有 5 个有差异**（`kmem_cache` 因 KASAN 开关；`oplus_task_struct` / `task_struct` / `rq` / `task_group` 为 OEM 内部字段或 `android_kabi_reserved` 命名差异）
- `struct module` 70 个字段**偏移完全相同**

结论：真实 ABI 兼容。因此 `patches/kabi_bypass.patch` 只改 `kernel/module/version.c` 里 `check_version()` 的 `bad_version` 分支（`return 0` → `return 1`，只警告不拒绝），开关 `KABI_BYPASS=true`。

### 3. KASAN 必须开，而且是 `KASAN_HW_TAGS`

`kasan_flag_enabled` 这个符号**只有 `CONFIG_KASAN_HW_TAGS`（MTE 硬件标签，运行时可开关）才导出**，而原厂有 22 个模块引用它（`monitor_hang`、`mali_kbase`、`wlan_drv`、`cfg80211` 等）。
只开 `CONFIG_KASAN=y` 不开 HW_TAGS 依然缺符号 → init 装模块失败。所以原厂这 5 项调试配置（KASAN / UBSAN / KFENCE / PAGE_OWNER / PANIC_ON_OOPS）本版本保持原厂原样。

### 4. 符号完备性证明（不用再"开机试错"）

把手机上 600 个已加载模块全部拉下来（`/vendor_dlkm` + `/system_dlkm` + `vendor_boot` ramdisk，共 646 个 `.ko`），解析 ELF 的 UND 符号全集，减去模块之间互相导出的符号，再与本内核 `System.map` 的 `__ksymtab_` 导出全集求差集：

- 需要内核符号 **3391** 个 / 本内核导出 **15309** 个 / **缺口 22 个**
- 22 个中：20 个只被第二阶段 OPLUS scx 调度模块引用（不影响启动）；2 个背光符号是 **WEAK**，内核加载器明确容忍

明细：`verify/missing_symbols_run11.txt`；方法：`verify/stock_needed.py`。

### 5. 其它构建修正

- `CONFIG_MODULE_SIG_KEY`：原厂值依赖 `$(DEVICE_MODULES_REL_DIR)`，在开源编译时展开为空 → 覆盖为内核默认 `certs/signing_key.pem`（一次性密钥；`MODULE_SIG_FORCE=n`，不影响加载原厂模块）
- LTO 与原厂一致用 `none`，CFI 保持开启
- Droidspaces 必需配置：`SYSVIPC`、`POSIX_MQUEUE`、`PID_NS`、`IPC_NS`、`USER_NS`、`UTS_NS`、`NET_NS`、`CGROUPS/MEMCG/CGROUP_FREEZER`、`SECCOMP(_FILTER)`、`OVERLAY_FS`、`TMPFS(_XATTR/_POSIX_ACL)`、`DEVTMPFS`、`VETH`、`BRIDGE`、`MACVLAN` 等（见 `scripts/prepare.sh`）

---

## 四、目录结构

```
.github/workflows/build.yml   # 云端编译流水线（拉源码/打补丁/编译/断言/上传）
config/
  plf110_stock.config         # 本机原厂 /proc/config.gz（配置基线）
  features.env                # 功能开关（true/false，改完重跑即可）
scripts/prepare.sh            # 打补丁 + 生成 defconfig + 符号断言
patches/
  kabi_bypass.patch           # 跳过 genksyms CRC 校验（只警告不拒绝）
docs/
  VERIFIED_BUILD.md           # 已验证版本的完整技术记录
  RELEASE_NOTES_v1.md         # Release 正文
verify/                       # 符号完备性 / boot 镜像校验 / 厂商模块基线
```

---

## 五、改功能

编辑 `config/features.env`，把对应项改成 `true` / `false`，提交后重新 Run workflow：

- `DROIDSPACES=true` —— 容器必需（默认开）
- 其余默认 `false`：`BBR` / `BBRv3` / `NET_SCHED` / `IP_SET_NAT` / `TTL_TARGET` / `SDP_CHARGE` / `NTSYNC` / `NTFS3` / `SQUASHFS` / `UNICODE_FIX` / `PERF_TWEAKS` / `EXTRA_FS` / `CONTAINER_NET` / `NET_DEFAULTS`

**关闭 ≠ 删除**：`prepare.sh` 会把每个关闭项写成 `# CONFIG_XXX is not set` 占位留在 defconfig 里，随时可改回。
⚠️ `Image` 是直接跑在 boot 分区的内核，**所有功能必须内置（`=y`）**，脚本已按此处理。

---

## 六、已知限制

1. **2 个 OPLUS scx 调度模块未加载**：`oplus_bsp_game_opt`（缺 4 个 `__tracepoint_android_vh_scx_*` 符号 → 加载失败）、`oplus_bsp_sched_ext`（依赖前者，未尝试）。公开内核源码没有 HMBIRD/scx 这部分（`CONFIG_HMBIRD_SCHED` 在各公开版本 Kconfig 中均不存在）。影响：OPLUS 游戏/性能调度不生效，原生调度与容器不受影响。
2. **`/data` 上无法挂载 overlayfs**：该 f2fs 实例（dm-77，带 inlinecrypt/compress/casefold 特性）的 dentry 被 overlayfs 判为 unsupported；`/metadata`(f2fs)、ext4、tmpfs 正常。原厂同样限制，Droidspaces 用 loop ext4 镜像作容器根文件系统，不受影响。
3. `SELinux = Permissive`（由 FolkPatch 设置，对容器有利）。
4. 本版本为对齐原厂 ABI 保留 KASAN/UBSAN，**未做性能瘦身**；瘦身版需要补 `kasan_flag_enabled` 等导出桩（后续可做）。

---

## 七、排错

| 现象 | 排查 |
|---|---|
| Actions 步骤标红 | 点开该步日志看 `::error::`；常见为网络超时（重跑）、补丁偏移变化 |
| 配置没生效 | 看日志开头 `===== 生效开关：... =====` 与实际 `.config`；workflow 已有 fail-fast 断言 |
| 刷完白屏/重启 | 进 fastboot 刷回 `stock_boot_original.img`；`adb` 起来后取 `/sys/fs/pstore/console-ramoops-0` 分析 |
| 模块加载失败 | `adb shell 'su -c "dmesg \| grep -i \"Unknown symbol\""'`，对照 `verify/missing_symbols_run11.txt` |
| 容器起不来 | `adb shell 'su -c "tail -50 /data/local/Droidspaces/Logs/droidspacesd.log"'` |

---

## 八、免责声明

刷机有风险（变砖、数据丢失、失去保修）。本仓库所有镜像均在本机实测通过，但**请自行确认已备份原厂 boot/init_boot**（Release 里提供了原厂镜像）。
不修改 `abl/xbl/tz/hyp/vbmeta` 等分区；刷写前请确认 `fastboot getvar unlocked` 为 `yes`。
