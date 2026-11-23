# 已验证可启动版本（GitHub Actions run #11）

> 这份文档记录 **2026-11-23** 在本机（OnePlus ACE 5 Racing / PLF110 / MT6989 / Android 16）
> 上第一次成功启动自编内核、并跑起 Droidspaces 容器的完整结果。
> 结论：**内核、root、外设、容器全部打通。**

## 一、结论速览

| 项目 | 结果 |
|---|---|
| 内核启动 | ✅ `boot_completed=1`，`uname -r` = `6.1.134-g04555ae11869` |
| 内核模块 | ✅ 598 / 600 原厂模块加载成功（缺 2 个 OPLUS scx 性能调度模块，无外设影响） |
| root | ✅ FolkPatch 0.13.9 重打补丁后 `su -c id` → `uid=0(root) context=u:r:magisk:s0` |
| 外设 | ✅ 显示/触摸/按键/指纹(3 枚)/传感器(40/40)/WiFi/蓝牙/相机(拍照)/音频/充电/USB/马达(实测有震感) |
| Droidspaces | ✅ v7.2.0，容器 ID 1 运行中，`systemctl is-system-running` = **running** |
| 容器网络 | ✅ eth0=172.28.186.11/16（DHCP），宿主机↔容器 0.32ms，容器→外网 ping 通，DNS 解析 github.com 成功 |
| 容器系统 | Microsoft Azure Linux 3.0（systemd，根文件系统为 loop52 ext4 3.9G，652M 已用），`tdnf 3.5.8` 可用 |

## 二、本版本的构建参数

| 项 | 值 |
|---|---|
| 内核源码 | `OnePlusOSS/android_kernel_oneplus_mt6989` @ `76bcc45d34eac1a834830b356d0589020f4be059`（同步版本 PLF110_16.0.3.500，6.1.134） |
| 厂商模块树 | `OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_mt6989` @ `efa5a76b4a472e8dfbeea906fb6c05e931334e68`（必须配套，内核树有 8 个符号链接指向它） |
| 工具链 | Android clang **r487747c / 17.0.2**（`Android (10087095, +pgo, +bolt, +lto, -mlgo, based on r487747c)`）——与原厂 vendor 模块构建工具链完全一致（从 `adsp-v2.ko` 的 `.comment` 段验证） |
| 配置基线 | 本机原厂 `/proc/config.gz`（`config/plf110_stock.config`，9097 行） |
| LTO | `none`（与原厂一致） |
| CFI | `clang`（与原厂一致） |
| KASAN | `KASAN_HW_TAGS`（MTE 硬件标签，与原厂一致；`kasan_flag_enabled` 只有这个模式才导出，22 个原厂模块依赖它） |
| 版本串 | `6.1.134-g04555ae11869` |
| 构建记录 | GitHub Actions run #11，commit `04555ae` |
| Image | 35,838,464 B，sha256 `4fb42c92d0e3eca33df1e9dc4eb370e54d7e44507c602d2e326202d92d34d73d` |

## 三、kABI 问题与处理（本版本能启动的核心）

**现象**：自编内核启动到 0.33 s 时 init 装载 `/lib/modules/monitor_hang.ko` 失败 → `Unknown symbol kasan_flag_enabled` → init 退出（exit 127）→ `Kernel panic - not syncing: Attempted to kill init!` → 白屏重启。

**根因**：本机固件 `PLF110_16.0.2.401`（2025-12-09 构建）的内核源码从未公开，公开仓库只有 16.0.0.203 / 16.0.3.500 / 16.0.5.701 / 16.0.9.402。用公开源码构建时，原厂 vendor 模块的 genksyms CRC 与本内核算出来的不一致（51 个符号里 19 个不同，`module_layout` 原厂期望 `0xea759d7f`，本地算出 `0xb1ac0e57`）。

**关键判断**：CRC 只是"类型摘要文本"的哈希，并不等于真实 ABI。用两个内核的 BTF 段做全量结构体比对：

- 10335 个公共结构体，**只有 5 个有差异**：`kmem_cache`（因 KASAN 开关）、`oplus_task_struct`、`task_struct`、`rq`、`task_group`（均为 OEM 内部字段/命名差异）
- `struct module` 70 个字段**偏移完全相同**
- 因此真实 ABI 兼容，可以安全地跳过 CRC 校验

**做法**：`patches/kabi_bypass.patch` —— 只改 `kernel/module/version.c` 里 `check_version()` 的 `bad_version` 分支：`return 0` → `return 1`（只打警告，不拒绝加载）。开关 `KABI_BYPASS=true` 在 `config/features.env`。

## 四、符号完备性证明

为了不再"装到第 N 个模块挂一次"，做了完备性证明：

1. 从手机拉全部原厂模块：`/vendor_dlkm/lib/modules` 320 个 + `/system_dlkm/lib/modules` 56 个 + `vendor_boot` 分区 ramdisk 里的 270 个（first-stage，`modules.load` 245 条）
2. 解析每个 `.ko` 的 ELF 符号表 → **UND 符号全集**；减去模块之间互相导出的符号
3. 用本内核 `System.map` 的 `__ksymtab_<name>` 标签求**导出全集**
4. 差集 = 会上报 `Unknown symbol` 的完整名单

**结果（本版本）**：需要 3391 个内核符号 / 导出 15309 个 / **缺 22 个**，且：

- 20 个只被 `oplus_bsp_sched_ext`、`oplus_bsp_game_opt` 两个 **第二阶段**模块引用（OPLUS HMBIRD/scx 调度；公开源码里没有 `CONFIG_HMBIRD_SCHED` 这段代码）→ 装不上不影响开机
- 2 个背光符号被 first-stage 的 `leds-mtk-disp` 引用，但是 **WEAK 弱符号**，内核加载器明确容忍（`kernel/module/main.c`：`Ok if weak or ignored`）

明细见 `verify/missing_symbols_run11.txt`，原厂已加载模块基线见 `verify/proc_modules_baseline.txt`。

## 五、实机验证命令（可复现）

```bash
# 内核
adb shell uname -a                  # 6.1.134-g04555ae11869
adb shell getprop sys.boot_completed   # 1

# root
adb shell 'su -c id'                # uid=0(root) context=u:r:magisk:s0

# 模块加载数（原厂基线 600）
adb shell 'cat /proc/modules | wc -l'

# 命名空间（容器必需）
adb shell 'ls /proc/self/ns'        # cgroup ipc mnt net pid time user uts

# 容器状态
adb shell 'su -c "ps -A | grep -E "droidspaces|systemd""'
adb shell 'su -c "cat /data/local/Droidspaces/Containers/1/container.config"'
adb shell 'su -c "tail -20 /data/local/Droidspaces/Logs/1/log"'

# 容器内命令（不需要 apt，直接 nsenter）
adb shell 'su -c "nsenter -t <容器systemd PID> -m -p -- /usr/bin/uname -a"'
adb shell 'su -c "nsenter -t <容器systemd PID> -n -- /system/bin/ping -c 2 223.5.5.5"'
```

## 六、镜像与校验值

| 文件 | 说明 | size | sha256 |
|---|---|---|---|
| `boot_run11_6.1.134.img` | **自编内核 + 原厂纯净 ramdisk（无 root）** | 67,108,864 | `c152ed9bfc5d15454d0c9ce5306313fff69d5ef478bd7e4895bc1af99660700a` |
| `folk_patched_..._tklj.img` | **自编内核 + FolkPatch root（当前在用）** | 67,108,864 | `e5ef715770342eccfcc6af46ce83e3f2f705a4c7bf48f275d6f33ca05ad6c15e` |
| `Image` | 内核镜像 | 35,838,464 | `4fb42c92d0e3eca33df1e9dc4eb370e54d7e44507c602d2e326202d92d34d73d` |
| `System.map` | 符号表 | 4,978,806 | `e6a278f3a7cc5f8569f9944e92d1c9a809e6e1b7e4c964a4717d72d8d074e3f8` |
| `kernel.config` | 最终配置 | 211,656 | `801c6b06217b36cfbe03bd5f595f5dd8d74c1de0e72bfbda029618c4e55d2972` |

boot 镜像结构：AOSP header v4（1584 B）+ LZ4 legacy 内核（17,047,807 B）+ 0 长度 ramdisk + 原厂 vbmeta（1728 B @ 17,276,928）+ AVB footer；lz4 回读解压 sha256 与 `Image` 完全一致（已校验）。

## 七、刷入与回滚

```bash
# 刷入（bootloader 模式；本机 fastboot boot 不支持，只能 flash）
adb reboot bootloader
fastboot flash boot boot_run11_6.1.134.img
fastboot reboot

# 回滚到原厂
fastboot flash boot stock_boot.img
```

**注意**：
- 必须保持 `boot_a` 槽（本机只有 a 槽在用）
- 本机 `fastboot boot`（临时启动）不支持，只能刷入
- 不要动 `abl/xbl/tz/hyp/vbmeta` 分区；本机解锁状态下校验已关闭，刷 boot 不需要签名
- 想要 root：用 FolkPatch 0.13.9 以 `boot_run11_6.1.134.img` 为底包打补丁，再把输出刷入（本次产出的就是 `folk_patched_..._tklj.img`）

## 八、已知问题（不影响容器/日常使用）

1. **2 个 OPLUS 调度模块未能加载**：`oplus_bsp_sched_ext`、`oplus_bsp_game_opt` 依赖 HMBIRD/scx 符号，公开内核源码缺这段（`CONFIG_HMBIRD_SCHED` 在 16.0.0.203 / 16.0.3.500 / 16.0.5.701 / 16.0.9.402 的 Kconfig 里都不存在）。影响：OPLUS 的性能调度增强缺失，普通调度正常。
2. **`/data` 上无法挂载 overlayfs**：`/data` 的 f2fs 实例（dm-77，带 inlinecrypt/compress/casefold 特性）dentry 标志被 overlayfs 判为 unsupported；`/metadata`(f2fs)、ext4、tmpfs 都正常。这是原厂同样存在的限制（内核 overlayfs 代码与 f2fs 配置都是原厂同款），Droidspaces 用 **loop 挂载 ext4 镜像** 作为容器根文件系统，不受影响。
3. `SELinux = Permissive`（FolkPatch 设置，对容器有利）。
4. `PANIC_ON_OOPS` 等调试项为原厂默认值；本版本为与原厂 ABI 对齐而保留 KASAN/UBSAN，未做性能瘦身（瘦身版需补 `kasan_flag_enabled` 等导出桩，后续可做）。

## 九、验证脚本（`verify/` 目录）

| 脚本 | 用途 |
|---|---|
| `ko_symbols.py` | 解析 `.ko` 的 UND 符号与 `__ksymtab_strings` 导出符号 |
| `stock_needed.py` | 完备性证明：原厂已加载模块的 UND 全集 vs 本内核导出全集 → `missing.txt` |
| `inspect_boot_v4.py` | 校验 boot v4 镜像：header、lz4 回读 sha256、vbmeta 偏移、AVB footer 一致性 |
| `extract_vendor_boot.py` | 从 `vendor_boot.img` 解出 ramdisk 里的模块（LZ4 legacy / gzip / cpio） |
| `proc_modules_baseline.txt` | 原厂内核运行时 `/proc/modules` 全量（600 个）基线 |
| `missing_symbols_run11.txt` | 本版本相对原厂模块的缺失符号清单（22 个） |

## 原厂 / 回滚镜像（同 Release 内，均可下载）

| 资产名 | 内容 | 大小 | sha256 |
|---|---|---|---|
| `stock_boot_original.img` | **完整原厂 boot**（内核 `6.1.134-android14-11-o-g8f3b9b4f58d8`，未做任何改动，kernel 35,816,160 B） | 67,108,864 | `16b0b00eb63ef046f2422d39e286bade44a123a1abd28aeb1f45f27b002ca201` |
| `stock_boot_folkpatch_root.img` | **原厂内核 + FolkPatch 0.13.9 root**（实测可正常启动并带 root；与本次改造前设备 `boot_a` 内容一致，即最稳的救砖镜像） | 67,108,864 | `224794ed8a2d3aab33fc15ab7524d23572ae48c302a01d6b871bcd6292b10bd2` |
| `stock_init_boot_original.img` | **原厂 init_boot**（generic ramdisk 3,270,374 B，完整回滚时配套使用） | 8,388,608 | `917dacdf28781f59a9bf1e8c57c3ab04da3d665173b5ed72da5340cca82b304c` |

刷机命令：

```bash
adb reboot bootloader
# 回到完全原厂
fastboot flash boot stock_boot_original.img
fastboot flash init_boot stock_init_boot_original.img     # 可选，仅当之前动过 init_boot
# 或者：原厂内核 + root
fastboot flash boot stock_boot_folkpatch_root.img
fastboot reboot
```

> 本机 `fastboot boot`（临时启动）不支持，只能 flash；解锁状态下校验已关闭，原厂镜像可直接刷。

---

## 九、v2（run13, 2026-11-23）实机验证记录

### 9.1 构建参数

| 项 | 值 |
|---|---|
| commit | `9d2fb6767847c6d180a2c64629c77fce02ee597c`（run13） |
| worklfow 输入 | `lto=none`、`debug_info=true` |
| kernel | `6.1.134-g9d2fb6767847 #1 SMP PREEMPT Mon Nov 23 13:40:42 UTC 2026` |
| `Image` | 36,387,328 B，sha256 `2c3cabcf146f455742e39d2463090276b6b5ac67a189c6e4ecae61f056da6583` |

### 9.2 与 run11（v1）配置逐项比对

- 新增开启：`CFS_BANDWIDTH`、`CGROUP_PIDS`、`NTSYNC`、`IP_SET`（全部类型）、`NETFILTER_XT_MATCH_ADDRTYPE`、`NETFILTER_XT_SET`、`IP6_NF_NAT`、`IP6_NF_TARGET_MASQUERADE`
- **没有任何被关闭项**；`KASAN / KASAN_HW_TAGS / UBSAN / KFENCE / PAGE_OWNER / PANIC_ON_OOPS / MODVERSIONS / DEBUG_INFO_BTF / KUNIT` 全部与 run11 一致

### 9.3 运行验证

| 项目 | 结果 |
|---|---|
| 启动 | `boot_completed=1`，无 panic / BUG / Oops |
| 原厂模块 | `lsmod` = 599 / 600（2 个 OPLUS scx 模块仍因公开源码缺 HMBIRD 而无法加载） |
| 模块错误 | dmesg `Unknown symbol` 仅 8 条，全部是 `oplus_bsp_game_opt` 的 4 个 scx tracepoint（已知，无外设影响） |
| `/dev/ntsync` | `crw------- root root 10,125` ✅ |
| cgroup 控制器 | `/sys/fs/cgroup/cgroup.controllers` 含 `pids` ✅ |
| `droidspaces check` | **全部 ✓**：IPv6 NAT / CPU limit / Process limit 三项由 ✗ 变 ✓ |
| 容器限额 | `--cpus 2 --pids-limit 200` → `cpu_quota=200000 / period=100000 / pids_limit=200`；容器内 `pids.max=200` ✅ |
| NTsync | 静态测试程序在**容器内**和**宿主 root** 均 `NTSYNC_TEST_PASS`（CREATE_SEM / SEM_RELEASE / SEM_READ count=2 / EVENT set+read） ✅ |
| IPv6 NAT | `ip6tables -t nat -L -n` 正常 ✅ |
| 容器 | 恢复默认配置后正常运行：Azure Linux 3.0，`systemctl is-system-running` = running，IP `172.28.186.11` |

### 9.4 v2 产物哈希

| 资产 | 大小 | sha256 |
|---|---|---|
| `folk_patched_115404_0.13.9_hfxt.img` | 67,108,864 | `1d44445a598ed6a162399d526bbede90b96f4225ddf50618c164559632f7e0b1` |
| `boot_run13_6.1.134.img` | 67,108,864 | `4db24326d9a8d47fc8351e94e3490126beb5dd5c0e4f1e8ce0f2dcc0d85d49bd` |
| `Image` | 36,387,328 | `2c3cabcf146f455742e39d2463090276b6b5ac67a189c6e4ecae61f056da6583` |
| `System.map` | 5,010,316 | `bc3a0e601944c0991bebc336493c7d5eff05920fc8686ab409ad64fda9987621` |
| `kernel.config` | 212,221 | `58945c88000987d1d05a359fd8d213ad6e4b6d473341f042f6ae286895ca5333` |

FolkPatch 打补丁后镜像校验：与 `Image` 逐页比对仅 45 字节不同（4 个页），尾部 payload 432,480 字节，含 `KP1158/folk/KPM/ksu` 标记；FolkPatch 自动把 vbmeta 后移到 17,387,520，AVB0/footer 正常。

### 9.5 run12 失败复盘（`debug_info=false` → 白屏）

- run13 之前用 `debug_info=false` 构建了 run12（build 时间 `Mon Nov 23 12:56:14 UTC 2026`），刷入后白屏。
- pstore `console-ramoops-0` 显示：0.325s 时 `monitor_hang: Unknown symbol kasan_flag_enabled (err -2)`，
  随后 PID 1 init 以 127 退出 → `Kernel panic - not syncing: Attempted to kill init! exitcode=0x00007f00`。
- 原因：`debug_info=false` 关闭 KASAN，而 `kasan_flag_enabled` 只有 `CONFIG_KASAN_HW_TAGS=y` 才导出，
  原厂 22 个模块（monitor_hang / mali / wlan 等）依赖它 → 第一段 init 装模块失败。
- 结论：**本机必须 `debug_info=true`**；性能瘦身版需要额外补 `kasan_flag_enabled` 导出桩（后续）。
- 已回滚到 run11 镜像救机，再刷入 run13 通过。