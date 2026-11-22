#!/usr/bin/env bash
# ============================================================
#  PLF110 (OnePlus ACE 5 Racing, MT6989, Android 16, 6.1.134)
#  内核定制准备脚本：打补丁 + 生成 defconfig
#  由 GitHub Actions 调用；本地 Linux 也能直接跑：
#     KDIR=/path/to/android_kernel_oneplus_mt6989-770ca1ea... \
#     PATCH_RAW=https://raw.githubusercontent.com/WildKernels/kernel_patches/main \
#     bash scripts/prepare.sh
# ============================================================
set -euo pipefail

: "${KDIR:?KDIR 未设置}"
: "${PATCH_RAW:?PATCH_RAW 未设置}"

cd "$KDIR"

say() { printf '\n===== %s =====\n' "$*"; }
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

# ------------------------------------------------------------
# 1. Droidspaces 必需补丁（GKI kABI 补丁，不能省）
# ------------------------------------------------------------
fetch "$PATCH_RAW/common/droidspaces/fix_sysvipc_kabi_6_7_8.patch" "$tmp/kabi.patch"
apply "Droidspaces sysvipc kABI（sched.h 预留槽）" "$tmp/kabi.patch"

# OPLUS bsp_midas 在容器场景下的空任务 panic 修复
fetch "$PATCH_RAW/common/droidspaces/0001-Return-ghost-task-if-task-is-null-and-is-requested-b.patch" "$tmp/ghost.patch"
apply "OPLUS bsp_midas 空任务修复（kernel/pid.c）" "$tmp/ghost.patch"

# ------------------------------------------------------------
# 2. 可选功能补丁
# ------------------------------------------------------------
BBRV3_OK=false
NTSYNC_OK=false

if [ "${BBRV3:-false}" = "true" ]; then
  fetch "$PATCH_RAW/common/bbrv3/0001-net-tcp-backport-BBRv3-to-android14-6.1.patch" "$tmp/bbrv3.patch"
  if apply_optional "BBRv3 backport (android14-6.1)" "$tmp/bbrv3.patch"; then BBRV3_OK=true; fi
fi

if [ "${NTSYNC:-false}" = "true" ]; then
  NTSYNC_PARTS=0
  fetch "$PATCH_RAW/common/ntsync/ntsync_compat_android14-6.1.patch" "$tmp/ntsync_compat.patch"
  if apply_optional "NTSync compat (android14-6.1)" "$tmp/ntsync_compat.patch"; then NTSYNC_PARTS=$((NTSYNC_PARTS+1)); fi
  fetch "$PATCH_RAW/common/ntsync/ntsync_base.patch" "$tmp/ntsync_base.patch"
  if apply_optional "NTSync base" "$tmp/ntsync_base.patch"; then NTSYNC_PARTS=$((NTSYNC_PARTS+1)); fi
  if [ "$NTSYNC_PARTS" -eq 2 ]; then NTSYNC_OK=true; fi
fi

if [ "${UNICODE:-false}" = "true" ]; then
  fetch "$PATCH_RAW/common/unicode_bypass_fix_6.1-.patch" "$tmp/unicode.patch"
  apply_optional "Unicode 文件名兼容修复" "$tmp/unicode.patch"
fi

if [ "${SDP900:-false}" = "true" ]; then
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
# 3. 写配置（追加到 gki_defconfig，Kconfig 后写覆盖前写）
# ------------------------------------------------------------
cfg=arch/arm64/configs/gki_defconfig
say "写入配置：$cfg"

# --- Droidspaces 核心（必须） ---
cat >> "$cfg" <<'EOF'

# ==== Droidspaces 支持 ====
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
EOF

# --- BBR ---
if [ "${BBR:-true}" = "true" ]; then
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

# --- NTSync（补丁成功才开配置） ---
if [ "${NTSYNC_OK:-false}" = "true" ]; then
cat >> "$cfg" <<'EOF'

# ==== NTSync（Wine / Windows 游戏）====
CONFIG_NTSYNC=y
EOF
fi

# --- 网络调度器 ---
if [ "${NETSCHED:-true}" = "true" ]; then
cat >> "$cfg" <<'EOF'

# ==== 网络调度器 ====
CONFIG_NET_SCH_CAKE=y
CONFIG_NET_SCH_PIE=y
CONFIG_NET_SCH_FQ_PIE=y
EOF
fi

# --- IP_SET + IPv6 NAT（Droidspaces NAT / UFW） ---
if [ "${IPSET:-true}" = "true" ]; then
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

# --- TTL / Hop Limit ---
if [ "${TTL:-false}" = "true" ]; then
cat >> "$cfg" <<'EOF'

# ==== TTL target（热点共享用） ====
CONFIG_IP_NF_TARGET_TTL=y
CONFIG_IP6_NF_TARGET_HL=y
CONFIG_IP6_NF_MATCH_HL=y
EOF
fi

# --- NTFS3 ---
if [ "${NTFS3:-true}" = "true" ]; then
cat >> "$cfg" <<'EOF'

# ==== NTFS3 ====
CONFIG_NTFS3_FS=y
CONFIG_NTFS3_LZX_XPRESS=y
CONFIG_NTFS3_FS_POSIX_ACL=y
EOF
fi

# --- SQUASHFS ---
if [ "${SQUASHFS:-true}" = "true" ]; then
cat >> "$cfg" <<'EOF'

# ==== SQUASHFS ====
CONFIG_SQUASHFS=y
CONFIG_SQUASHFS_XATTR=y
CONFIG_SQUASHFS_ZSTD=y
CONFIG_SQUASHFS_LZ4=y
EOF
fi

# --- 额外文件系统：ISO9660/UDF（挂 ISO）+ CIFS/SMB（NAS）+ NFS ---
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

# --- 容器网络增强 ---
if [ "${CONTAINER_NET:-false}" = "true" ]; then
cat >> "$cfg" <<'EOF'

# ==== 容器网络增强 ====
CONFIG_MACVLAN=y
CONFIG_IPVLAN=y
CONFIG_NETFILTER_XT_TARGET_CHECKSUM=y
EOF
fi

# --- 默认网络调优 ---
if [ "${NET_DEFAULTS:-false}" = "true" ]; then
  {
    echo
    echo '# ==== 默认网络调优 ===='
    if [ "${BBR:-true}" = "true" ]; then echo 'CONFIG_DEFAULT_TCP_CONG="bbr"'; fi
    if [ "${NETSCHED:-true}" = "true" ]; then echo 'CONFIG_DEFAULT_NET_SCH="fq"'; fi
  } >> "$cfg"
fi

# ------------------------------------------------------------
# 4. LTO / CFI
# ------------------------------------------------------------
say "LTO 模式：${LTO_MODE:-thin}"
case "${LTO_MODE:-thin}" in
  thin)
cat >> "$cfg" <<'EOF'

# ==== LTO thin（与原厂一致，CFI 保持开启） ====
CONFIG_LTO_CLANG=y
CONFIG_LTO_CLANG_THIN=y
EOF
    ;;
  none)
cat >> "$cfg" <<'EOF'

# ==== 无 LTO（编译快；CFI 关闭） ====
CONFIG_LTO_NONE=y
# CONFIG_LTO_CLANG is not set
# CONFIG_CFI_CLANG is not set
EOF
    ;;
  *)
    echo "未知 LTO_MODE: ${LTO_MODE}" >&2; exit 1 ;;
esac

# ------------------------------------------------------------
# 5. 生产化：关掉原厂 gki_defconfig 里的调试选项（KASAN/KFENCE/UBSAN/BTF…）
#    —— 这些在 ACK 的 gki_defconfig 里是开着的，日常使用不需要，关掉更快更省内存
# ------------------------------------------------------------
if [ "${DEBUG_INFO:-false}" != "true" ]; then
say "关闭调试选项（KASAN/KFENCE/UBSAN/PAGE_OWNER/PANIC_ON_OOPS/DEBUG_INFO/BTF/KUNIT）"
cat >> "$cfg" <<'EOF'

# ==== Production debug off ====
CONFIG_DEBUG_INFO_NONE=y
# CONFIG_DEBUG_INFO_DWARF4 is not set
# CONFIG_DEBUG_INFO_BTF is not set
# CONFIG_KASAN is not set
# CONFIG_KFENCE is not set
# CONFIG_UBSAN is not set
# CONFIG_PAGE_OWNER is not set
# CONFIG_PANIC_ON_OOPS is not set
# CONFIG_KUNIT is not set
# CONFIG_KUNIT_DEBUGFS is not set
CONFIG_FRAME_WARN=0
EOF
fi

# ------------------------------------------------------------
# 6. 其它小配置
# ------------------------------------------------------------
cat >> "$cfg" <<'EOF'

# ==== 杂项 ====
CONFIG_NLS_DEFAULT="utf8"
CONFIG_FUSE_FS=y
CONFIG_TUN=y
EOF

say "准备完成"
tail -n 12 "$cfg"
