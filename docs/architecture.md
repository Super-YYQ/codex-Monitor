# 架构

## 数据流

```text
Windows Task Scheduler
  ├─ CodexQuotaKeeper.Check：周期、登录与 schedule 原生触发器
  └─ CodexQuotaKeeper.Check.AnchorAlarm：最近窗口到期时间 +1 分钟的一次性触发器
                    │
                    ▼
scripts/runner.ps1（单次运行，无常驻进程）
  ├─ common.ps1：配置、原子 JSON、脱敏、机器身份、可等待的本地锁
  ├─ preflight.ps1：配置与运行环境门禁
  ├─ leader-lease.ps1 / global-backoff.ps1：可选的多机租约与集群退避
  ├─ app-server-client.ps1 / quota-client.ps1：官方 app-server JSON-RPC 与额度快照
  ├─ state-machine.ps1：快照事件、schedule/expiry 决策与持久去重
  ├─ anchor-alarm.ps1：纯 alarm plan + Windows Task Scheduler 适配器
  ├─ auto-anchor.ps1：Claim、执行画像校验、codex exec 与二次验证
  └─ logger.ps1 / github-sync.ps1：本地 JSONL、outbox 与可选远程 history
                    │
                    ▼
runtime/（state schema 3、expiryTrack、claims、logs、lock、machine）
```

## 模块边界

- `state-machine.ps1` 是触发决策的唯一入口。它接收配置、当前快照和持久状态，返回零个或多个
  确定性事件；reset 事件只用于审计，不驱动模型调用。
- `anchor-alarm.ps1` 把“选哪个到期时刻”与“如何注册 Windows 任务”分开。前者是纯函数，后者只维护
  一个稳定任务名；每次成功读取额度或应用配置后重算。
- `auto-anchor.ps1` 只处理副作用协议：合并事件、Claim、执行前重验证、一次模型调用、二次额度验证和
  终态落盘。LOCAL_ONLY 使用本地持久 Claim，多机模式使用远程 CAS Claim。
- `app-server-client.ps1` 统一拥有 transport 错误分类；上层不再重复猜测 DNS/TLS/429/认证错误。

## AutoAnchor 状态机

```text
schedule ─┐
          ├─ collect/coalesce ─ guard ─ Claim ─ lease revalidate ─ exec ─ verify ─ COMPLETED
expiry ───┘                         │                              └─────────────── FAILED/EXPIRED
anchorOnApply ──────────────────────┘
```

- `schedule` 与 `anchorOnExpiry` 可同时启用；同轮多个到期事件只产生一次物理执行。
- schedule 到点时若 primary 正在运行，槽位会被消费但不执行；超过一个轮询周期的迟到槽位同样只消费。
- expiry 只在窗口不运行时触发。同一个 `lastNonEmptyResetsAt` 生成稳定 eventId，重启后的新窗口可再次触发。
- 两个自动触发器均为空时，即使 AutoAnchor 已启用也保持纯查询。

## 可靠性与安全边界

- 429 与认证失败进入集群级退避；DNS/TLS/TIMEOUT/EOF 只进入本机退避，避免单机网络故障冻结集群。
- 一次性闹钟与周期任务竞争时，闹钟 runner 最长等待锁 60 秒，然后重新读取快照；不会按旧状态直接执行。
- history 采用字段白名单和统一脱敏；用户主目录在错误文本中归一化为 `<user>`。
- 安装器对部署根目录宽松 ACL 给出告警。推荐安装到 `$env:LOCALAPPDATA\CodexQuotaKeeper`。
