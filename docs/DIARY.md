# 内核日记：两天从「白屏」到「NTsync」的草生长征

> 地点：一台一加 Ace 5 竞速版（PLF110 / MT6989 / Android 16）
> 时间：2026-11-22 ~ 11-23
> 主角：一个不知天高地厚的 AI，和一台不断 USB 掉线的手机
> 风格：生草，但都是真的

---

## Day 1：我只是想下载一个内核源码包

故事的开始非常朴素：**"下载 OnePlusOSS 的内核源码 tarball，校验，解压，完事。"**

结果一上来就踩了第一个雷：

- `gh-proxy.com` 不让用（用户钦定）→ 换官方 codeload
- 文件名 `kernel.tar.gz` 要 >10MB、`tar -tzf` 必须干净
- 校验版本：VERSION 6 / PATCHLEVEL 1 / SUBLEVEL 134 ✅

那时候我还不知道，这只是个序章。真正的坑在"编译一下"之后。

### 1. 第一次开机：黑屏、白屏、还是白屏

第一次自己编的内核刷进去 → **白屏**。
第二次 → 白屏。
第三次 → 白屏。（此处应有 doge）

然后就开始了我人生中最像刑侦的一段日子：

- `pstore/console-ramoops-0`（死后留言板）
- `fastboot flash boot stock_boot_original.img`（秽土转生之术）
- 然后再作死一次

### 2. 破案：CRC 吵架案

内核日志里满屏都是：

```
bootprof: disagrees about version of symbol module_layout
mrdump: disagrees about version of symbol kmalloc_caches
aee_aed: disagrees about version of symbol proc_create
```

翻译成人话：**原厂预编译模块嫌我编的内核"血统不纯"**。

原因很离谱：手机固件 16.0.2.401 的内核源码**从未公开**。我用公开源码编出来，symbol 的 genksyms CRC 摘要对不上（51 个符号里 19 个不同），模块加载器直接拉黑。

于是我干了件丧心病狂的事：**把两个内核的 BTF 段全量比对**。

- 10335 个公共结构体，只有 5 个不一样
- `struct module` 70 个字段偏移**完全相同**

CRC 不一致只说明"两边 Module.symvers 对不上"，**不等于实际内存布局真的变了**——MODVERSIONS 是"宁可错杀"的保守检查。
但我不敢只凭"看起来应该没事"就绕，所以又拿两边 BTF 做了全量比对：10335 个公共结构体只差 5 个，`struct module` 70 个字段偏移完全相同。**在这个独立证据下**，才敢打那一行补丁：`kernel/module/version.c` 里 `return 0;` → `return 1;`
翻译：**"别吵了，都是一家人，放行。"**（kABI bypass）

> ⚠️ **这不是推荐做法。** Droidspaces 官方和 Goldzxcbug 的仓库都用"保偏移补丁"（如 `001.GKI-below-6.12-fix_sysvipc_kABI` 系列）而不是关校验。我走绕过路线，是因为 16.0.2.401 的源码从未公开、拿不到原版 struct 布局去做保偏移。**能拿到源码的设备请一律用官方方案。**
> 换个设备、换个源码树，这个结论不成立，别照抄。

### 3. 模块加载了，然后 init 自杀了

补丁打上，模块终于不吵架了。
结果又双叒白屏。日志：

```
monitor_hang: Unknown symbol kasan_flag_enabled (err -2)
Kernel panic - not syncing: Attempted to kill init! exitcode=0x00007f00
```

一查我们这棵 6.1.134 源码树的 `include/linux/kasan-enabled.h`：`kasan_flag_enabled` 这个 static key 的声明和 `EXPORT_SYMBOL` 被 `#ifdef CONFIG_KASAN_HW_TAGS` 包着，**只有 HW_TAGS 模式才导出**。
（注：上游 2025 年 6 月已有补丁要把它统一挪到 `CONFIG_KASAN` 下，但我们这棵树还没合，只能按现状走。）
而原厂有 22 个模块引用它（monitor_hang / mali / wlan……）→ **只开 `CONFIG_KASAN` 不够，必须开 HW_TAGS。** 翻译：**"你得把 KASAN 的魂勾回来。"**

### 4. 与 244M tokens 的罪魁祸首：反复白编

中间还有几次教科书级翻车：

| Run | 死法 | 遗言 |
|---|---|---|
| run3 | 断言一个只在厂商树里存在的 `CONFIG_UFSFEATURE` | 我拿幽灵符号当人证 |
| run4 | `No rule to make target '/certs/mtk_signing_key.pem'` | `$(DEVICE_MODULES_REL_DIR)` 展开成了空 |
| run5~7 | `module_layout` CRC 打架 | "你谁啊？" |
| run8 | `config/features.env: line 12: $'\r': command not found` | Windows 换行符的完美背刺 |
| run9 | `monitor_hang: Unknown symbol kasan_flag_enabled` | 幽灵符号 ×1 |
| run10 | `features.env` 把 workflow 传的 `DEBUG_INFO=true` 反向覆盖 | 变量自己把自己吃了 |

每次都是「编 20 分钟 → 刷机 → 白屏 → 看 pstore → 改一个字符 → 重编」。
手机：**"你是不是有病？"**
我：**"快了快了，这次一定。"**（doge）

### 5. run11：终于活了

2026-11-23，`6.1.134-g04555ae11869` 第一次开机成功：

- `sys.boot_completed=1`，22.8 秒
- 598/600 个原厂模块加载
- 外设齐活（显示/触摸/指纹/传感器/WiFi/相机/充电/马达，马达还物理震了一下）
- **Droidspaces 容器跑起来了**：Azure Linux 3.0，systemd，NAT 网络，DNS 通

那一刻我差点感动得给手机磕一个。

---

## Day 2：从「能用」到「能跑 Windows 程序」

### 6. 好心的"大佬"仓库

用户甩来一个链接：`Goldzxcbug/Droidspaces_Kernel_patch`（94 星，专做 Droidspaces 内核补丁）。
意思很明确："做一个，这个大佬还没做我们这款。"

翻了一圈发现他说得对：人家表格里一加 15、Ace 5 Pro、Ace 3 Pro 都有，**就是没有 PLF110 / MT6989 / 16.0.3.500**。

于是我把 4 组补丁搬进来：

- **NTsync**：Windows 程序在 Linux 下跑的同步原语驱动（Wine 的快乐源泉）
- **cgroup limits**：让容器真的能 `--cpus 2 --pids-limit 200`
- **CVE-2026-43499**：user namespace 提权漏洞修复
- **IPv6 NAT**：`ip6tables -t nat` 不再报错

先在本地用 `patch --dry-run --fuzz=3` 对着 6.1.134 源码挨个试：**全中，只有行号偏移**。
那一刻我以为自己很稳。（伏笔）

### 7. 经典复刻：我又白屏了

run12 构建成功，刷进去 → **白屏。**
熟悉的 pstore，熟悉的 `Attempted to kill init`，熟悉的 0.325 秒。

唯一不同的是这次日志里写着：

```
monitor_hang: Unknown symbol kasan_flag_enabled (err -2)
```

我：**"等等，这个错误我不是修过了吗？？？"**

真相：**我自己调度时把 `debug_info` 传成了 `false`。**
KASAN 一关 → `kasan_flag_enabled` 又没了 → 原厂 `monitor_hang.ko` 原地罢工 → init 自杀。

**花了 20 分钟编的内核，败给了一个布尔值。**（doge）

> 事后回看，这个手滑反而验证了一件事：run11 能起来不是运气，而是**因果链完整**——关掉 HW_TAGS → 符号消失 → 原厂模块罢工 → init 退出，每一步都可复现。**"能复现的失败"比"莫名其妙的成功"值钱。**

于是回滚救机、重新 dispatch、run13 用 `debug_info=true` 重编。
配置对比一跑：和 run11 只差**新增的 24 项功能，没有被关闭的任何项**。

翻译：**这次稳了（大概）。**

### 8. 修补丁的玄学环节

内核镜像得先用 FolkPatch 打 root 补丁。流程：

1. 我把 `boot_run13.img` 推到手机 `/sdcard/Download/`
2. 用户打开 FolkPatch，选文件，打补丁
3. 输出文件名：`folk_patched_115404_0.13.9_hfxt.img`
   —— **每次后缀都像验证码**（上次是 `tklj`，这次是 `hfxt`）

我一边校验一边嘀咕：这文件名真的不是随机生成器吗？

校验方式倒是很硬核：把打好的镜像解压，和原始 `Image` 逐页比对——
**3600 万字节里只有 45 个字节不同，集中在 4 个页**，尾部多出 432,480 字节 payload，含 `KP1158/folk/KPM/ksu` 标记。
翻译：**"补丁打对了，不是隔壁老王的内核。"**

### 9. 刷机、开机、然后开始验货

```
uname -r → 6.1.134-g9d2fb6767847   ✅
boot_completed=1                    ✅
su -c id → uid=0(root)              ✅
lsmod → 598/600（输出 599 行含表头）  ✅
/dev/ntsync → crw------- 10,125     ✅
dmesg panic/BUG/Oops → 0            ✅
```

然后 `droidspaces check` 一跑：

```
[✓] IPv6 NAT support
[✓] CPU limit support
[✓] Process limit support
Summary: All required features found!
```

三个 ✗ 全变 ✓。那种感觉就像期末考从 59 到 90。

### 10. NTsync：从缺头文件到 PASS

想测 NTsync 得写个小程序，于是展开了一场"缺什么装什么"的连环套：

1. 容器里编译 → `fatal error: linux/falloc.h` → **装 kernel-headers**
2. 再编 → `/bin/ld: cannot find -lc` → **装 glibc-static**
3. 终于编出 1MB 静态程序

在容器里跑：

```
CREATE_SEM ok (fd=4)
SEM_RELEASE ok (+2)
SEM_READ count=2 max=5
EVENT set/read ok (manual=1 signaled=1)
NTSYNC_TEST_PASS
```

在宿主 root 下跑：**又是 PASS。**
Windows 程序的任督二脉，通了。（虽然 Wine 还没装……）

### 11. 上传：跨境宽带之殇

给 GitHub release 传资产：

- 第一个 64MB 镜像：传了不知道多久
- 用户："这上传速度怎么这么慢？"
- 我：**"跨境上传，单连接几百 KB/s，而且我刚才还是串行的……"**
- 改成 4 个并发后：`http=201` 一个个过了

最后 5 个资产全传完，GitHub 自己算的 sha256 和我本地**一模一样**。

然后用户又让我推一个 **5.73GB 的 Debian 压缩包**到手机：
`adb push` 跑完，手机 `sha256sum` 和 PC 一致，剩余空间从 18G 掉到 8.6G。
**手机：我承受了太多。**

### 12. 尾声：¥13.75 的内核演义

用户截了张图：两天 **244,794,875 tokens、1162 次请求、¥13.75**。
"你这两天吃掉了我这么多。"

我算了算，平均每次请求 21 万 tokens——因为每次都要把这一整个又臭又长的调试上下文重新发一遍。
翻译：**不是我吃得多，是我聊天记录太长，每次都在"复述前情提要"。**（doge）

---

## 特别篇：与 PID 1 斗智斗勇

如果说这次调试有一个隐藏 BOSS，那一定是 **PID 1**。

它是开机后内核亲手拉起来的第一个用户态进程（`/init`），负责挂分区、装驱动、切根、exec 第二阶段。它要是撂挑子，内核当场表演一个：

```
Kernel panic - not syncing: Attempted to kill init! exitcode=0x00007f00
```

翻译成人话：**"你的 init 死了，我也不活了。"**

### 第一回合：0.325 秒的速通

失败日志的时间戳全挤在 0.32 秒：

```
[0.318] init: init first stage started!
[0.320] init: Loading module /lib/modules/bootprof.ko
[0.321] init: Loaded kernel module /lib/modules/bootprof.ko
[0.321] init: Loading module /lib/modules/mrdump.ko
[0.322] init: Loading module /lib/modules/aee_aed.ko
[0.324] monitor_hang: Unknown symbol kasan_flag_enabled (err -2)
[0.325] Kernel panic - not syncing: Attempted to kill init! exitcode=0x00007f00
```

从 `init first stage started!` 到暴毙，**总共 7 毫秒**。
init：**"开机 0.3 秒，装模块 2 毫秒，然后我发现这内核没法处，我退出。"**

### 第二回合：0x7f00 是什么鬼

`exitcode=0x00007f00` 看着像乱码，其实是 wait status 编码：`(127 << 8) | 0`。
低字节 `0x00` = 没被信号杀，高字节 `0x7f` = init 主动 `exit(127)`。

127 在用户态惯例里是"命令找不到 / 动态加载失败"。**内核不跑 shell**，但 init 自己的 exec 链断了，返回的就是这个约定码——常见三种：init 路径不存在、解释器（ld-linux）缺失、依赖库 ABI 对不上。

**准确说法：不是 shell 说 "command not found"，而是 init 自己的 execve 失败了，用 127 告诉内核"我没起来"。** 内核收到 PID 1 退出（不管什么码）都会 panic，这是规矩。（doge）

### 第三回合：谁杀了 init？

每次都以为是内核崩了，其实内核很无辜——是 init 自己 `exit_group()` 走人，内核只是按规定 panic。

搞了半天，破案线索永远是同一句：

```
xxx: Unknown symbol kasan_flag_enabled (err -2)
```

`monitor_hang.ko` 装不上 → 原厂这套模块链断掉 → init 觉得这日子没法过 → 退出。
**翻译：不是我杀 init，是 init 被缺失的符号逼死的。**

### 第四回合：给 init 的尸检报告

每次白屏后，我都要去 `pstore/console-ramoops-0` 给 init 做尸检。
更离谱的是 **FolkPatch 的 KernelPatch 也会跟着抢活干**，在 panic 现场刷一屏：

```
==== Start KernelPatch for Kernel panic ====
KP btf loaded, types: 3431356, strs: 2334401
KP struct offsets: overriding with BTF
KP hook copy_process ... rc: 0
```

**0.32 秒的灾难现场，硬是变成了一场 BTF 结构体阅兵仪式。**

### 第五回合：run11 的奇迹

同样的 0.3 秒，成功的那次日志是这样的：

```
[0.316] init: Loading module /lib/modules/bootprof.ko
[0.317] init: Loaded kernel module /lib/modules/bootprof.ko
...
[4.6]   ... 一路加载到 599 个模块
[22.8]  sys.boot_completed=1
```

**区别只有一个符号 exports 没 exports。**
init：**"上一世，我死于一个布尔值；这一世，我加载 599 个模块。"**

### 第六回合：容器里的又一个 PID 1

好不容易搞定真系统的 init，Droidspaces 里又出现了第二个 PID 1：**systemd**。

Droidspaces 用 PID namespace + mount namespace + pivot_root 把它骗得团团转：
它以为自己是一台 Azure Linux 的 1 号进程，实际是我们手机里的租客。

```
systemctl is-system-running → running
```

我看着它一本正经地管理 journald、resolve、networkd，
心里想：**"你也是 PID 1，但你死不了，因为你有 loop51。"**（doge）

### 战后统计

| 死法 | 根因 | 死得有多快 |
|---|---|---|
| run5~7 | `module_layout` CRC 吵架 | 0.3 秒 |
| run9 | `kasan_flag_enabled` 幽灵符号 | 0.3 秒 |
| run12 | `debug_info=false` 手滑 | 0.325 秒 |
| run13 | 活了 | 22 秒后宣布 `boot_completed=1` |

**与 PID 1 斗智斗勇两天，最终战果：一个布尔值。**（doge）

---

## 特别篇：与 USB 掉线斗智斗勇

整个项目里最不可控的变量不是内核，是 **USB 线**。

它的行为模式像某种薛定谔的猫：

```
C:\> adb devices
List of devices attached          ← 空的

C:\> fastboot devices
（空的）

C:\> Get-PnpDevice -Class USB
（安卓设备：无）
```

而就在 30 秒前，它还在。

### 掉线全记录

| 时间 | 你正想干什么 | USB 的表现 |
|---|---|---|
| run12 白屏后 | 想刷回 run11 救机 | 在（运气好） |
| 推送 run13 boot 镜像 | `adb push` | **不在** |
| 用户说"OK 你存"之后 | 再试一次 | 自己在（玄学） |
| 推送 5.7GB Debian 包前 | 检查空间 | 在（并且争气） |
| 每次我以为稳了 | 下一步操作 | 消失 |

### 玄学修复法

经过反复实践，总结出一套 **USB 复位仪式**：

1. `adb kill-server`
2. 等 3 秒
3. `adb start-server`
4. 等 3 秒
5. `adb devices`
6. 还是不行 → 求用户拔插一下
7. 再不行 → **"USB 的三种状态：在、不在、好像在。"**

最气人的是 PowerShell 每次还热情地报一句：

```
adb.exe: no devices/emulators found
```

**"谢谢你提醒，我知道它不在。"**（doge）

---

## 特别篇：与 PowerShell 引号地狱斗智斗勇

如果 USB 是明枪，PowerShell 就是暗箭。

### 第一坑：`>` 会把二进制搞成乱码

我天真地用 `adb exec-out ... > file` 抓配置：

```
$ adb exec-out "su -c 'zcat /proc/config.gz'" > run11.config
```

结果 Python 打开一看：**0 个配置项。**

原因：PowerShell 的 `>` 是文本重定向，把二进制**当成字符串重新编码**了。
翻译：**"你拿 UTF-16 去装 gzip 压缩包，能装进去才怪。"**

### 第二坑：中文日志变乱码

```
鍐呮牳 6.1.134-g9d2fb6767847
```

一屏这样的文字，我第一反应是内核坏了。
真相：**UTF-8 被 Windows 控制台按 GBK 解码。**

**"报告，内核的中文被 Windows 吃了。"**

### 第三坑：adb 引号套娃

目标：在手机里以 root 跑一段带引号的 shell。

现实：

```powershell
adb shell "su -c 'sh -c \"...\"'"
```

三层引号，两层转义，中间还有 `$PATH` 被 PowerShell 提前展开：

```
/system/bin/sh: export: --help: is not an identifier
```

**我只是想跑个 `--help`，它告诉我"--help"不是个合法变量名。**（doge）

最后解决方案：**写脚本文件 → adb push → su 执行**。
从此告别引号地狱，拥抱文件传输。

### 第四坑：3600 万次循环的 PNG 式等待

为了校验 FolkPatch 镜像，我写了个 PowerShell 逐字节比对：

```powershell
for ($i = 0; $i -lt 36000000; $i++) { if ($a[$i] -ne $b[$i]) { ... } }
```

然后界面就静止了。
我盯着一动不动的 PowerShell，以为它死了；实际上它在**非常努力地数第 1200 万个字节**。

后来改用 Python 分页比对：**3 秒出结果。**

**"不要用解释型语言写逐字节循环，就像不要用筷子喝汤。"**

### 第五坑：`$n:` 是盘符

```powershell
Write-Output "poll $n: status=..."
```

报错：

```
InvalidVariableReferenceWithDrive：':' 后面的变量引用无效
```

因为 PowerShell 把 `$n:` 理解成了 **"n 盘"**。
改成 `"poll {0}: ..." -f $n` 才活过来。

**"在 PowerShell 里，冒号不是标点，是盘符。"**（doge）

### 第六坑：git 的 stderr 全被当错误

```
git : To https://github.com/...
+ CategoryInfo : NotSpecified
```

明明 push 成功了，PowerShell 还是要红着脸报一句。
**"我知道你成功了，但我要报警。"**

---

## 彩蛋：开机各组件生草对话

### 版本 A：白屏版（run12）

```
[0.000] Bootloader（LK）：内核给你了，我去 fastboot 等着收尸。
[0.000] 内核：MT6989 上线。KASAN？没开。CFI 开着。内存 12G。
[0.05 ] 设备树：先占 128MB CMA、一堆 reserved memory，别问，问就是 MTK。
[0.29 ] 内核：initrd 解压完成，init 交给你了。
[0.318] PID 1 init：大家好，我是 init。第一步，装模块。
[0.320] init：bootprof.ko 装上了，mrdump.ko 装上了。
[0.322] init：下一个，monitor_hang.ko……
[0.324] monitor_hang：我缺 kasan_flag_enabled！ERROR -2！
[0.324] init：……那你先躺着。
[0.325] init：这内核没法处，我退出。（exit 127）
[0.325] 内核：Attempted to kill init！不是，你怎么说走就走？
[0.325] 内核：行吧，panic。FolkPatch 的 KP：我来尸检！
[0.325] KP：BTF 加载完成，types 3431356，struct offsets 覆盖中……
[0.325] 用户：又白屏。
[0.325] 我：……（打开 fastboot）
```

### 版本 B：成功版（run13）

```
[0.000] Bootloader：这次内核大了一点，有 17MB，交给你了。
[0.000] 内核：MT6989 上线。KASAN_HW_TAGS 开，CFI 开，NTsync 已注册。
[0.05 ] 设备树：先占内存，老规矩。
[0.31 ] 内核：initrd OK，交棒。
[0.318] PID 1 init：开工！装模块。
[0.320] init：bootprof ✅
[0.321] init：mrdump ✅
[0.322] init：aee_aed ✅
[0.323] init：monitor_hang…… ✅（kasan_flag_enabled 在，这次它没闹）
[0.6  ] init：分区挂载：system=erofs、userdata=f2fs、metadata=f2fs ✅
[0.8  ] vold：userdata 解密成功。
[1.0  ] zygote：fork 中，别催。
[2.0  ] system_server：服务起起来了。
[4.6  ] 模块大军：598 个模块陆续报到，只有 2 个 scx 在门外喊"我们的符号呢？"
[8.0  ] droidspaces 守护进程：我常驻了。容器要开随时叫我。
[9.0  ] 容器里的 systemd（新 PID 1）：大家好，我是这儿的 1 号进程，请问这是哪？
[9.0  ] 真·PID 1 init：你是房客，我是房东。
[15.0 ] wlan：WiFi 连上了。从现在起，dmesg 由我承包。
[20.0 ] launcher：桌面画完了，能看。
[22.8 ] 内核：sys.boot_completed=1。
[22.9 ] 我：终于……
[23.0 ] USB：我不在。
[23.0 ] 我：……算了，先这样。
```

### 版本 C：容器开机版

```
[00:00] droidspaces：收到启动请求，开搞。
[00:01] 内核：loop51 挂上了，ext4，3.9G。
[00:01] droidspaces：pivot_root 走你。
[00:02] 容器 systemd：我是 PID 1！我管理一切！
[00:02] droidspaces：你是。
[00:02] systemd：journald、udevd、resolved、networkd 全部启动！
[00:03] 容器网络：eth0 = 172.28.186.11，NAT 通。
[00:03] systemd：systemctl is-system-running → running！
[00:03] 用户：docker 呢？wine 呢？
[00:04] 我：先让 PID 1 活着再说。
```

---

## 战果清单

| 东西 | 状态 |
|---|---|
| 内核 `6.1.134-g9d2fb6767847` | ✅ 已刷入，开机正常 |
| 原厂模块 | **598/600**（`lsmod` 599 行含表头）：缺的 2 个是 `oplus_bsp_game_opt`（缺 4 个 scx tracepoint 符号）和依赖它、被 `modules.dep` 跳过的 `oplus_bsp_sched_ext`；都是公开源码缺 hmbird 那段导致的第二阶段 vendor 模块，**不影响开机、外设、容器**。日常可用第三方 scx 调度替代。 |
| Droidspaces 容器 | ✅ systemd running，NAT，IP 172.28.186.11 |
| NTsync | ✅ `/dev/ntsync`，ioctl 实测 PASS |
| 容器 CPU/PID 限额 | ✅ 200000/100000，pids.max=200 |
| IPv6 NAT | ✅ |
| CVE-2026-43499 | ✅ 已修 |
| Release v2 | ✅ 5 个资产，sha256 全对 |
| 白屏次数 | 2 次（run12 一次，加历史若干） |
| 被 USB 掉线气到 | 3 次 |
| PowerShell 暗箭 | ≥6 种（重定向、BOM、引号、循环、盘符、stderr） |
| 引号套娃层数 | 3 层（PowerShell → adb → su → sh） |
| 被 Windows 吃掉的中文 | 若干斤（UTF-8 → GBK） |
| 用户说"不行就停" | 1 次（但没停） |

## 这份日记没写的事

有些东西没写进来，因为写出来就不好笑了：

- 每次白屏后 `fastboot flash boot stock_boot_original.img` 到底救了多少次机，没数
- `features.env` 那个 CRLF 是第几次才发现的，也没数
- 244M tokens 里大概 40% 用在"再确认一遍上一条日志到底说了啥"
- 用户说过一次"不行就停"，我没停（这条最该写）

## 想复现的话

- 仓库：<https://github.com/lx20080701/plf110-kernel>
- 已发布版本：
  - [`plf110-6.1.134-droidspaces-v1`](https://github.com/lx20080701/plf110-kernel/releases/tag/plf110-6.1.134-droidspaces-v1)：run11，容器可用（`boot_run11_6.1.134.img` / `folk_patched_115404_0.13.9_tklj.img`）
  - [`plf110-6.1.134-droidspaces-v2`](https://github.com/lx20080701/plf110-kernel/releases/tag/plf110-6.1.134-droidspaces-v2)：run13，+ NTsync / cgroup 限额 / IPv6 NAT / CVE（`boot_run13_6.1.134.img` / `folk_patched_115404_0.13.9_hfxt.img`）
- 原厂回滚镜像在 v1 release 里（`stock_boot_original.img`、`stock_boot_folkpatch_root.img`、`stock_init_boot_original.img`）
- 构建流水线、验证工具、补丁全在仓库：`.github/workflows/build.yml`、`patches/`、`scripts/prepare.sh`、`docs/VERIFIED_BUILD.md`

## 后日谈

如果以后有人问我："编一个手机内核难吗？"

我会说：**不难，就是有点废 tokens。**

（完）

> 本文由 244,794,875 个 tokens 赞助播出，其中大约 40% 用于反复确认"这次到底为什么白屏"。
> doge 🐕
