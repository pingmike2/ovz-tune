# ovz-tune

一键调优 Linux 小鸡的 TCP / 系统参数，**自适应 OpenVZ、LXC/Incus、KVM**，支持 Debian / Ubuntu。

不猜、不硬写：每个参数先读再试写，写不进去就跳过并告诉你原因。所以同一份脚本在容器里不会刷一屏 `Read-only file system`。

![shellcheck](https://github.com/pingmike2/ovz-tune/actions/workflows/shellcheck.yml/badge.svg)
![license](https://img.shields.io/badge/license-MIT-blue)
![platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-red)

## 一键

带菜单，先看清楚再决定：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pingmike2/ovz-tune/main/install.sh)
```

不交互，直接调优：

```bash
curl -fsSL https://raw.githubusercontent.com/pingmike2/ovz-tune/main/install.sh | bash -s -- --apply
```

装上之后随时用：

```bash
ovz-tune              # 菜单
ovz-tune --apply      # 调优
ovz-tune --rollback   # 撤销
```

> 不加 `--apply` 永远只是演练，只打印计划，不改任何东西。

## 它做什么

| 类别 | 内容 |
|---|---|
| 网络栈 | `somaxconn`、`tcp_fastopen`、本地端口范围、`tcp_fin_timeout`、`tw_reuse`、keepalive、`mtu_probing`、`slow_start_after_idle`、`tcp_notsent_lowat` |
| 队列与缓冲区 | `netdev_max_backlog`、`tcp_max_syn_backlog`、`rmem/wmem`（按内存 8M / 16M / 32M 定档，**<512MB 保留内核默认**） |
| 拥塞控制 | 内核支持就上 `bbr` + `fq`，不支持就明确告诉你为什么不行 |
| 路径 MTU | `--mtu auto`：逐个试 1500/1460/1450/1444/1436/1400，比 TLS 握手耗时，只在发现黑洞时改 |
| 连接跟踪 | `nf_conntrack_max` |
| 内存回收 | `swappiness`、`vfs_cache_pressure`、`dirty_ratio`（容器拒绝就跳过） |
| 日志 | journald 限额，按内存 64M / 100M / 200M 定档 |
| 句柄 | `nofile 65535` |
| SSH | keepalive 60s，`sshd -t` 校验通过才 reload；socket 激活模式自动识别 |
| 容器清理 | 清 `ssh@*` / `session-*` 死连接残留；容器里 mask 永远起不来的 `systemd-hostnamed` |
| 其他（可选） | 时区、主机名（含 cloud-init 防回滚）、swap、apt 升级（EOL 系统自动切 archive 源） |

## 各虚拟化能改多少（实测）

| 环境 | 生效 | 跳过 | 说明 |
|---|---|---|---|
| **KVM**（Debian 11, 461MB） | 24 | 0 | 全部可调，含 BBR + fq |
| **LXC**（Debian 11） | 18 | 5 | `net.core.*` 被宿主锁，`net.ipv4.*` 可用 |
| **Incus/LXC + NAT**（Debian 11, 256MB, 限 0.25 核） | 12 | 10 | 连 `net.core.*` 键都不存在；BBR 不可用；qdisc 固定 `noqueue` |
| **OpenVZ**（Debian 12, 1.5GB） | 3 | 4 | 只剩 `somaxconn` / `fastopen` / 端口范围 |

OpenVZ 的 `vm.*` 会返回 `EINVAL`，`swapon` 返回 `Operation not permitted`，`tcp_congestion_control` 这个键根本不存在——**内核是共享的**，这些由宿主决定，不是配置问题。脚本不去硬碰，直接标注。

### 容器 / NAT 小鸡额外做的

- 认出"只有私网地址"的形态，环境里标 `· 私网 NAT`，MTU 由宿主决定时不去改
- 清掉 `ssh@*` 残留（一台 217 天的机器上堆了 **190 个**失败单元，全是扫描器打出来的死连接），但不碰真正的服务失败
- 容器里 `systemd-hostnamed` 必然 `status=225/NETWORK`，顺手 mask，代价是 `hostnamectl` 不可用
- apt 升级走独立 `systemd-run` unit：容器里 SSH 一断，前台 apt 会被 logind 连坐杀掉，dpkg 可能半途而废
- Debian 11 这类已 EOL 的系统，源 404 时自动切 `archive.debian.org`

## 参数

```
--apply                 真正执行（默认是演练）
--dry-run               演练
--tz Asia/Shanghai      顺便设时区
--hostname myvps        顺便改主机名（自动处理 /etc/hosts 和 cloud-init）
--journald-max 200M     指定日志上限
--swap 1024             尝试加 1G swap（容器里会自动放弃）
--mtu auto              实测最优 MTU，只在发现黑洞时才改
--mtu 1400              直接指定 MTU 并开机持久化
--upgrade               顺便 apt 升级（可能重启服务，默认不做）
--rollback              撤销本脚本的改动
```

## 回滚

```bash
ovz-tune --rollback
```

删除脚本生成的 drop-in、清理 `limits.conf` 标记段、重载 sysctl。原文件备份在 `/var/backups/ovz-tune/`。

注意：回滚只撤**持久化配置**，运行中的参数要重启才回到系统默认；主机名 / 时区 / swap 不自动还原。

## 路径 MTU 黑洞（`--mtu auto`）

套壳 / 反代 / WireGuard 中转的机器常见症状：握手 3 秒起步、TLS 卡死，实际是路径 MTU 黑洞（ICMP too-big 被吞）。原理是 A/B 改 MTU 看 TLS 握手时间：

```bash
for m in 1500 1450 1444 1436 1400; do
  ip link set dev eth0 mtu $m
  echo -n "mtu=$m "
  curl -s -o /dev/null -w 'tls=%{time_appconnect}\n' https://www.cloudflare.com
done
```

`--mtu auto` 就是把这段自动化：每个候选值取 3 次采样的中位数，最后只在**基线 > 0.5s 且最优值 < 0.15s** 时才切换（真黑洞是 3 秒级，正常抖动不会触发误判），并写一个 `ovz-tune-mtu.service` 开机持久化。判定为正常时保持原值不动。

```bash
ovz-tune --apply --mtu auto     # 实测并按需采用
ovz-tune --apply --mtu 1400     # 已知答案，直接指定
```

veth 类网卡（宿主控制 MTU）会直接跳过并说明原因。

## 它不做什么

- 不重启 nginx / sing-box / argo 等业务服务；ssh 也只 reload
- 不改 `PermitRootLogin`、不装防火墙、不碰 fail2ban
- 不换内核、不改 `/etc/resolv.conf`
- 不装任何第三方面板或"探长"类工具

## 要求

- Debian 10+ / Ubuntu 18.04+，root 权限
- 需要 `bash`、`iproute2`、`systemd`（无 systemd 的会自动跳过相关步骤）

## License

MIT
