# PLF110 自编内核 v2 — Droidspaces + NTsync + cgroup 限额

基于 run13 构建（commit `9d2fb67`，2026-11-23），在原 v1（Droidspaces 容器可用）基础上增加：

- **NTsync**：NT 同步原语驱动（`/dev/ntsync`），Wine / Windows 程序用
- **容器限额**：`--cpus` / `--pids-limit` 真正生效（`CGROUP_PIDS` + `CFS_BANDWIDTH`）
- **IPv6 NAT**：`ip6tables -t nat` 可用（Droidspaces check 里最后一项 ✗ 已变 ✓）
- **CVE-2026-43499 修复**：user namespace 下 rtmutex 提权漏洞

补丁来源：[Goldzxcbug/Droidspaces_Kernel_patch](https://github.com/Goldzxcbug/Droidspaces_Kernel_patch) @ `dc0f76b`。
上游仓库的测试机型表里没有 PLF110 / MT6989 / 16.0.3.500 这个组合，本项目做了适配 + 实机验证。

## 资产

| 资产 | 内容 | 大小 | sha256 |
|---|---|---|---|
| `folk_patched_115404_0.13.9_hfxt.img` | **自编内核 + FolkPatch root（推荐直接用）** | 64 MB | `1d44445a598ed6a162399d526bbede90b96f4225ddf50618c164559632f7e0b1` |
| `boot_run13_6.1.134.img` | 自编内核 + 原厂纯净 ramdisk（无 root） | 64 MB | `4db24326d9a8d47fc8351e94e3490126beb5dd5c0e4f1e8ce0f2dcc0d85d49bd` |
| `Image` | ARM64 内核镜像（`6.1.134-g9d2fb6767847`） | 34.7 MB | `2c3cabcf146f455742e39d2463090276b6b5ac67a189c6e4ecae61f056da6583` |
| `System.map` | 符号表 | 4.8 MB | `bc3a0e601944c0991bebc336493c7d5eff05920fc8686ab409ad64fda9987621` |
| `kernel.config` | 最终内核配置 | 207 KB | `58945c88000987d1d05a359fd8d213ad6e4b6d473341f042f6ae286895ca5333` |

> 原厂回滚镜像（`stock_boot_original.img`、`stock_boot_folkpatch_root.img`、`stock_init_boot_original.img`）仍在 v1 release：
> [plf110-6.1.134-droidspaces-v1](https://github.com/lx20080701/plf110-kernel/releases/tag/plf110-6.1.134-droidspaces-v1)

## 刷入

```bash
adb reboot bootloader

# 推荐：自编内核 + root
fastboot flash boot folk_patched_115404_0.13.9_hfxt.img

# 或自编内核（无 root）
# fastboot flash boot boot_run13_6.1.134.img

fastboot reboot
```

验证：

```bash
adb shell uname -r                    # 6.1.134-g9d2fb6767847
adb shell getprop sys.boot_completed  # 1
adb shell 'su -c id'                  # uid=0(root)
adb shell 'su -c dmesg | grep -c "Unknown symbol"'   # 8（只有已知的 2 个 OPLUS scx 模块）
adb shell 'su -c "ls -l /dev/ntsync"'                # crw------- root root 10,125
adb shell 'su -c "/data/local/Droidspaces/bin/droidspaces check"'  # 全部 ✓（含 IPv6 NAT / CPU limit / Process limit）
```

## 回滚

```bash
adb reboot bootloader
fastboot flash boot stock_boot_original.img    # 完全原厂（v1 release 里下载）
fastboot reboot
```

⚠️ 本机 `fastboot boot` 不支持，只能 `flash`；解锁状态下校验已关闭。
⚠️ 刷机有风险，请确认已有救砖镜像。

## 实机验证记录

- 内核 `6.1.134-g9d2fb6767847`，`boot_completed=1`，开机无 panic/BUG/Oops
- 原厂模块 **598 / 600** 加载（`lsmod` 输出 599 行含表头；缺的 2 个仍是公开源码没有 HMBIRD/scx 的那两个，无外设影响）
- `droidspaces check`：**全绿**，IPv6 NAT / CPU limit / Process limit 三项从 ✗ 变 ✓
- 容器限额实测：`--cpus 2 --pids-limit 200` → `cpu_quota=200000/100000`、`pids.max=200` 生效
- NTsync 实测：容器内 + 宿主 root 均通过 `CREATE_SEM / SEM_RELEASE / SEM_READ / EVENT set+read`（`NTSYNC_TEST_PASS`）
- 容器恢复默认配置后正常运行：Azure Linux 3.0，`systemctl is-system-running` = running，IP `172.28.186.11`

**注意**：本版本为对齐原厂 vendor 模块 ABI，仍保留原厂调试配置（KASAN_HW_TAGS / UBSAN / KFENCE / PAGE_OWNER / PANIC_ON_OOPS）。
构建时必须用 `debug_info=true`（run12 用了 false → KASAN 关闭 → 原厂 `monitor_hang.ko` 缺 `kasan_flag_enabled` → init 0.32s panic 白屏）。
性能瘦身版需要先补 `kasan_flag_enabled` 导出桩，后续可做。
