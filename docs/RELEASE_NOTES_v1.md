# PLF110 6.1.134 自编内核（Droidspaces 版）—— 已验证可启动

第一次在 **OnePlus ACE 5 Racing (PLF110 / MT6989 / Android 16)** 上成功启动自编内核，
并跑起 **Droidspaces v7.2.0** 容器（systemd / Azure Linux 3.0）。

## 成品

| 文件 | 说明 |
|---|---|
| `boot_run11_6.1.134.img` | 自编内核 + 原厂纯净 ramdisk（**无 root**）<br>`sha256 c152ed9bfc5d15454d0c9ce5306313fff69d5ef478bd7e4895bc1af99660700a` |
| `folk_patched_115404_0.13.9_tklj.img` | 自编内核 + **FolkPatch root**（当前在用的成品）<br>`sha256 e5ef715770342eccfcc6af46ce83e3f2f705a4c7bf48f275d6f33ca05ad6c15e` |
| `Image` | ARM64 内核镜像，`6.1.134-g04555ae11869`，35,838,464 B<br>`sha256 4fb42c92d0e3eca33df1e9dc4eb370e54d7e44507c602d2e326202d92d34d73d` |
| `System.map` / `kernel.config` | 符号表 / 最终配置（KASAN_HW_TAGS、CFI、LTO=none，与原厂一致） |
| `missing_symbols_run11.txt` | 相对原厂 600 个模块的符号缺口（22 个，均不影响启动） |

## 刷入

```bash
adb reboot bootloader
fastboot flash boot boot_run11_6.1.134.img   # 或 folk_patched_..._tklj.img
fastboot reboot
```

回滚：`fastboot flash boot` 原厂 boot.img。本机**不支持 `fastboot boot` 临时启动**，只能刷入。

## 验证结果

- 内核：`boot_completed=1`，`uname -r` = `6.1.134-g04555ae11869`
- 模块：**598/600** 原厂模块加载成功（缺 `oplus_bsp_sched_ext`、`oplus_bsp_game_opt` 两个 OPLUS scx 调度模块，公开源码缺 hmbird，无外设影响）
- 外设：显示/触摸/按键/指纹(3枚)/40 传感器/WiFi/蓝牙/相机(拍照)/音频/充电/USB/马达(实测有震感) 全部正常
- 容器：`systemctl is-system-running` = **running**，9 个 systemd 服务；根文件系统 loop52 ext4 3.9G；eth0 `172.28.186.11/16`（DHCP）；宿主机↔容器 ping 0.32ms；容器→外网 ping 通；DNS 解析 github.com 成功；`tdnf 3.5.8` 可用
- root：`su -c id` → `uid=0(root) context=u:r:magisk:s0`

## 这个版本解决了什么

1. **kABI CRC 不匹配**：固件 16.0.2.401 的源码从未公开，公开源码（16.0.3.500）构建出的 genksyms CRC 与原厂模块不一致（51 个符号中 19 个不同）→ 原厂模块被 `disagrees about version of symbol module_layout` 拒绝 → init 起不来。
   用两个内核的 **BTF 全量比对**证明真实 ABI 兼容（10335 个公共结构体仅 5 个 OEM 内部结构有差异，`struct module` 70 个字段偏移完全一致），因此加一行补丁让内核**只警告不拒绝**。
2. **符号依赖缺失**：`kasan_flag_enabled` 只有 `CONFIG_KASAN_HW_TAGS` 才导出，22 个原厂模块依赖它（`monitor_hang`/`mali`/`wlan` 等）→ 配置恢复为与原厂一致。
3. **符号完备性证明**：从手机拉全部 646 个 `.ko`（含 vendor_boot ramdisk），解析 UND 符号全集对差集，确认 first-stage 无缺口。

## 已知限制

- 2 个 OPLUS scx 调度模块未加载（公开源码缺 hmbird 代码）
- `/data` 上无法挂载 overlayfs（f2fs dentry 特性，原厂同样限制）；容器用 loop ext4 镜像不受影响
- 本版本为对齐原厂 ABI 保留 KASAN/UBSAN，未做性能瘦身

完整记录见仓库 `docs/VERIFIED_BUILD.md`。

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
