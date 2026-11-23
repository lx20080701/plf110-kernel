#!/usr/bin/env bash
# ============================================================
#  PLF110 (OnePlus ACE 5 Racing, MT6989, Android 16, 6.1.134)
#  内核定制准备脚本：打补丁 + 生成 defconfig
#  由 GitHub Actions 调用；本地 Linux 也能直接跑：
#     KDIR=/path/to/android_kernel_oneplus_mt6989-xxxx \
#     PATCH_RAW=https://raw.githubusercontent.com/WildKernels/kernel_patches/main \
#     STOCK_CONFIG=$PWD/config/plf110_stock.config \
#     bash scripts/prepare.sh
#
#  【本次策略：最小可用集 + 第二批增强】
#  第一批（run11 已验证）：Droidspaces 容器能跑起来。
#  第二批（run12，补丁来源 Goldzxcbug/Droidspaces_Kernel_patch @dc0f76b）：
#    NTSYNC        Wine / Windows 程序所需的 NT 同步原语（drivers/misc/ntsync）
#    CGROUP_LIMITS 容器 --cpus / --pids-limit 所需 CGROUP_PIDS + CFS_BANDWIDTH
#    USERNS_CVE    user namespace 提权漏洞修复（CVE-2026-43499，rtmutex）
#    IP_SET_NAT    IPv6 NAT（Droidspaces check 里唯一缺的网络项）
#  关闭的功能不删除 —— 仍然写入 "# CONFIG_XXX is not set" 占位，
#  这样 defconfig 里能一眼看到每个功能当前状态，改 true 即可恢复。
# ============================================================
set -euo pipefail

: "${KDIR:?KDIR 未设置}"
: "${PATCH_RAW:?PATCH_RAW 未设置}"
: "${STOCK_CONFIG:?STOCK_CONFIG 未设置（设备原厂 /proc/config.gz 解出来的配置）}"

cd "$KDIR"

say() { printf '\n===== %s =====\n' "$*"; }
say "生效开关：DROIDSPACES=${DROIDSPACES:-true} KABI_BYPASS=${KABI_BYPASS:-true} NTSYNC=${NTSYNC:-false} CGROUP_LIMITS=${CGROUP_LIMITS:-false} USERNS_CVE=${USERNS_CVE:-false} IP_SET_NAT=${IP_SET_NAT:-false} DEBUG_INFO=${DEBUG_INFO:-false} LTO_MODE=${LTO_MODE:-none}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fetch() { curl -LfsS --retry 3 --connect-timeout 20 -o "$2" "$1"; }
apply() { say "应用补丁：$1"; patch -p1 --forward --fuzz=3 < "$2"; }
# 可选补丁：失败只警告，不中断编译；返回 0=成功 / 1=失败
apply_optional() {
  say "应用可选补丁：$1"
  if patch -p1 --forward --fuzz=3 < "$2"; then
    return 0
  fi
  echo "::warning::可选补丁未能应用：$1（已跳过）"
  return 1
}

# 强制补丁：先用 --dry-run 全量校验（保证整份 patch 能套上），再真正应用。
# 这样可以避免 patch 套到一半失败、源码留下半套改动再去编译。
apply_required() {
  say "应用补丁（强制，先 dry-run 校验）：$1"
  if ! patch -p1 --forward --fuzz=3 --dry-run < "$2" >/dev/null 2>&1; then
    echo "::error::补丁无法应用到本内核源码：$1"
    patch -p1 --forward --fuzz=3 --dry-run < "$2" 2>&1 | tail -n 30 || true
    exit 1
  fi
  patch -p1 --forward --fuzz=3 < "$2"
}

# 可选补丁（先校验版）：校验不通过就整份跳过，绝不留半套改动
apply_safe_optional() {
  say "应用可选补丁（先 dry-run 校验）：$1"
  if patch -p1 --forward --fuzz=3 --dry-run < "$2" >/dev/null 2>&1; then
    patch -p1 --forward --fuzz=3 < "$2"
    return 0
  fi
  echo "::warning::可选补丁无法应用，已整份跳过：$1"
  return 1
}

# 统一的 "关闭占位" 输出：把 config 符号写成 "# CONFIG_X is not set"
not_set() {
  local s
  for s in "$@"; do
    printf '# CONFIG_%s is not set\n' "$s"
  done
}

# ------------------------------------------------------------
# 1. Droidspaces 必需补丁（GKI kABI 补丁，不能省）
# ------------------------------------------------------------
if [ "${DROIDSPACES:-true}" = "true" ]; then
  fetch "$PATCH_RAW/common/droidspaces/fix_sysvipc_kabi_6_7_8.patch" "$tmp/kabi.patch"
  apply "Droidspaces sysvipc kABI（sched.h 预留槽）" "$tmp/kabi.patch"

  # OPLUS bsp_midas 在容器场景下的空任务 panic 修复
  fetch "$PATCH_RAW/common/droidspaces/0001-Return-ghost-task-if-task-is-null-and-is-requested-b.patch" "$tmp/ghost.patch"
  apply "OPLUS bsp_midas 空任务修复（kernel/pid.c）" "$tmp/ghost.patch"
else
  say "DROIDSPACES=false：跳过 Droidspaces kABI/ghost 补丁"
fi

# ------------------------------------------------------------
# 1.5 kABI CRC 校验旁路（必须！）
#    手机固件 PLF110_16.0.2.401 的内核源码从未公开，仓库里最接近的两个版本
#    （16.0.0.203 / 16.0.3.500）编出来的 genksyms CRC 摘要都与原厂不同，
#    run6/run7 实测 51 个符号里 19 个 CRC 不一致 → 原厂 vendor 模块全部被
#    "disagrees about version of symbol module_layout" 拒绝加载 →
#    UFS 等存储模块装不上 → 找不到 super/metadata 分区 → init panic 重启。
#    但 BTF 全量比对已证明真实 ABI 一致：10335 个公共结构体只有 5 个 OEM 内部
#    结构体有差异，struct module 的 70 个字段偏移完全相同。
#    因此这里让内核只打警告、不拒绝加载。
# ------------------------------------------------------------
if [ "${KABI_BYPASS:-true}" = "true" ]; then
  say "kABI CRC 校验旁路（放行原厂 vendor 模块）"
  if patch -p1 --forward --fuzz=3 < "$GITHUB_WORKSPACE/patches/kabi_bypass.patch"; then
    grep -q 'oplus-kabi-bypass' kernel/module/version.c \
      || { echo "::error::kABI bypass 补丁内容校验失败"; exit 1; }
    echo "kABI bypass 已生效"
  else
    echo "::error::kABI bypass 补丁应用失败"; exit 1
  fi
else
  say "KABI_BYPASS=false：保留严格 CRC 校验（原厂模块将无法加载）"
fi

# ------------------------------------------------------------
# 2. 可选功能补丁（本次全部 false，全部跳过）
# ------------------------------------------------------------
BBRV3_OK=false
NTSYNC_OK=false

if [ "${BBRV3:-false}" = "true" ]; then
  fetch "$PATCH_RAW/common/bbrv3/0001-net-tcp-backport-BBRv3-to-android14-6.1.patch" "$tmp/bbrv3.patch"
  if apply_optional "BBRv3 backport (android14-6.1)" "$tmp/bbrv3.patch"; then BBRV3_OK=true; fi
fi

if [ "${NTSYNC:-false}" = "true" ]; then
  # 来源：Goldzxcbug/Droidspaces_Kernel_patch @dc0f76bedd790b7738e5695509297ee71ca4a2c2
  #       （README 标注 NTsync 所需补丁 = ntsync_base + ntsync_<android版本>-<内核版本>）
  apply_required "NTsync base（drivers/misc/ntsync.c + include/uapi/linux/ntsync.h）" \
    "$GITHUB_WORKSPACE/patches/ds_ntsync_base.patch"
  apply_required "NTsync compat（android14-6.1：drivers/misc/Kconfig + Makefile）" \
    "$GITHUB_WORKSPACE/patches/ds_ntsync_compat_android14-6.1.patch"
  grep -q 'NTSYNC_NAME' drivers/misc/ntsync.c \
    || { echo "::error::NTsync 驱动源码校验失败"; exit 1; }
  grep -q 'obj-$(CONFIG_NTSYNC)' drivers/misc/Makefile \
    || { echo "::error::NTsync Makefile 校验失败"; exit 1; }
  NTSYNC_OK=true
fi

if [ "${CGROUP_LIMITS:-false}" = "true" ]; then
  # 原厂 6.1.134 config 里 CONFIG_CGROUP_PIDS / CONFIG_CFS_BANDWIDTH 是关的
  # （Droidspaces check 里 [✗] CPU limit / [✗] Process limit）。
  # 这两个功能在 Android KMI 冻结后才被打开会改 cgroup 子系统编号/数组边界，
  # 这个补丁用 "ABI 可见数组保持原边界、cgroup core 走额外运行时槽位" 的方式
  # 兼容原厂预编译模块。改 Droidspaces 容器限额验证用。
  apply_required "cgroup 限制 KMI 兼容补丁（CGROUP_PIDS + CFS_BANDWIDTH）" \
    "$GITHUB_WORKSPACE/patches/ds_cgroup_limits_6.1.patch"
  grep -q 'CGROUP_SUBSYS_COUNT_ACTIVE' include/linux/cgroup-defs.h \
    || { echo "::error::cgroup 限制补丁内容校验失败"; exit 1; }
  CGROUP_LIMITS_OK=true
fi

if [ "${USERNS_CVE:-false}" = "true" ]; then
  # CVE-2026-43499：user namespace 下 rtmutex remove_waiter() 用 current 而非
  # waiter->task，可被用来提权。本内核 CONFIG_USER_NS=y，建议补上。
  # 补丁按 6.1 系列的后向移植版本打（我们的 6.1.134 上下文兼容，已在本地 dry-run 验证）。
  apply_required "CVE-2026-43499 user-namespace rtmutex 修复（6.1）" \
    "$GITHUB_WORKSPACE/patches/ds_cve_userns_rtmutex_6.1.patch"
  grep -q 'waiter_task' kernel/locking/rtmutex.c \
    || { echo "::error::CVE 补丁内容校验失败"; exit 1; }
fi

if [ "${UNICODE_FIX:-false}" = "true" ]; then
  fetch "$PATCH_RAW/common/unicode_bypass_fix_6.1-.patch" "$tmp/unicode.patch"
  apply_optional "Unicode 文件名兼容修复" "$tmp/unicode.patch"
fi

if [ "${SDP_CHARGE:-false}" = "true" ]; then
  fetch "$PATCH_RAW/oneplus/0001-misc-oplus-sdp-900ma.patch" "$tmp/sdp900.patch"
  apply_optional "USB SDP 充电 500mA -> 900mA" "$tmp/sdp900.patch"
fi

# WildKernels 的优化补丁集（内存/IO/调度/网络小优化，同机型已长期验证）
if [ "${PERF_TWEAKS:-false}" = "true" ]; then
  say "应用 WildKernels 优化补丁集（失败自动跳过）"
  perf_patches=(
    optimized_mem_operations
    file_struct_8bytes_align
    reduce_cache_pressure
    mem_opt_prefetch
    minimise_wakeup_time
    int_sqrt
    force_tcp_nodelay
    reduce_gc_thread_sleep_time
    add_timeout_wakelocks_globally
    f2fs_reduce_congestion
    reduce_freeze_timeout
    add_limitation_scaling_min_freq
    re_write_limitation_scaling_min_freq
    adjust_cpu_scan_order
    avoid_extra_s2idle_wake_attempts
    disable_cache_hot_buddy
    f2fs_enlarge_min_fsync_blocks
    increase_ext4_default_commit_age
    increase_sk_mem_packets
    reduce_pci_pme_wakeups
    silence_irq_cpu_logspam
    silence_system_logspam
  )
  for p in "${perf_patches[@]}"; do
    fetch "$PATCH_RAW/common/$p.patch" "$tmp/$p.patch"
    apply_optional "优化补丁 $p" "$tmp/$p.patch" || true
  done
fi

# ------------------------------------------------------------
# 3. 写配置
#    基线 = 设备原厂 /proc/config.gz（生产配置，含 ARCH_MEDIATEK/OPLUS/MTK 全套内置驱动）
#    !! 不能用 Google 的 gki_defconfig：那是通用最小配置，缺 200+ 个原厂 =y 的
#       MTK/OPLUS 内置驱动，导致第一段 init 挂载失败 → kernel panic "Attempted to kill init"
#    Kconfig 后写覆盖前写，所以增量直接 append 在后面
# ------------------------------------------------------------
cfg=arch/arm64/configs/plf110_defconfig
say "写入配置（原厂 config + 最小增量）：$cfg"
[ -f "$STOCK_CONFIG" ] || { echo "STOCK_CONFIG 不存在: $STOCK_CONFIG" >&2; exit 1; }
cp "$STOCK_CONFIG" "$cfg"

# ============================================================
# 3.1 关闭的功能：全部写成 "# CONFIG_XXX is not set" 占位
#     （原厂 config 里这些符号本来就是 not set，这里再写一遍是显式固定，
#       也保证不会有人以为"删掉就算关了"）
# ============================================================
{
  echo
  echo '# ============================================================'
  echo '# 已关闭的功能（占位保留，不删除；改 features.env 为 true 即恢复）'
  echo '# ============================================================'

  # --- BBR ---
  echo ''
  echo '# ---- BBR（关闭）----'
  not_set TCP_CONG_ADVANCED TCP_CONG_BBR

  # --- BBRv3（源码补丁；补丁未打时符号不存在，kconfig 会静默忽略） ---
  echo ''
  echo '# ---- BBRv3（关闭，源码补丁未应用）----'
  not_set TCP_CONG_BBR3

  # --- 网络调度器（FQ 是原厂自带 =y，保留不动）---
  echo ''
  echo '# ---- 网络调度器（关闭；原厂 NET_SCH_FQ=y 保留）----'
  not_set NET_SCH_CAKE NET_SCH_PIE NET_SCH_FQ_PIE

  # --- IP_SET + IPv6 NAT ---
  echo ''
  echo '# ---- IP_SET + IPv6 NAT（关闭）----'
  not_set IP_SET IP_SET_BITMAP_IP IP_SET_BITMAP_IPMAC IP_SET_BITMAP_PORT \
          IP_SET_HASH_IP IP_SET_HASH_IPMARK IP_SET_HASH_IPPORT IP_SET_HASH_IPPORTIP \
          IP_SET_HASH_IPPORTNET IP_SET_HASH_IPMAC IP_SET_HASH_MAC IP_SET_HASH_NETPORTNET \
          IP_SET_HASH_NET IP_SET_HASH_NETNET IP_SET_HASH_NETPORT IP_SET_HASH_NETIFACE \
          IP_SET_LIST_SET NETFILTER_XT_MATCH_ADDRTYPE NETFILTER_XT_SET \
          IP6_NF_NAT IP6_NF_TARGET_MASQUERADE

  # --- TTL / Hop-Limit ---
  echo ''
  echo '# ---- TTL / Hop-Limit target（关闭）----'
  not_set IP_NF_TARGET_TTL IP6_NF_TARGET_HL IP6_NF_MATCH_HL

  # --- NTSync（补丁未应用）---
  echo ''
  echo '# ---- NTSync（关闭，补丁未应用）----'
  not_set NTSYNC

  # --- NTFS3 ---
  echo ''
  echo '# ---- NTFS3（关闭）----'
  not_set NTFS3_FS NTFS3_LZX_XPRESS NTFS3_FS_POSIX_ACL

  # --- SQUASHFS ---
  echo ''
  echo '# ---- SQUASHFS（关闭）----'
  not_set SQUASHFS SQUASHFS_XATTR SQUASHFS_ZSTD SQUASHFS_LZ4

  # --- 额外文件系统（NETWORK_FILESYSTEMS 原厂=y，保留不动）---
  echo ''
  echo '# ---- 额外文件系统 ISO9660/UDF/CIFS/NFS（关闭）----'
  not_set ISO9660_FS JOLIET ZISOFS UDF_FS CIFS CIFS_XATTR CIFS_POSIX \
          NFS_FS NFS_V3 NFS_V4 NFS_V4_1

  # --- 容器网络增强（MACVLAN 由 Droidspaces 管理，这里不碰）---
  echo ''
  echo '# ---- 容器网络增强 IPVLAN / XT_TARGET_CHECKSUM（关闭）----'
  not_set IPVLAN NETFILTER_XT_TARGET_CHECKSUM

  # --- 默认网络调优 ---
  echo ''
  echo '# ---- 默认网络调优（关闭）----'
  not_set NET_SCH_DEFAULT
} >> "$cfg"

# ============================================================
# 3.2 Droidspaces 核心（容器运行必需项，唯一开启的功能）
# ============================================================
if [ "${DROIDSPACES:-true}" = "true" ]; then
  say "DROIDSPACES=true：写入容器必需配置"
cat >> "$cfg" <<'EOF'

# ==== Droidspaces 支持（容器运行必需） ====
CONFIG_SYSVIPC=y
CONFIG_POSIX_MQUEUE=y
CONFIG_IPC_NS=y
CONFIG_UTS_NS=y
CONFIG_PID_NS=y
CONFIG_DEVTMPFS=y
CONFIG_USER_NS=y
CONFIG_MACVLAN=y
CONFIG_NETFILTER_XT_TARGET_LOG=y
CONFIG_NETFILTER_XT_MATCH_RECENT=y
CONFIG_IP_NF_TARGET_REJECT=y
CONFIG_IP6_NF_TARGET_REJECT=y
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_NETFILTER_ADVANCED=y
EOF
else
  {
    echo
    echo '# ==== Droidspaces 支持（关闭）===='
    not_set SYSVIPC POSIX_MQUEUE IPC_NS UTS_NS PID_NS DEVTMPFS USER_NS \
            MACVLAN NETFILTER_XT_TARGET_LOG NETFILTER_XT_MATCH_RECENT \
            IP_NF_TARGET_REJECT IP6_NF_TARGET_REJECT TMPFS_XATTR TMPFS_POSIX_ACL
  } >> "$cfg"
fi

# ============================================================
# 3.3 其它已关闭功能的配置增量
# ============================================================
if [ "${BBR:-false}" = "true" ]; then
cat >> "$cfg" <<'EOF'

# ==== BBR ====
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
EOF
fi

if [ "${BBRV3_OK:-false}" = "true" ]; then
cat >> "$cfg" <<'EOF'
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR3=y
EOF
fi

if [ "${NTSYNC_OK:-false}" = "true" ]; then
cat >> "$cfg" <<'EOF'

# ==== NTSync（Wine / Windows 程序；补丁源码见 patches/ds_ntsync_*.patch）====
CONFIG_NTSYNC=y
EOF
fi

if [ "${CGROUP_LIMITS_OK:-false}" = "true" ]; then
cat >> "$cfg" <<'EOF'

# ==== 容器 CPU / PID 限额（Droidspaces --cpus / --pids-limit）====
# 依赖 patches/ds_cgroup_limits_6.1.patch（KMI 兼容版，保持原厂模块 ABI 边界）
CONFIG_CGROUP_PIDS=y
CONFIG_CFS_BANDWIDTH=y
EOF
fi

if [ "${NET_SCHED:-false}" = "true" ]; then
cat >> "$cfg" <<'EOF'

# ==== 网络调度器 ====
CONFIG_NET_SCH_CAKE=y
CONFIG_NET_SCH_PIE=y
CONFIG_NET_SCH_FQ_PIE=y
EOF
fi

if [ "${IP_SET_NAT:-false}" = "true" ]; then
cat >> "$cfg" <<'EOF'

# ==== IP_SET + IPv6 NAT ====
CONFIG_IP_SET=y
CONFIG_IP_SET_MAX=65534
CONFIG_IP_SET_BITMAP_IP=y
CONFIG_IP_SET_BITMAP_IPMAC=y
CONFIG_IP_SET_BITMAP_PORT=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_IPMARK=y
CONFIG_IP_SET_HASH_IPPORT=y
CONFIG_IP_SET_HASH_IPPORTIP=y
CONFIG_IP_SET_HASH_IPPORTNET=y
CONFIG_IP_SET_HASH_IPMAC=y
CONFIG_IP_SET_HASH_MAC=y
CONFIG_IP_SET_HASH_NETPORTNET=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_IP_SET_HASH_NETNET=y
CONFIG_IP_SET_HASH_NETPORT=y
CONFIG_IP_SET_HASH_NETIFACE=y
CONFIG_IP_SET_LIST_SET=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_SET=y
CONFIG_IP6_NF_NAT=y
CONFIG_IP6_NF_TARGET_MASQUERADE=y
EOF
fi

if [ "${TTL_TARGET:-false}" = "true" ]; then
cat >> "$cfg" <<'EOF'

# ==== TTL target（热点共享用） ====
CONFIG_IP_NF_TARGET_TTL=y
CONFIG_IP6_NF_TARGET_HL=y
CONFIG_IP6_NF_MATCH_HL=y
EOF
fi

if [ "${NTFS3:-false}" = "true" ]; then
cat >> "$cfg" <<'EOF'

# ==== NTFS3 ====
CONFIG_NTFS3_FS=y
CONFIG_NTFS3_LZX_XPRESS=y
CONFIG_NTFS3_FS_POSIX_ACL=y
EOF
fi

if [ "${SQUASHFS:-false}" = "true" ]; then
cat >> "$cfg" <<'EOF'

# ==== SQUASHFS ====
CONFIG_SQUASHFS=y
CONFIG_SQUASHFS_XATTR=y
CONFIG_SQUASHFS_ZSTD=y
CONFIG_SQUASHFS_LZ4=y
EOF
fi

if [ "${EXTRA_FS:-false}" = "true" ]; then
cat >> "$cfg" <<'EOF'

# ==== 额外文件系统 ====
CONFIG_NETWORK_FILESYSTEMS=y
CONFIG_ISO9660_FS=y
CONFIG_JOLIET=y
CONFIG_ZISOFS=y
CONFIG_UDF_FS=y
CONFIG_CIFS=y
CONFIG_CIFS_XATTR=y
CONFIG_CIFS_POSIX=y
CONFIG_NFS_FS=y
CONFIG_NFS_V3=y
CONFIG_NFS_V4=y
CONFIG_NFS_V4_1=y
EOF
fi

if [ "${CONTAINER_NET:-false}" = "true" ]; then
cat >> "$cfg" <<'EOF'

# ==== 容器网络增强 ====
CONFIG_MACVLAN=y
CONFIG_IPVLAN=y
CONFIG_NETFILTER_XT_TARGET_CHECKSUM=y
EOF
fi

if [ "${NET_DEFAULTS:-false}" = "true" ]; then
  {
    echo
    echo '# ==== 默认网络调优 ===='
    if [ "${BBR:-false}" = "true" ]; then echo 'CONFIG_DEFAULT_BBR=y'; fi
    if [ "${NET_SCHED:-false}" = "true" ]; then
      echo 'CONFIG_NET_SCH_DEFAULT=y'
      echo 'CONFIG_DEFAULT_FQ=y'
    fi
  } >> "$cfg"
fi

# ------------------------------------------------------------
# 4. LTO（本次不动；CFI 不受影响：kcfi 不需要 LTO，原厂 CFI 保持开启以兼容 stock 模块）
# ------------------------------------------------------------
say "LTO 模式：${LTO_MODE:-none}"
case "${LTO_MODE:-none}" in
  thin)
cat >> "$cfg" <<'EOF'

# ==== LTO thin ====
# CONFIG_LTO_NONE is not set
CONFIG_LTO_CLANG_THIN=y
EOF
    ;;
  none)
cat >> "$cfg" <<'EOF'

# ==== 无 LTO（与原厂一致；CFI 仍然开启）====
CONFIG_LTO_NONE=y
# CONFIG_LTO_CLANG_THIN is not set
# CONFIG_LTO_CLANG_FULL is not set
EOF
    ;;
  *)
    echo "未知 LTO_MODE: ${LTO_MODE}" >&2; exit 1 ;;
esac

# ------------------------------------------------------------
# 5. 调试选项
#    !! ABI 红线：KUNIT / DEBUG_INFO_BTF / DEBUG_INFO_BTF_MODULES / DEBUG_INFO
#       这四个会改变 struct module 的字段布局（include/linux/module.h 里的 #ifdef），
#       而导出符号 module_layout 的 CRC 是 genksyms 按"函数签名用到的类型"算的，
#       包含 struct module 完整定义 → 一旦改掉，原厂 vendor 模块全部报
#         "disagrees about version of symbol module_layout" → Exec format error
#       → 第一段 init 加载不了模块 → 开不了机（run5 实测踩坑，pstore 有日志）。
#       所以这里只关「不影响 struct module / 导出 CRC」的调试项，
#       并且显式把 ABI 相关的四项钉在原厂的 y。
# ------------------------------------------------------------
cat >> "$cfg" <<'EOF'

# ==== kABI 红线（必须与原厂一致，否则 vendor 模块加载失败）====
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO_DWARF4=y
# CONFIG_DEBUG_INFO_NONE is not set
CONFIG_DEBUG_INFO_BTF=y
CONFIG_DEBUG_INFO_BTF_MODULES=y
CONFIG_KUNIT=y
EOF

if [ "${DEBUG_INFO:-false}" != "true" ]; then
  say "关闭不影响 kABI 的调试选项（KASAN/KFENCE/UBSAN/PAGE_OWNER/PANIC_ON_OOPS）"
cat >> "$cfg" <<'EOF'

# ==== Production debug off（只关不影响导出 CRC 的项）====
# CONFIG_KASAN is not set
# CONFIG_KFENCE is not set
# CONFIG_UBSAN is not set
# CONFIG_PAGE_OWNER is not set
# CONFIG_PANIC_ON_OOPS is not set
CONFIG_FRAME_WARN=0
EOF
fi

# ------------------------------------------------------------
# 6. 构建必需修正 + 其它小配置（本次不动）
# ------------------------------------------------------------
cat >> "$cfg" <<'EOF'

# ==== 构建必需：模块签名密钥 ====
# 原厂 config 是 CONFIG_MODULE_SIG_KEY="$(DEVICE_MODULES_REL_DIR)/certs/mtk_signing_key.pem"
# —— $(DEVICE_MODULES_REL_DIR) 只在 OPPO 内部 build 里定义，OSS 编译时展开成空字符串，
#    就变成绝对路径 /certs/mtk_signing_key.pem；certs/signing_key.x509 找不到依赖 →
#    make 直接失败："No rule to make target '/certs/mtk_signing_key.pem'"（run4 就是死在这）。
# 改回内核默认值 certs/signing_key.pem：构建系统会自动生成一次性密钥。
# MODULE_SIG_FORCE 原厂就是 =n，所以不影响加载原厂 vendor 模块。
CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"

# ==== 杂项 ====
CONFIG_NLS_DEFAULT="utf8"
CONFIG_FUSE_FS=y
CONFIG_TUN=y
EOF

say "准备完成"
tail -n 15 "$cfg"
