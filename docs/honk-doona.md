# Honk + Doona 测试变体

LiBwrt 6.12 NSS 与 ImmortalWrt 6.18 PPE 各有一个 eBPF 变体，把代理从 HomeProxy + sing-box 换成 Honk 0.1.0-beta.6 与内嵌 Doona 0.1.0-rc.6。板级、内核和转发策略与对应原版线相同。

ImmortalWrt 6.18 NSS 曾在 2026-11-22 试制同名变体，实测无法在 256 MB 机型启动 Honk，因此该变体已停止发布，仓库中不再保留对应 Profile 与工作流。该线的原版镜像功能正常。

## 可用状态

| 变体 | 内核 | 256 MB 原厂机型 |
|:---|:---|:---|
| LiBwrt 6.12 NSS （eBPF） | 6.12.116 | 可用 |
| ImmortalWrt 6.18 PPE （eBPF） | 6.18.60 | 可用 |

## 启停与管理

- 出厂默认停止 Honk。先备份配置和原版镜像，通过 LuCI「服务 → Honk 代理」显式启动。
- Doona 在受信任的 LAN 上通过路由器 IP 和 9527 端口访问。LuCI 页面提供跳转入口。首次打开 Doona 时创建管理员。
- 防火墙只允许 `br-lan` 和 loopback 使用该端口。自建受信任的 VLAN 或 LAN 接口时，同步检查 Honk 配置和 `/etc/nftables.d/30-zn-m2-honk.nft`。
- 默认分流为直连。NFQUEUE 默认关闭，Honk 的上游 DNS 与 dnsmasq 分离。`dns.routing.response` 使用 `fallback: accept`：把响应 fallback 指向与请求 fallback 相同的上游会让每个名称返回 SERVFAIL。
- 规则文件为 `/etc/honk/config.dae`，管理员状态在 `/etc/honk/data/`。同线保留配置升级后复核这两个位置。
- `sysupgrade -k` 保留 `/etc/honk/config.dae`。手工改过该文件后，升级会继续沿用旧内容；需要出厂默认值时执行 `cp /rom/etc/honk/config.dae /etc/honk/config.dae` 后重启 Honk。

## Doona 未启用的功能

Doona 的「系统状态」会列出后端声明但不满足前置条件的功能。出厂配置下会出现三类提示，前两类来自配置，第三类是设计行为。

| 提示 | 原因 | 状态 |
|:---|:---|:---|
| 导入、修订历史（需要启动参数） | 修订历史、导入和回滚写进 `<data_dir>/state/honk.db`，需要 `--store db`。自 2026-11-24 起出厂即为 `db`，不再出现该提示。 | 已解决 |
| 无法更新地理数据 | 出厂 `config.dae` 没有 `assets { geodata { ... } }`，两个 `geodata` 资产没有 HTTP(S) 来源，因此无法下载。`geodata` 设置本身还需要一个可写的状态数据库，该条件现已满足。 | 需自建 URL |
| 流程记录只在查看时记录 | `experimental.native_api.record_flows` 默认 `true`，但只在有客户端持有流诊断需求时记录；没有客户端就不保留。 | 设计行为 |

`--store db` 把受管理的 `.dae` 源存进 `<data_dir>/state/honk.db`。出厂即启用，代价与约束：

- `global.data_dir` 与 `--data-dir` 必须一致（本镜像均为 `/etc/honk/data`）。
- 数据库为空时，启动会从 `-c` 导入一次。这一步要求 `native_api.enabled` 与 `config_write` 都为真，并且已经配置凭据——本镜像已满足。
- 导入时会剥离 `native_api`/`clash_api` 里的 `secret:`。本镜像用的是 `password_auth`，不受影响。
- 数据库模式不支持 Clash API；本镜像没有 `clash_api`，不受影响。
- 最多保留 50 个修订、共 16 MiB。`/etc/honk/data` 位于 `/overlay`，出厂余量约 46 MB。
- **数据库一旦有内容，`/etc/honk/config.dae` 就不再是权威来源**：之后对它的改动只在数据库清空后才会重新导入。改配置请走 Doona，或先执行 `honk-core admin reset` 再重启。
- 回退到文件模式：`uci set honk.config.store='file'` 后重启 Honk；数据库文件可以留在原处，honk 会忽略它。


## 验收记录

**LiBwrt 6.12 NSS，2026-11-22，`LiBwrt-2026.11.22.3.1-ZN_M2-NOWIFI-6.12-NSS-ebpf`，6.12.116**

| 项目 | 实测 |
|:---|:---|
| 升级 | `sysupgrade -k` 后 45 秒 SSH 恢复；LAN 保持 `192.168.10.1/24` |
| DNS | 连续 24 秒采样 3 次、每次 5 条 A 记录；路由器直连 223.5.5.5 与 1.1.1.1 均通 |
| Honk 进程 | VmRSS 21.6 MB，VmHWM 34,972 kB 恒定；14–16 线程 |
| BPF 挂载 | `/sys/fs/bpf` 46 个 map，5 个 UDP receive tracing 程序 |
| 管理面 | Doona `192.168.10.1:9527` 从 LAN 可达 |
| 边界 | WAN 侧 22 / 80 / 9527 全部拒绝 |
| 硬件分载 | NSS 固件与 ECM 正常；Honk 停止后转发回到原始路径 |
| 出厂默认 | stopped + disabled，`/etc/rc.d` 无链接 |

**ImmortalWrt 6.18 PPE，2026-11-21，`ImmortalWrt-2026.11.21.2.1-ZN_M2-NOWIFI-6.18-PPE-ebpf`，6.18.60**

| 项目 | 实测 |
|:---|:---|
| 升级 | `sysupgrade -k` 后 62 秒 SSH 恢复；LAN `192.168.10.1/24`，WAN `192.168.1.134/24` |
| DNS | 573 秒内 20 次采样（dnsmasq / 直连 223.5.5.5 / 直连 1.1.1.1）全部成功 |
| Honk 进程 | VmRSS 19.2→20.3 MB，VmHWM 36.1 MB |
| BPF 挂载 | `/sys/fs/bpf` 36 个 map |
| 管理面 | Doona `127.0.0.1:9527` 正常，`dae0@if9 UP` |
| 边界 | WAN 侧 22 / 80 / 9527 全部拒绝 |
| 硬件分载 | PPE `offloaded` 计数持续增长（92→94 / 15 秒），flowtable 覆盖 `lan1 lan2 lan3 wan` |
| 内存余量 | `MemAvailable` 66–107 MB |

## 运行状态自查

Honk 在 Linux 6.12+ 上用 TCX（`bpf_link`）挂载 TC 程序，不创建 `clsact` qdisc，也不安装传统 `tc filter`。镜像里没有 `tc` 命令不影响功能，`tc filter show dev br-lan` 看不到内容属正常。

```sh
bpftool prog list | head
bpftool map list | head
ls /sys/fs/bpf
```

`/sys/fs/bpf` 下的 pin 名（`CONN_STATE_MAP`、`ROUTING_POLICY_ROOT`、`LISTEN_SOCKET_MAP` 等）和客户端 IP 的 DNS 查询出现在 `logread | grep dns_control` 里，说明数据面已接管。

## 已知告警

| 日志 | 原因 | 处理 |
|:---|:---|:---|
| `LAN self-protection coverage could not be confirmed` | 上游的顾问式自检无法证明管理面可达性，出厂 `config.dae` 没有为路由器本机地址添加显式 `direct(must)` 规则，因此必然触发。不拒绝启动，也不改写路由 | 需要从 LAN 访问 9527 或 SSH 时，自行添加本机地址的 `direct(must)` 规则 |
| `kernel UDP trace attach unavailable` | 缺少 `CONFIG_FUNCTION_TRACER` 与 `CONFIG_DYNAMIC_FTRACE` | 自 2026-11-22 起镜像已含这两项，该告警不再出现 |

## 内存占用

LiBwrt 6.12.116，256 MB 原厂机型：

| 状态 | `MemFree` | `MemAvailable` |
|:---|---:|---:|
| Honk 停止（出厂默认） | 63,584 kB | 85,020 kB |
| Honk 运行稳定 | 63,640–73,716 kB | 57,000–65,500 kB |

Honk 占用 22 MB RSS 加 20.1 MB BPF map memlock，两者有重叠：进程通过 mmap 引用 BPF 程序文本（`Mapped` 18.7 MB），这部分既是进程 RSS 也是内核里的程序页。`VmHWM` 在两轮共 18 分钟采样里恒定 34,972 kB，map 数量恒定 46 个，没有增长。

`VmSize` 72 MB 是 Go 运行时的虚拟地址预留，不是物理占用。zram 压缩比 5.1 倍，只占 2.5 MB 物理内存。

## 构建来源

归档实现见 [PR #84](https://github.com/osGex0o0II/ZN-M2-No-WIFI-Builder/pull/84)，该分支已被 [PR #86](https://github.com/osGex0o0II/ZN-M2-No-WIFI-Builder/pull/86) 回退，历史文件仍可从对应提交取回。本版采用固定哈希的官方 ARM64 musl stock-full 资产。镜像中保留许可证与 Doona 声明，对应源码见 [NOTICE.md](../NOTICE.md)。
