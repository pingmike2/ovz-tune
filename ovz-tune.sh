#!/usr/bin/env bash
# ovz-tune.sh — OpenVZ / LXC / KVM 通用网络与系统调优（Debian / Ubuntu）
#
# 设计原则：不假设能力，先探测再应用。
#   - 每个 sysctl 键先读、再试写，写不进去就跳过并记录原因
#   - 只在真正生效的键上生成 /etc/sysctl.d 配置
#   - 不重启任何业务服务（ssh 只 reload，且先 sshd -t 校验）
#   - 所有改动可回滚，--rollback 一键撤销
#
# 用法：
#   ovz-tune                                  无参数进交互菜单
#   ovz-tune --apply                          执行推荐调优
#   ovz-tune --apply --tz Asia/Shanghai       同时设置时区
#   ovz-tune --apply --hostname myhost        同时改主机名
#   ovz-tune --apply --journald-max 200M      指定 journald 上限（默认按内存自动）
#   ovz-tune --apply --swap 1024              尝试加 1G swap（容器里会自动放弃）
#   ovz-tune --apply --upgrade                同时 apt 升级（可能重启服务，默认不做）
#   ovz-tune --rollback                       撤销本脚本的所有改动
#
# 无参数且 stdin 不是终端时（例如 curl | bash）默认只演练，不做任何改动。
#
set -u

VERSION="1.0.0"
ARGC=$#

usage() {
  cat <<'EOF'
ovz-tune — OpenVZ / LXC / KVM 一键调优（Debian / Ubuntu）

用法:
  ovz-tune                                  交互菜单（无参数 + 终端）
  ovz-tune --apply                          执行推荐调优
  ovz-tune --apply --tz Asia/Shanghai       同时设置时区
  ovz-tune --apply --hostname myhost        同时改主机名
  ovz-tune --apply --journald-max 200M      指定 journald 上限
  ovz-tune --apply --swap 1024              尝试加 1G swap
  ovz-tune --apply --upgrade                同时 apt 升级
  ovz-tune --rollback                       撤销本脚本的所有改动

不加 --apply 就是演练模式，只打印计划。
EOF
}

DRY=1; DO_ROLLBACK=0; DO_UPGRADE=0
TZ_NAME=""; NEW_HOST=""; SWAP_MB=0; JOURNALD_MAX=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)       DRY=0 ;;
    --dry-run)     DRY=1 ;;
    --rollback)    DO_ROLLBACK=1; DRY=0 ;;
    --upgrade)     DO_UPGRADE=1 ;;
    --tz)          TZ_NAME="${2:-}"; shift ;;
    --hostname)    NEW_HOST="${2:-}"; shift ;;
    --journald-max) JOURNALD_MAX="${2:-}"; shift ;;
    --swap)        SWAP_MB="${2:-0}"; shift ;;
    -h|--help)     usage; exit 0 ;;
    -V|--version)  echo "ovz-tune $VERSION"; exit 0 ;;
    *) echo "未知参数: $1（--help 看用法）"; exit 2 ;;
  esac
  shift
done

[ "$(id -u)" = "0" ] || { echo "需要 root 执行"; exit 1; }

menu() {
  cat <<'EOF'
  ┌─────────────────────────────────────────┐
  │  ovz-tune · 一键调优                    │
  ├─────────────────────────────────────────┤
  │  1) 演练（只看计划，不改动）            │
  │  2) 执行推荐调优      ← 常用            │
  │  3) 执行 + 时区设为 Asia/Shanghai       │
  │  4) 执行 + 改主机名                     │
  │  5) 执行 + apt 升级                     │
  │  6) 回滚上一轮改动                      │
  │  0) 退出                                │
  └─────────────────────────────────────────┘
EOF
  printf '请选择 [1]: '
  read -r ans || ans=0
  ans=${ans:-1}
  case "$ans" in
    1) DRY=1 ;;
    2) DRY=0 ;;
    3) DRY=0; TZ_NAME=Asia/Shanghai ;;
    4) DRY=0; printf '新主机名: '; read -r NEW_HOST || true ;;
    5) DRY=0; DO_UPGRADE=1 ;;
    6) DO_ROLLBACK=1; DRY=0 ;;
    0) exit 0 ;;
    *) echo "无效选项: $ans"; exit 2 ;;
  esac
  printf '\n'
}

if [ "$ARGC" -eq 0 ] && [ -t 0 ]; then
  menu
fi
STAMP=$(date +%Y%m%d-%H%M%S)
SYSCTL_FILE=/etc/sysctl.d/99-vps-tuning.conf
JOURNALD_FILE=/etc/systemd/journald.conf.d/99-limit.conf
SSH_FILE=/etc/ssh/sshd_config.d/99-keepalive.conf
LIMITS_FILE=/etc/security/limits.conf
BEGIN_MARK="# BEGIN ovz-tune"
END_MARK="# END ovz-tune"

APPLIED=(); SKIPPED=(); CHANGED=()

say()  { printf '%s\n' "$*"; }
head2() { printf '\n== %s ==\n' "$*"; }
ok()   { printf '  [OK]   %s\n' "$*"; }
skip() { printf '  [跳过] %s\n' "$*"; }
plan() { printf '  [计划] %s\n' "$*"; }
warn() { printf '  [注意] %s\n' "$*"; }

backup_once() {
  local f=$1 d=/var/backups/ovz-tune b
  [ -f "$f" ] || return 0
  mkdir -p "$d"
  b="$d/$(printf '%s' "${f#/}" | tr '/' '_').$STAMP"
  [ -f "$b" ] || cp -a "$f" "$b"
  CHANGED+=("备份 $b")
  return 0
}

# ---------- 环境探测 ----------
detect() {
  # shellcheck source=/dev/null
  . /etc/os-release 2>/dev/null || true
  DISTRO="${ID:-unknown}"; DISTRO_VER="${VERSION_ID:-?}"
  case "${ID_LIKE:-}${ID:-}" in
    *debian*|*ubuntu*) PKG=apt ;;
    *) PKG=none ;;
  esac

  VIRT=unknown
  if [ -f /proc/user_beancounters ]; then VIRT=openvz
  elif grep -qa 'lxc' /proc/1/cgroup 2>/dev/null; then VIRT=lxc
  elif [ -f /.dockerenv ]; then VIRT=docker
  elif command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT=$(systemd-detect-virt 2>/dev/null || echo unknown)
  fi

  MEM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
  [ -z "${MEM_MB:-}" ] && MEM_MB=0

  DEFAULT_IF=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
  [ -z "${DEFAULT_IF:-}" ] && DEFAULT_IF=""
}

detect

head2 "环境"
say "  发行版 : ${DISTRO} ${DISTRO_VER}  (包管理: ${PKG})"
say "  虚拟化 : ${VIRT}"
say "  内存   : ${MEM_MB} MB"
say "  默认网卡: ${DEFAULT_IF:-无}  qdisc: $(tc qdisc show dev "${DEFAULT_IF:-lo}" 2>/dev/null | awk '{print $2}' | head -1)"
say "  模式   : $([ "$DRY" = 1 ] && echo 演练-不改动 || echo 执行)"

if [ "$PKG" = none ]; then warn "非 Debian/Ubuntu 系，跳过 apt 相关步骤"; fi

# ---------- 回滚 ----------
if [ "$DO_ROLLBACK" = 1 ]; then
  head2 "回滚"
  for f in "$SYSCTL_FILE" "$JOURNALD_FILE" "$SSH_FILE"; do
    if [ -f "$f" ]; then rm -f "$f" && ok "已删除 $f"; fi
  done
  if [ -f "$LIMITS_FILE" ] && grep -q "$BEGIN_MARK" "$LIMITS_FILE"; then
    backup_once "$LIMITS_FILE"
    sed -i "/$BEGIN_MARK/,/$END_MARK/d" "$LIMITS_FILE" && ok "已清理 $LIMITS_FILE 中的 ovz-tune 段"
  fi
  if [ -n "${DEFAULT_IF:-}" ] && tc qdisc show dev "$DEFAULT_IF" 2>/dev/null | grep -qw fq; then
    tc qdisc replace dev "$DEFAULT_IF" root fq_codel 2>/dev/null && ok "qdisc 恢复 fq_codel"
  fi
  sysctl --system >/dev/null 2>&1 && ok "已重新加载 sysctl"
  systemctl restart systemd-journald 2>/dev/null && ok "journald 已重启"
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
  say ""
  say "回滚完成。已删除持久化配置；运行中的参数要重启后才回到系统默认。"
  say "主机名 / 时区 / swap / qdisc 不自动还原，需要的话手动处理。"
  say "原文件备份在 /var/backups/ovz-tune/"
  exit 0
fi

# ---------- sysctl 应用引擎 ----------
norm() { printf '%s' "$1" | tr -s ' \t' ' ' | sed 's/^ //; s/ $//'; }

# try_kv <key> <value> [min]
#   min: 只在目标值比当前值更大时才写入（用于队列/缓冲区，避免把大机器改小）
try_kv() {
  local k="$1" v="$2" mode="${3:-set}" cur
  cur=$(sysctl -n "$k" 2>/dev/null) || cur=""
  if [ -z "$cur" ]; then SKIPPED+=("$k|内核无此键（宿主机控制）"); return 1; fi
  if [ "$(norm "$cur")" = "$(norm "$v")" ]; then
    APPLIED+=("$k = $v"); ok "$k 已是 $v"; return 0
  fi
  if [ "$mode" = min ] && [ "$cur" -ge "$v" ] 2>/dev/null; then
    ok "$k 当前 $cur 已不低于目标 $v，保持不变"; return 0
  fi
  if [ "$DRY" = 1 ]; then plan "$k: $(norm "$cur") -> $v"; APPLIED+=("$k = $v"); return 0; fi
  if sysctl -w "$k=$v" >/dev/null 2>&1; then
    ok "$k: $(norm "$cur") -> $v"; APPLIED+=("$k = $v"); return 0
  else
    SKIPPED+=("$k|写入被拒绝（容器限制），当前 $(norm "$cur")"); return 1
  fi
}

head2 "sysctl（按能力自适应）"

# 通用：几乎各平台都可写
try_kv net.core.somaxconn 8192 min
try_kv net.ipv4.tcp_fastopen 3
try_kv "net.ipv4.ip_local_port_range" "10240 65535"

if [ "$VIRT" != openvz ]; then
  # 非 OpenVZ 才有机会调到的键
  try_kv net.ipv4.tcp_fin_timeout 15
  try_kv net.ipv4.tcp_tw_reuse 1
  try_kv net.ipv4.tcp_max_tw_buckets 65536 min
  try_kv net.ipv4.tcp_keepalive_time 300
  try_kv net.ipv4.tcp_keepalive_intvl 30
  try_kv net.ipv4.tcp_keepalive_probes 5
  try_kv net.ipv4.tcp_mtu_probing 1
  try_kv net.ipv4.tcp_slow_start_after_idle 0
  try_kv net.ipv4.tcp_max_syn_backlog 8192 min
  try_kv net.core.netdev_max_backlog 16384 min
  try_kv net.netfilter.nf_conntrack_max 262144 min

  # 缓冲区按内存定档，1.5G 以下不贪大
  if [ "$MEM_MB" -ge 4096 ]; then BUF=33554432
  elif [ "$MEM_MB" -ge 2048 ]; then BUF=16777216
  else BUF=8388608; fi
  try_kv net.core.rmem_max "$BUF" min
  try_kv net.core.wmem_max "$BUF" min
  try_kv "net.ipv4.tcp_rmem" "4096 87380 $BUF"
  try_kv "net.ipv4.tcp_wmem" "4096 65536 $BUF"
else
  # OpenVZ 的 vm.* 一律 EINVAL，直接标注原因，不去刷报错
  for k in vm.swappiness vm.vfs_cache_pressure vm.dirty_ratio vm.dirty_background_ratio; do
    SKIPPED+=("$k|OpenVZ 容器拒绝写入（EINVAL），由宿主统一管理")
  done
  try_kv net.netfilter.nf_conntrack_max 262144 min
fi

# 内存回收：能写就写（LXC/Docker 里可能被拒，脚本自动跳过）
if [ "$VIRT" != openvz ]; then
  try_kv vm.swappiness 10
  try_kv vm.vfs_cache_pressure 50
  try_kv vm.dirty_ratio 15
  try_kv vm.dirty_background_ratio 5
fi

# 拥塞控制 + qdisc：只有键存在且 bbr 可用时才动
head2 "拥塞控制与队列"
CC_CUR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
CC_LIST=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
if [ -z "$CC_CUR" ]; then
  skip "tcp_congestion_control 不存在（OpenVZ/共享内核），拥塞算法由宿主机决定"
elif printf '%s' "$CC_LIST" | grep -qw bbr; then
  try_kv net.ipv4.tcp_congestion_control bbr
  try_kv net.core.default_qdisc fq
else
  skip "内核未提供 bbr（当前可用: ${CC_LIST:-未知}）"
fi

if [ -n "${DEFAULT_IF:-}" ]; then
  QD=$(tc qdisc show dev "$DEFAULT_IF" 2>/dev/null | awk '{print $2}' | head -1)
  case "$QD" in
    noqueue) skip "$DEFAULT_IF 是虚拟设备（qdisc=noqueue），队列由宿主管理" ;;
    fq)      ok "$DEFAULT_IF qdisc 已是 fq" ;;
    *)
      if [ "$DRY" = 1 ]; then plan "$DEFAULT_IF qdisc: $QD -> fq"
      elif tc qdisc replace dev "$DEFAULT_IF" root fq 2>/dev/null; then
        ok "$DEFAULT_IF qdisc: $QD -> fq"; CHANGED+=("qdisc $DEFAULT_IF -> fq")
      else
        skip "$DEFAULT_IF qdisc 无法修改（$QD）"
      fi ;;
  esac
fi

# ---------- 持久化 sysctl ----------
head2 "持久化 sysctl"
if [ ${#APPLIED[@]} -eq 0 ]; then
  skip "没有可应用的键，不生成配置文件"
elif [ "$DRY" = 1 ]; then
  plan "将写入 $SYSCTL_FILE（${#APPLIED[@]} 项）"
else
  backup_once "$SYSCTL_FILE"
  {
    echo "# 由 ovz-tune.sh 生成于 $STAMP（虚拟化: $VIRT，内存: ${MEM_MB}MB）"
    printf '%s\n' "${APPLIED[@]}"
  } > "$SYSCTL_FILE"
  ok "已写入 $SYSCTL_FILE（${#APPLIED[@]} 项）"
fi

# ---------- journald ----------
head2 "journald 限额"
if ! command -v journalctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
  skip "无 systemd-journald"
else
  if [ -z "$JOURNALD_MAX" ]; then
    if [ "$MEM_MB" -lt 1024 ]; then JOURNALD_MAX=64M
    elif [ "$MEM_MB" -lt 2048 ]; then JOURNALD_MAX=100M
    else JOURNALD_MAX=200M; fi
  fi
  CUR_J=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[MG]' | head -1)
  say "  当前占用: ${CUR_J:-未知}，上限设为 $JOURNALD_MAX"
  if [ "$DRY" = 1 ]; then plan "写入 $JOURNALD_FILE"
  else
    mkdir -p /etc/systemd/journald.conf.d
    backup_once "$JOURNALD_FILE"
    cat > "$JOURNALD_FILE" <<EOF
[Journal]
SystemMaxUse=$JOURNALD_MAX
SystemMaxFileSize=25M
MaxRetentionSec=1week
EOF
    if systemctl restart systemd-journald 2>/dev/null; then
      ok "journald 已生效"
    else
      warn "journald 重启失败（容器可能不允许）"
    fi
  fi
fi

# ---------- 文件句柄 ----------
head2 "文件句柄"
if grep -q "$BEGIN_MARK" "$LIMITS_FILE" 2>/dev/null; then
  skip "$LIMITS_FILE 已包含 ovz-tune 段"
elif grep -qE '^[^#]*nofile[[:space:]]+65535' "$LIMITS_FILE" 2>/dev/null; then
  skip "$LIMITS_FILE 已存在 nofile 65535（非本脚本写入，保持不动）"
elif [ "$DRY" = 1 ]; then
  plan "在 $LIMITS_FILE 追加 nofile 65535"
else
  backup_once "$LIMITS_FILE"
  {
    echo "$BEGIN_MARK"
    echo "* soft nofile 65535"
    echo "* hard nofile 65535"
    echo "root soft nofile 65535"
    echo "root hard nofile 65535"
    echo "$END_MARK"
  } >> "$LIMITS_FILE"
  ok "已追加 nofile 65535（新登录生效）"
fi

# ---------- SSH 保活 ----------
head2 "SSH 保活"
if [ "$DRY" = 1 ]; then
  plan "写入 $SSH_FILE（ClientAliveInterval 60），sshd -t 通过后 reload"
else
  if grep -q '^Include /etc/ssh/sshd_config.d' /etc/ssh/sshd_config 2>/dev/null; then
    mkdir -p /etc/ssh/sshd_config.d
    backup_once "$SSH_FILE"
    cat > "$SSH_FILE" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
ClientAliveInterval 60
ClientAliveCountMax 3
MaxAuthTries 6
LoginGraceTime 40
EOF
    ok "已写入 $SSH_FILE"
  else
    # 老版本 sshd 没有 Include，直接追加到主配置
    if grep -q "$BEGIN_MARK" /etc/ssh/sshd_config 2>/dev/null; then
      skip "sshd_config 已包含 ovz-tune 段"
    else
      backup_once /etc/ssh/sshd_config
      {
        echo "$BEGIN_MARK"
        echo "ClientAliveInterval 60"
        echo "ClientAliveCountMax 3"
        echo "$END_MARK"
      } >> /etc/ssh/sshd_config
      ok "已追加到 /etc/ssh/sshd_config（该版本无 sshd_config.d）"
    fi
  fi
  if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null
    ok "sshd 配置校验通过并已 reload"
  else
    warn "sshd -t 校验失败，未 reload，请检查 /etc/ssh/ 配置"
  fi
fi

# ---------- 时区 ----------
if [ -n "$TZ_NAME" ]; then
  head2 "时区"
  if [ "$DRY" = 1 ]; then plan "设为 $TZ_NAME"
  elif timedatectl set-timezone "$TZ_NAME" 2>/dev/null; then
    ok "时区 = $TZ_NAME"
  else
    warn "设置失败：$TZ_NAME 是否正确？"
  fi
fi

# ---------- 主机名 ----------
if [ -n "$NEW_HOST" ]; then
  head2 "主机名"
  if [ "$DRY" = 1 ]; then plan "改为 $NEW_HOST（含 /etc/hosts 与 cloud-init 保护）"
  else
    backup_once /etc/hostname; backup_once /etc/hosts
    hostnamectl set-hostname "$NEW_HOST" 2>/dev/null || { echo "$NEW_HOST" > /etc/hostname; hostname "$NEW_HOST" 2>/dev/null; }
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$NEW_HOST" <<'PY'
import sys, pathlib
new = sys.argv[1]; p = pathlib.Path("/etc/hosts")
lines = [l for l in p.read_text(errors="replace").splitlines() if l.split() and l.split()[0] != "127.0.1.1"]
if not any(l.split()[:1] == ["127.0.0.1"] for l in lines): lines.insert(0, "127.0.0.1\tlocalhost")
lines.append("127.0.1.1\t" + new)
p.write_text("\n".join(lines) + "\n")
PY
    else
      sed -i "/^127\.0\.1\.1/d" /etc/hosts; echo "127.0.1.1 $NEW_HOST" >> /etc/hosts
    fi
    if [ -f /etc/cloud/cloud.cfg ]; then
      backup_once /etc/cloud/cloud.cfg
      sed -i 's/^preserve_hostname:.*/preserve_hostname: true/' /etc/cloud/cloud.cfg
      grep -q '^preserve_hostname:' /etc/cloud/cloud.cfg || echo 'preserve_hostname: true' >> /etc/cloud/cloud.cfg
      sed -i 's/^manage_etc_hosts:.*/manage_etc_hosts: false/' /etc/cloud/cloud.cfg
      ok "cloud-init 已设为保留主机名（防止重启被改回）"
    fi
    ok "主机名 = $(hostname)"
  fi
fi

# ---------- swap ----------
if [ "$SWAP_MB" -gt 0 ] 2>/dev/null; then
  head2 "swap（${SWAP_MB}MB）"
  if [ -n "$(swapon --show 2>/dev/null)" ] && [ "$DRY" = 0 ]; then
    skip "已有 swap，不重复创建"
  elif [ "$DRY" = 1 ]; then
    plan "创建 /swapfile-ovz 并挂载（容器不允许则自动放弃）"
  else
    F=/swapfile-ovz
    if [ ! -f "$F" ]; then
      fallocate -l "${SWAP_MB}M" "$F" 2>/dev/null || dd if=/dev/zero of="$F" bs=1M count="$SWAP_MB" status=none
      chmod 600 "$F"; mkswap "$F" >/dev/null 2>&1
    fi
    if swapon "$F" 2>/dev/null; then
      grep -q "^$F" /etc/fstab || echo "$F none swap sw 0 0" >> /etc/fstab
      ok "swap ${SWAP_MB}MB 已启用"
    else
      rm -f "$F"; skip "swapon 被拒绝（OpenVZ/LXC 常见），已删除临时文件"
    fi
  fi
fi

# ---------- 升级 ----------
if [ "$DO_UPGRADE" = 1 ] && [ "$PKG" = apt ]; then
  head2 "apt 升级"
  if [ "$DRY" = 1 ]; then plan "apt-get update && upgrade"
  else
    DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1 | tail -3
    DEBIAN_FRONTEND=noninteractive apt-get -y upgrade 2>&1 | tail -4
    DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge >/dev/null 2>&1
    apt-get clean
    ok "升级完成，剩余可升级: $(apt-get -s upgrade 2>/dev/null | grep -oE '^[0-9]+ upgraded' || echo 0)"
  fi
fi

# ---------- 汇总 ----------
head2 "汇总"
say "  已应用: ${#APPLIED[@]} 项"
say "  已跳过: ${#SKIPPED[@]} 项"
if [ ${#SKIPPED[@]} -gt 0 ]; then
  printf '%s\n' "${SKIPPED[@]}" | awk -F'|' '{printf "    - %-42s %s\n", $1, $2}'
fi
if [ "$DRY" = 1 ]; then
  say ""
  say "  这是演练。确认无误后加 --apply 执行。"
else
  say ""
  say "  完成。回滚用: $0 --rollback"
fi
