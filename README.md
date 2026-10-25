# ovz-tune

一键调优 Linux 小鸡的 TCP / 系统参数，**自适应 OpenVZ、LXC、KVM**，支持 Debian / Ubuntu。

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
| 网络栈 | `somaxconn`、`tcp_fastopen`、本地端口范围、`tcp_fin_timeout`、`tw_reuse`、keepalive、`mtu_probing`、`slow_start_after_idle` |
| 队列与缓冲区 | `netdev_max_backlog`、`tcp_max_syn_backlog`、`rmem/wmem`（按内存 8M / 16M / 32M 定档） |
| 拥塞控制 | 内核支持就上 `bbr` + `fq`，不支持就明确告诉你为什么不行 |
| 连接跟踪 | `nf_conntrack_max` |
| 内存回收 | `swappiness`、`vfs_cache_pressure`、`dirty_ratio`（容器拒绝就跳过） |
| 日志 | journald 限额，按内存 64M / 100M / 200M 定档 |
| 句柄 | `nofile 65535` |
| SSH | keepalive 60s，`sshd -t` 校验通过才 reload |
| 其他（可选） | 时区、主机名（含 cloud-init 防回滚）、swap、apt 升级 |

## 各虚拟化能改多少（实测）

| 环境 | 生效 | 跳过 | 说明 |
|---|---|---|---|
| **KVM**（Debian 11, 461MB） | 24 | 0 | 全部可调，含 BBR + fq |
| **LXC**（Debian 11） | 18 | 5 | `net.core.*` 被宿主锁，`net.ipv4.*` 可用 |
| **OpenVZ**（Debian 12, 1.5GB） | 3 | 4 | 只剩 `somaxconn` / `fastopen` / 端口范围 |

OpenVZ 的 `vm.*` 会返回 `EINVAL`，`swapon` 返回 `Operation not permitted`，`tcp_congestion_control` 这个键根本不存在——**内核是共享的**，这些由宿主决定，不是配置问题。脚本不去硬碰，直接标注。

## 参数

```
--apply                 真正执行（默认是演练）
--dry-run               演练
--tz Asia/Shanghai      顺便设时区
--hostname myvps        顺便改主机名（自动处理 /etc/hosts 和 cloud-init）
--journald-max 200M     指定日志上限
--swap 1024             尝试加 1G swap（容器里会自动放弃）
--upgrade               顺便 apt 升级（可能重启服务，默认不做）
--rollback              撤销本脚本的改动
```

## 回滚

```bash
ovz-tune --rollback
```

删除脚本生成的 drop-in、清理 `limits.conf` 标记段、重载 sysctl。原文件备份在 `/var/backups/ovz-tune/`。

注意：回滚只撤**持久化配置**，运行中的参数要重启才回到系统默认；主机名 / 时区 / swap 不自动还原。

## 为什么不自动改 MTU

MTU 猜错会直接掉吞吐甚至断连，必须实测。判断方法很简单——A/B 改 MTU，看 TLS 握手时间：

```bash
for m in 1500 1450 1444 1436 1400; do
  ip link set dev eth0 mtu $m
  echo -n "mtu=$m "
  curl -s -o /dev/null -w 'tls=%{time_appconnect}\n' https://www.cloudflare.com
done
```

如果某个值从 `3.15s` 掉到 `0.03s`，那就是路径 MTU 黑洞（ICMP 被吞了），把那个值固定下来即可。

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
