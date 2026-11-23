# PLF110（一加 Ace 5 竞速版）自编内核 + Droidspaces + NTsync

> **状态：✅ v2 已实机验证可用（2026-11-23）**
> 自编内核 `6.1.134-g9d2fb6767847` 在本机成功启动（`boot_completed=1`），root、外设正常，
> Droidspaces 容器跑通，并且新增：**NTsync（Wine/Windows 程序）**、**容器 CPU/PID 限额**、
> **IPv6 NAT**、**CVE-2026-43499 修复**。

| 项目 | 结果 |
|---|---|
| 设备 | OnePlus PLF110 / MT6989 / Android 16（固件 16.0.2.401） |
| 内核 | `6.1.134-g9d2fb6767847`（CFI 开、LTO=none、KASAN_HW_TAGS，与原厂 ABI 对齐） |
| 内核模块 | **598 / 600** 原厂模块加载成功（`lsmod` 输出 599 行含表头；缺 2 个 OPLUS scx 性能调度模块，无外设影响） |
| root | FolkPatch 0.13.9（`su -c id` → `uid=0(root)`） |
| 容器 | Droidspaces v7.2.0，`systemctl is-system-running` = **running**，IP `172.28.186.11`，外网/DNS 通 |
| 新增能力 | ✅ NTsync（`/dev/ntsync`，实测 ioctl PASS）｜✅ `--cpus` / `--pids-limit` 生效｜✅ IPv6 NAT｜✅ CVE 修复 |
| `droidspaces check` | **全绿**（含 IPv6 NAT / CPU limit / Process limit 三项，v1 时是 ✗） |
| 启动耗时 | 开机到 `sys.boot_completed=1` 约 **22~30 秒** |

- 📄 完整技术记录（构建参数 / kABI 处理 / 符号完备性证明 / 实机验证 / 回滚）：**[docs/VERIFIED_BUILD.md](docs/VERIFIED_BUILD.md)**
- 📋 运行日志分析（开机→37 分钟：警告/崩溃/模块状态）：**[docs/RUNTIME_LOG_REPORT.md](docs/RUNTIME_LOG_REPORT.md)**
- 🧪 验证工具与基线数据：**[verify/](verify/)**
- 📦 全部成品镜像：**[Releases › `plf110-6.1.134-droidspaces-v2`](../../releases/tag/plf110-6.1.134-droidspaces-v2)**
  （原厂回滚镜像在 [v1](../../releases/tag/plf110-6.1.134-droidspaces-v1)）

---

## 一、直接下载使用（不自己编译）

v2 Release 里有 5 个文件（原厂回滚镜像在 v1 Release）：

| 资产 | 内容 | 大小 | sha256 |
|---|---|---|---|
| `folk_patched_115404_0.13.9_hfxt.img` | **自编内核 + FolkPatch root**（推荐直接用） | 64 MB | `1d44445a598ed6a162399d526bbede90b96f4225ddf50618c164559632f7e0b1` |
| `boot_run13_6.1.134.img` | 自编内核 + 原厂纯净 ramdisk（无 root） | 64 MB | `4db24326d9a8d47fc8351e94e3490126beb5dd5c0e4f1e8ce0f2dcc0d85d49bd` |
| `Image` | ARM64 内核镜像（打 boot 用） | 34.7 MB | `2c3cabcf146f455742e39d2463090276b6b5ac67a189c6e4ecae61f056da6583` |
| `System.map` | 符号表（调试/定位用） | 4.8 MB | `bc3a0e601944c0991bebc336493c7d5eff05920fc8686ab409ad64fda9987621` |
| `kernel.config` | 最终内核配置 | 207 KB | `58945c88000987d1d05a359fd8d213ad6e4b6d473341f042f6ae286895ca5333` |

v1 Release 里的原厂回滚镜像（刷机前建议下载放着）：

| 资产 | 内容 | sha256（前 16 位） |
|---|---|---|
| `stock_boot_original.img` | **完整原厂 boot**（零改动） | `16b0b00eb63ef046…` |
| `stock_boot_folkpatch_root.img` | **原厂内核 + FolkPatch root**（最稳救砖镜像） | `224794ed8a2d3aab…` |
| `stock_init_boot_original.img` | 原厂 init_boot（完整回滚用） | `917dacdf28781f59…` |

> 完整 sha256 见 Release 页面，或 `docs/VERIFIED_BUILD.md`。

### 刷入

```bash
adb reboot bootloader

# 推荐：自编内核 + root（NTsync / 容器限额全都有）
fastboot flash boot folk_patched_115404_0.13.9_hfxt.img

# 或自编内核（无 root）
# fastboot flash boot boot_run13_6.1.134.img

fastboot reboot
```

刷完验证：

```bash
adb shell uname -r                  # 应显示 6.1.134-g9d2fb6767847
adb shell getprop sys.boot_completed # 1
adb shell 'su -c id'                # 有 root 版应返回 uid=0(root)
adb shell 'su -c "ls -l /dev/ntsync"'                    # crw------- root root 10,125
adb shell 'su -c "/data/local/Droidspaces/bin/droidspaces check"'   # 全绿
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

> 历史教训：
> - `debug_info=true` 曾被 `config/features.env` 里的同名变量反向覆盖（run10 白编 16 分钟），现在 workflow 里有闸门：`features.env` 出现 `DEBUG_INFO/LTO_MODE` 会直接失败。
> - **run12 用了 `debug_info=false` 直接白屏**：KASAN 一关，原厂 `monitor_hang.ko` 就缺 `kasan_flag_enabled` 符号 → init 0.32 秒 `Attempted to kill init` panic。**本机必须用 `debug_info=true`**（run13 已验证）。

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

### 6. 第二批补丁：NTsync / 容器限额 / CVE / IPv6 NAT（v2 新增）

补丁来源 [Goldzxcbug/Droidspaces_Kernel_patch](https://github.com/Goldzxcbug/Droidspaces_Kernel_patch) @ `dc0f76b`，
已 vendored 到 `patches/ds_*.patch`（该仓库测试机型表没有 PLF110/MT6989/16.0.3.500，本项目做了适配与实机验证）：

| 补丁 | 作用 | 验证 |
|---|---|---|
| `ds_ntsync_base.patch` + `ds_ntsync_compat_android14-6.1.patch` | NT 同步原语（`drivers/misc/ntsync.c`，`/dev/ntsync`） | 容器内/宿主均通过 CREATE_SEM/RELEASE/READ/EVENT ioctl |
| `ds_cgroup_limits_6.1.patch` | 在 KMI 冻结内核上安全打开 `CGROUP_PIDS` + `CFS_BANDWIDTH`（ABI 可见数组保持原边界） | `--cpus 2 --pids-limit 200` 生效，`droidspaces check` 两项 ✗→✓ |
| `ds_cve_userns_rtmutex_6.1.patch` | CVE-2026-43499 user-ns rtmutex 提权修复 | 已打上（`rtmutex.c` 含 `waiter_task`） |
| 配置开关 | `CONFIG_IP_SET*` / `IP6_NF_NAT` / `IP6_NF_TARGET_MASQUERADE` | `ip6tables -t nat` 可用，check ✗→✓ |

`scripts/prepare.sh` 里每个补丁都**先 `patch --dry-run` 全量校验再应用**，失败立即中断构建，避免半套改动。
本地对 6.1.134 源码逐一 dry-run 验证：上下文全部命中，只有行号偏移、无 fuzz 失败。

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
  ds_ntsync_base.patch        # NTsync 驱动（Wine/Windows）
  ds_ntsync_compat_android14-6.1.patch
  ds_cgroup_limits_6.1.patch  # CGROUP_PIDS + CFS_BANDWIDTH（KMI 兼容）
  ds_cve_userns_rtmutex_6.1.patch
  README.md                   # 补丁来源/固定提交/sha256
docs/
  VERIFIED_BUILD.md           # 已验证版本的完整技术记录（含 v2 run13）
  RELEASE_NOTES_v1.md         # v1 Release 正文
  RELEASE_NOTES_v2.md         # v2 Release 正文
verify/                       # 符号完备性 / boot 镜像校验 / 厂商模块基线
```

---

## 五、改功能

编辑 `config/features.env`，把对应项改成 `true` / `false`，提交后重新 Run workflow：

- `DROIDSPACES=true` —— 容器必需（默认开）
- v2 默认开启：`NTSYNC`（Wine/Windows）、`CGROUP_LIMITS`（容器 CPU/PID 限额）、`USERNS_CVE`（CVE 修复）、`IP_SET_NAT`（IPv6 NAT）
- 其余默认 `false`：`BBR` / `BBRv3` / `NET_SCHED` / `TTL_TARGET` / `SDP_CHARGE` / `NTFS3` / `SQUASHFS` / `UNICODE_FIX` / `PERF_TWEAKS` / `EXTRA_FS` / `CONTAINER_NET` / `NET_DEFAULTS`

**关闭 ≠ 删除**：`prepare.sh` 会把每个关闭项写成 `# CONFIG_XXX is not set` 占位留在 defconfig 里，随时可改回。
⚠️ `Image` 是直接跑在 boot 分区的内核，**所有功能必须内置（`=y`）**，脚本已按此处理。

---

## 六、已知限制

1. **2 个 OPLUS scx 调度模块未加载**：`oplus_bsp_game_opt`（缺 4 个 `__tracepoint_android_vh_scx_*` 符号 → 加载失败）、`oplus_bsp_sched_ext`（依赖前者，未尝试）。公开内核源码没有 HMBIRD/scx 这部分（`CONFIG_HMBIRD_SCHED` 在各公开版本 Kconfig 中均不存在）。影响：OPLUS 游戏/性能调度不生效，原生调度与容器不受影响。
2. **`/data` 上无法挂载 overlayfs**：该 f2fs 实例（dm-77，带 inlinecrypt/compress/casefold 特性）的 dentry 被 overlayfs 判为 unsupported；`/metadata`(f2fs)、ext4、tmpfs 正常。原厂同样限制，Droidspaces 用 loop ext4 镜像作容器根文件系统，不受影响。
3. `SELinux = Permissive`（由 FolkPatch 设置，对容器有利）。
4. 本版本为对齐原厂 ABI **保留原厂调试配置**（KASAN_HW_TAGS / UBSAN / KFENCE / PAGE_OWNER / PANIC_ON_OOPS），**未做性能瘦身**。
   实测：`debug_info=false`（关 KASAN）会直接白屏（原厂 `monitor_hang.ko` 缺 `kasan_flag_enabled` → init panic）。
   瘦身版需要先补 `kasan_flag_enabled` 导出桩，属于后续可做项。
5. **构建参数**：本机必须 `debug_info=true`（run13 验证）；run12 误用 false 导致白屏，日志已归档在 `docs/VERIFIED_BUILD.md`。

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

---

<details>
<summary>🥚 彩蛋（点开有惊喜）</summary>

📖 **[内核日记：两天从白屏到 NTsync 的草生长征](docs/DIARY.md)**

一份带体温的工程考古记录：白屏三连、pstore 尸检、CRC 吵架式验亲、与 PID 1 斗智斗勇、USB 的三种状态、PowerShell 六坑，以及"599 行里其实有一行是表头"这种只有踩过坑才知道的细节。

> 建议在摸鱼时阅读，不建议在写代码前阅读。

</details>
