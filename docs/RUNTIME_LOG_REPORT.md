# 运行日志分析报告（run #11 内核，2026-11-23）

> 数据来源：本机实机 `dmesg` + `logcat`，时间跨度为**开机 → 运行约 37 分钟**。
> 结论：**无崩溃、无 ANR、无看门狗击杀、无 panic**；存在 18 条良性警告与 2 个 OPLUS scx 调度模块未加载。

## 一、开机时间线

| 时间 | 事件 |
|---|---|
| 0.000 s | `Booting Linux on physical CPU 0x0` |
| 0.313 s | `Freeing unused kernel memory: 4224K`（内核初始化完成） |
| 0.314 s | `init: init first stage started!` |
| 0.317 s | 首个模块 `bootprof.ko` 加载成功 |
| 1.15 s | UFS 存储链路就绪（`ufs_mediatek` / `cqhci` / `phy_mtk_ufs`） |
| 4.41 s | ⚠️ `oplus_bsp_game_opt` 加载失败（缺 scx tracepoint，见第五节） |
| **22.77 s** | **`init: processing action (sys.boot_completed=1)` → 开机完成** |
| 37 min | 仍在运行，无重启 |

## 二、内核警告（boot 期间 16 条，全部为"重复注册"类）

| 位置 | 次数 | 说明 |
|---|---|---|
| `fs/proc/generic.c:377 proc_register` | 8 | 模块注册同名 `/proc` 节点，内核忽略 |
| `kernel/tracepoint.c:340/404` + `usb_xhci/quirks.c:216/223 xhci_mtk_trace_init/deinit` | 4 | xHCI USB tracepoint 重复注册/注销 |
| `fs/sysfs/group.c:61 internal_create_group` | 1 | sysfs group 重名 |
| 其余 proc/sysfs 混合 | 3 | 同上 |

**触发模块**：`xhci_mtk_hcd_v2`(4)、`mtk_cmdq_drv_ext`(3)、`phy_mtk_xsphy`(2)、`oplus_bsp_uxmem_opt` / `task_cpustats` / `sigkill_diagnosis` / `zram_opt` / `kswapd_opt` / `memleak_detect_simple` / `oplus_sync_fence` 各 1。

性质：均为**原厂 vendor 模块自身抢占同一批 /proc、sysfs 名字**，内核 WARN 后继续，原厂内核同样存在（模块完全相同）。

## 三、运行期警告（18 s ~ 800 s，仅 2 条）

1. `20.5 s` — `WARNING: mm/slub.c:2013 new_slab`（`WARN_ON_ONCE(s->ctor && (flags & __GFP_ZERO))`）
   - 调用栈：`oplus_bsp_schedinfo → insert_hot_thread → kmem_cache_alloc`
   - 性质：原厂模块给"带构造函数"的 slab cache 用了 `__GFP_ZERO` 分配，属模块用法问题
2. `121.8 s` — `oplus_bsp_dfr_hung_task_enhance: task ufcs_sm:347 blocked for more than 60 seconds`
   - 栈：`ufcs_sm_task [ufcs_class]`
   - 性质：UFCS 快充状态机线程等待；实测充电正常（4841 mV / 330 mA），无功能影响

**无 oops / panic / BUG / 硬件错误。**

## 四、Android logcat（33065 行）

| 检查项 | 结果 |
|---|---|
| FATAL EXCEPTION | 0 |
| Fatal signal | 0 |
| ANR | 0 |
| WATCHDOG KILLING SYSTEM PROCESS | 0 |
| `am_proc_died` | 107（正常后台进程回收） |
| SELinux avc denied（当前缓冲区） | 0（系统 Permissive；早期 droidspacesd 的 avc 记录已滚出缓冲） |

E 级日志最多的 tag（OPLUS 常规刷屏，非故障）：

```
mtkpower@impl 971 / OsenseCommonUtils 600 / OplusStorageUFSBandwidth 400
AppOps 64 / RILC 44 / OplusStorageManagerFeature 40 / TNP 39
```

## 五、两个 OPLUS scx 调度模块

| 模块 | 状态 | 证据 |
|---|---|---|
| `oplus_bsp_game_opt` | ❌ 加载失败（4.41 s） | `Unknown symbol __tracepoint_android_vh_scx_select_cpu_dfl / __tracepoint_android_vh_check_preempt_curr_scx / __tracepoint_android_vh_scx_cpu_exclusive / __tracepoint_android_vh_scx_consume_dsq_allowed (err -2)`（重试一次，共 8 条） |
| `oplus_bsp_sched_ext` | ⛔ 未尝试 | `modules.dep`：`oplus_bsp_sched_ext.ko: oplus_bsp_game_opt.ko oplus_bsp_sched_assist.ko` → 依赖 `game_opt` 失败，init 直接跳过（故无报错日志） |

两个 `.ko` 均在 `/vendor_dlkm/lib/modules/`（290 KB / 113 KB），`modules.load` 第 169、180 行登记。

**根因**：4 个 `__tracepoint_android_vh_scx_*` 属于 OPLUS sched_ext/HMBIRD 改造，**公开内核源码没有这部分**（`CONFIG_HMBIRD_SCHED` 在 16.0.0.203 / 16.0.3.500 / 16.0.5.701 / 16.0.9.402 的 Kconfig 中均不存在），与 `verify/missing_symbols_run11.txt` 里的 21 个 scx 符号同源。

**影响**：OPLUS 游戏/性能调度不生效；原生调度（CFS/EEVDF）、容器、外设、日常使用不受影响。

**补齐思路（可选）**：从 16.0.5.701 / 16.0.9.402 的 `kernel_device_modules-6.1` 模块树移植 `include/trace/hooks/scx.h` 及对应 vendor hook 定义进内核树。

## 六、日志原始文件

| 文件 | 内容 |
|---|---|
| `boot_dmesg_full.log` | 完整开机 dmesg（0 → 23.6 s，20333 行）——由 Droidspaces 保存的完整快照提取（内核环形缓冲区已被 wlan 调试日志刷掉） |
| `logcat_all.txt` | 全缓冲区 logcat（33065 行） |
| `run11_dmesg.txt` | 运行期 dmesg（18 → 800 s） |
| `dmesg_now.txt` | 当前 dmesg（最近约 200 s） |

> 注意：本机 dmesg 环形缓冲区被 wlan 驱动的 INFO 级日志快速刷掉，抓早期日志需在开机后尽早抓取，或使用 `pstore`/Droidspaces 的 dmesg 快照。
