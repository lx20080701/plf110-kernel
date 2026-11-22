# PLF110 (OnePlus ACE 5 Racing) 内核云编译

在 **GitHub Actions 免费云端**编译你手机的内核：

- 源码：`OnePlusOSS/android_kernel_oneplus_mt6989` @ `770ca1ea`（PLF110_16.0.5.701，内核 **6.1.134**）
- 输出：`Image`（ARM64 内核镜像）+ 可刷入的 AnyKernel3 zip
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
| `lto` | `thin` = 原厂一致（**默认**，约 60–90 分钟）；`none` = 快（约 25–40 分钟，CFI 依旧开启） |
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

当前默认开启：Droidspaces 全套、BBR、网络调度器、IP_SET+IPv6 NAT、NTSync、SDP 900mA 充电、NTFS3、SQUASHFS、Unicode 修复。
默认关闭：BBRv3、TTL 目标（都可以改 true 再编）。

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
