# 架构

## 数据流

```
Windows Task Scheduler (CodexQuotaKeeper.Check, 仅当前用户)
        |  每 poll.intervalMinutes
        v
  scripts/runner.ps1  (一次性运行, 零常驻)
        |
        |-- common.ps1           配置(v2 schema)/JSON 原子写/脱敏/机器标识/本地互斥/launcher
        |-- preflight.ps1        配置校验 + codex/git/仓库绑定/runtime 可写
        |-- leader-lease.ps1     cqk/coordination 分支租约 (Git push 冲突 = CAS)
        |-- global-backoff.ps1   coordination/backoff.json 集群级退避
        |-- quota-client.ps1     codex app-server JSON-RPC: initialize -> account/rateLimits/read
        |-- state-machine.ps1    bucket/window 快照差异 -> 事件; eventId = SHA-256(bucketId|windowType|duration|prevResetsAt|reset)
        |-- auto-anchor.ps1      实验: 分布式 CAS Claim -> codex exec -> 二次验证 (默认关)
        |-- logger.ps1           runtime JSONL(EventRecord) + history JSONL + 每日 summary + 保留期
        |-- github-sync.ps1      durable outbox -> 不可变 history + summary (Git plumbing, push 拒绝 = CAS)
        v
  runtime/ (gitignored)          state/outbox/logs/lock/machine/sync-state
```

## 关键设计

- **零常驻**：计划任务到点拉起 runner，跑完退出。启用状态看计划任务与 runtime 心跳。
- **单 Leader**：租约 CAS + 全局退避 + 绑定门禁，保证任意时刻最多一个正常查询 Leader。
- **配额模型（v2）**：`rateLimitsByLimitId` 多 bucket 优先，`rateLimits` 兼容为单 bucket；
  白名单解析 primary/secondary 窗口；未知键进 rawMetadata，不参与 reset 判断；
  可选/空字段降级窗口信息；只有完全不可识别才 SCHEMA_UNKNOWN fail-closed。
- **事件键**：`bucketId|windowType`；AutoAnchor eventId 跨机确定。
- **不可变 history**：`history/<date>/<machineId>/<stamp>_<EVENT>_<id>.json`，
  多机并存不覆盖；durable outbox 保证推送失败不丢事件。
- **外部命令**：统一 `Resolve-ExecutableLaunchSpec`（exe/ps1/cmd/bat），npm codex.cmd 可用。

## 状态机

```
DISABLED/PASSIVE/LEADER/DEGRADED/AUTH_ERR/BACKOFF
AutoAnchor(实验): RESET_SEEN -> Claim(CAS) -> LeaseRevalidate -> codex exec -> Verify -> COMPLETED/FAILED/EXPIRED
```
