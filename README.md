# PLF110 (OnePlus ACE 5 Racing) 内核云编译

在 **GitHub Actions 免费云端**编译你手机的内核：

- 源码：`OnePlusOSS/android_kernel_oneplus_mt6989` @ `700216a4`（PLF110_16.0.0.203，内核 **6.1.134**，与本机 16.0.2.401 固件 2025-12-09 构建日最接近）+ 同一批次的厂商树 `android_kernel_modules_and_devicetree_oneplus_mt6989` @ `ae37b666`（内核树里 `drivers/soc/oplus/*` 等符号链接指向它的 `vendor/oplus/...`，缺了 Kconfig 解析直接失败）
- **配置基线 = 本机原厂 `/proc/config.gz`**（`config/plf110_stock.config`，由 `adb shell su -c 'zcat /proc/config.gz'` 导出）
  ⚠️ **不能用 Google 的 `gki_defconfig`**：那是通用最小配置，缺 200+ 个原厂 `=y` 的 MTK/OPLUS 内置驱动（`ARCH_MEDIATEK`、`OPLUS_CHARGER*`、`MTK_CCCI_DEVICES` 等），编出来会出现 **"第一段 init 挂载失败 → kernel panic: Attempted to kill init" 然后直接重启**（已实测踩坑）
  ℹ️ 原厂 config 里混有一批**只存在于厂商 modules 树**的符号（`UFSFEATURE`、`UFSTW`、`DEVICE_MODULES_*` 等，原厂 build 脚本后补进 `.config` 的装饰行）；GKI 树里没有这些 Kconfig 符号，kconfig 会**静默丢弃**（只有设 `KCONFIG_WARN_UNKNOWN_SYMBOLS` 才报）。所以基线断言只能挑真正的 GKI 符号（如 `ARCH_MEDIATEK`），不能拿 `UFSFEATURE` 断言——上一轮 run3 就死在这上面。
- 🔴 **kABI 红线（run5 的血的教训）**：`CONFIG_DEBUG_INFO` / `DEBUG_INFO_DWARF4` / `DEBUG_INFO_BTF` / `DEBUG_INFO_BTF_MODULES` / `KUNIT` **必须保持原厂的 `=y`**。
  `struct module` 里有两段 `#ifdef`（`CONFIG_DEBUG_INFO_BTF_MODULES` → `btf_data*`、`CONFIG_KUNIT` → `kunit_suites*`），改了它们 layout 就变；而导出符号 `module_layout` 的 CRC 是 genksyms 按该函数签名（`struct module *` 等）算的、**包含 struct module 完整定义** → CRC 变 → 原厂 vendor 模块全部报
  `disagrees about version of symbol module_layout` / `Exec format error` → 第一段 init 加载不了模块 → 机器无提示直接重启。
  所以 `prepare.sh` 只关**与导出 CRC 无关**的调试项（KASAN/KFENCE/UBSAN/PAGE_OWNER/PANIC_ON_OOPS），并把上面 5 个 ABI 符号显式钉成 `=y`，workflow 里也有硬断言。
- LTO 与原厂一致用 **`none`**（原厂 `CONFIG_LTO_NONE=y`），CFI 保持开启
- 构建修正：原厂 config 的 `CONFIG_MODULE_SIG_KEY="$(DEVICE_MODULES_REL_DIR)/certs/mtk_signing_key.pem"` 在 OSS 编译时 `$(DEVICE_MODULES_REL_DIR)` 展开为空 → 变成 `/certs/mtk_signing_key.pem`，make 直接失败（run4 的坑）。`prepare.sh` 已覆盖为内核默认 `certs/signing_key.pem`（构建时自动生成一次性密钥；`MODULE_SIG_FORCE` 原厂就是 `n`，不影响加载原厂 vendor 模块）
- ✅ **run #5 已完整编译成功**（`lto=none`、`debug_info=false`，约 12 分钟），产物见 Actions 的 `kernel-PLF110-A16-6.1.134-5`
- 输出：`Image`（ARM64 内核镜像）+ `Module.symvers`（用于核对 vendor 模块 kABI 兼容性）+ 可刷入的 AnyKernel3 zip
- 已内置：**Droidspaces 内核支持**（kABI 补丁 + SYSVIPC/PID_NS/IPC_NS/USER_NS 等配置）
- 你的编译产物还可以保留 **FolkPatch** root（刷机流程见文末）

---

## 一、怎么用（首次 5 分钟配置）

### 1. 建一个 GitHub 仓库

在 github.com 右上角 **+ → New repository**，随便起名（例如 `plf110-kernel`），Private 也可以，**不要**勾选 README（保持空仓库）。

### 2. 把本目录传到仓库

任选一种：

- **GitHub Desktop**（推荐，Windows 上最简单）：File → Add local repository → 选中 `plf110-kernel-ci` 文件夹 → 出现 "Publish repository" → 发布。
- **网页上传**：在仓库首页点 **Add file → Upload files**，把 `plf110-kernel-ci` 里的内容拖进去（注意 `.github` 是隐藏目录，如果漏了：**Add file → Create new file**，文件名输入 `.github/workflows/build.yml`，再把文件内容粘进去；`config/features.env`、`scripts/prepare.sh` 同理）。
- **命令行**（已装 git）：
  ```bash
  cd plf110-kernel-ci
  git init && git add -A && git commit -m "init"
  git remote add origin https://github.com/<你的用户名>/plf110-kernel.git
  git branch -M main && git push -u origin main
  ```

### 3. 跑编译

仓库页面 → **Actions** 标签 → 左侧选 **Build PLF110 kernel (6.1.134 + Droidspaces)** → 右侧 **Run workflow**：

| 选项 | 说明 |
|---|---|
| `lto` | `none` = 与原厂一致（**默认**，约 25–40 分钟，CFI 依旧开启）；`thin` = 实验（约 60–90 分钟） |
| `debug_info` | 保持 `false`。改成 true 会带上 KASAN/BTF/调试信息，非常慢，只用于排查内核 bug |

点 **Run workflow** 后等它跑完（页面会实时显示日志）。

### 4. 下载产物

跑完后进入该次运行页面，底部 **Artifacts** → `kernel-PLF110-A16-6.1.134-<序号>`，里面：

| 文件 | 说明 |
|---|---|
| `Image` | 编译出的内核镜像（后面打包 boot.img 用） |
| `AK3_*.zip` | AnyKernel3 刷机包（KernelFlasher 可直接刷，但会丢 FolkPatch） |
| `kernel.config` | 最终内核配置（可核对功能是否都开上了） |
| `build.log` | 完整编译日志 |
| `Image.sha256` | 校验值 |

---

## 二、改功能

打开 `config/features.env`，把对应项改成 `true` / `false`，提交（Commit）后重新 **Run workflow** 即可。

**当前策略：最小可用集** —— 只开 `DROIDSPACES=true`，其余全部 `false`（BBR / BBRv3 / NET_SCHED / IP_SET_NAT / TTL_TARGET / SDP_CHARGE / NTSYNC / NTFS3 / SQUASHFS / UNICODE_FIX / PERF_TWEAKS / EXTRA_FS / CONTAINER_NET / NET_DEFAULTS）。
目的：变量降到最少，万一起不来容易定位。**关闭 ≠ 删除**：`scripts/prepare.sh` 仍会把每个关闭的功能写成 `# CONFIG_XXX is not set` 占位留在 defconfig 里，改 `true` 立刻恢复。

> 注意：`Image` 是直接在 boot 分区里跑的内核，**所有功能必须是内置（`=y`）**，本仓库脚本已经按这个原则处理。

---

## 三、编译完成后怎么刷（保留 FolkPatch）

GitHub Actions 只产出 `Image`，还需要把 `Image` 塞回你手机的 boot.img 并重新打 FolkPatch 补丁。流程：

1. 把产物里的 `Image` 下载到电脑（例如 `F:\114514\Image`）。
2. 用你备份的**原厂 boot.img** 打包出 `boot_new.img`（用 magiskboot / mkbootimg，需要原厂内核之外的 ramdisk，这个我可以帮你做，把 boot.img 放 F:\114514 即可）。
3. 手机装 **FolkPatch** → 选择 `boot_new.img` 离线打补丁 → 刷入 boot 分区（或用电脑 fastboot 刷）。
4. 重启后 `设置 → 关于手机 → 内核版本` 应显示你编的版本；`uname -r` 能看到版本号。
5. 装 Droidspaces → **Settings → Requirements → Check Requirements** 全绿即成功。

> 如果刷炸了：进 fastboot 刷回你备份的 boot 即可，数据不会丢。

---

## 四、出问题怎么办

- Actions 页面那一步标红 → 点开看日志，把 **红字/最后 50 行** 发给我，我改脚本。
- 常见：网络下载超时（重跑一次即可）、`patch` 拒绝应用（上游补丁更新了，我调偏移/换变体）。
- 不要在没有备份的情况下刷任何东西。
