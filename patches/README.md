# patches/ 目录说明

## 本仓库自有补丁

| 文件 | 作用 |
|---|---|
| `kabi_bypass.patch` | 跳过原厂 vendor 模块的 genksyms CRC 校验（原厂模块源码未公开，真实 ABI 已用 BTF 全量比对证明一致） |
| `ds_ntsync_base.patch` | NT 同步原语驱动 `drivers/misc/ntsync.c` + `include/uapi/linux/ntsync.h`（Wine / Windows 程序用） |
| `ds_ntsync_compat_android14-6.1.patch` | NTsync 的 android14-6.1 适配：`drivers/misc/Kconfig` + `Makefile` 增加 `CONFIG_NTSYNC` |
| `ds_cgroup_limits_6.1.patch` | 在 KMI 冻结的内核上安全打开 `CONFIG_CGROUP_PIDS` / `CONFIG_CFS_BANDWIDTH`（容器 CPU/PID 限额），ABI 可见数组保持原边界 |
| `ds_cve_userns_rtmutex_6.1.patch` | CVE-2026-43499 user namespace rtmutex 提权修复（6.1 后向移植版） |

## 来源与固定版本

`ds_*.patch` 均 vendored 自：

- 仓库：<https://github.com/Goldzxcbug/Droidspaces_Kernel_patch>
- 提交：`dc0f76bedd790b7738e5695509297ee71ca4a2c2`（2026-11-02，含 5.10.272 cgroup KMI 补丁的那次提交）

该仓库的测试机型表覆盖了 OnePlus 多款 OKI 6.1 设备，但**没有 PLF110 / MT6989 / 16.0.3.500 这一组合**。
本项目在本机（PLF110，`OnePlusOSS/android_kernel_oneplus_mt6989@76bcc45d`，6.1.134）上
用 GNU patch `--fuzz=3` 逐一 dry-run 验证过：补丁上下文全部命中，只有行号偏移，无 fuzz 失败。
`scripts/prepare.sh` 里也会先 `--dry-run` 再实际应用，失败会立即中断构建。

## 校验（sha256，LF 行尾）

```
3f43fff167ecbfdd4ef01321db41e042e33db01b2c645c7d8e01bb4abf1ccdd3  ds_ntsync_base.patch
e03598f2e1f669e697957fb940be2248fd36171d2235468497bdd8cdbfde1e8e  ds_ntsync_compat_android14-6.1.patch
a1a23fe54d5f4f25f9bade536ab33d729999ef09925dcdce7937a441a5a862c5  ds_cgroup_limits_6.1.patch
6e9dc91d68b94e9bd5230bd1099e427bde744bc7337ba26d79d2a053640a211e  ds_cve_userns_rtmutex_6.1.patch
```

上游补丁来源（该仓库 README 注明）：

- <https://github.com/ravindu644/Droidspaces-OSS/tree/main/Documentation/resources/kernel-patches>
- <https://github.com/WildKernels/kernel_patches>
