# 场景详解（真实模拟数据）

> 本页把 README 里提到的每种仓库处理场景展开：用真实格式的时间、字段和文件内容模拟
> 一台机器（machineId `a1b2c3d4e5f6…`，标签 Home PC）从安装到运行一周的完整时间线。
> 所有 JSON 均为实际会写入 runtime/ 或推送到日志仓库的真实格式（字段与代码一一对应）。

---

## 0. 时间线总览

```mermaid
gantt
    title 一周运行时间线（周期判断模式，poll=60min）
    dateFormat YYYY-MM-DD HH:mm
    axisFormat %d日 %H:%M
    section 周期任务
    计划任务每60分钟拉起runner :milestone, m1, 2026-09-02 09:01, 0m
    安装probe（不保存状态）    :milestone, m2, 2026-09-02 09:00, 0m
    section AutoAnchor
    空闲判定(第2次轮询零用量)  :milestone, m3, 2026-09-02 11:00, 0m
    窗口重置触发               :milestone, m4, 2026-09-02 15:00, 0m
    keepalive兜底(5h无重置)    :milestone, m5, 2026-09-02 20:00, 0m
    section 日常
    静默期（5小时静默+兜底）   :2026-09-02 11:00, 2026-09-02 20:00
```

## 1. 安装与首次轮询（first observation）

双击 `install.cmd`：只读 probe 通过后注册计划任务，锚点 = 安装时刻+1 分钟。
首次正式轮询是 first observation——只写基线快照，不产生事件、不触发锚定。

```mermaid
sequenceDiagram
    participant T as 计划任务
    participant R as runner.ps1
    participant C as codex app-server
    participant S as runtime/state.json
    T->>R: 09:01 拉起（一次性，跑完退出）
    R->>R: 本地互斥锁 + preflight
    R->>C: initialize → account/rateLimits/read
    C-->>R: rateLimits 快照
    R->>S: 写 buckets 基线（无事件）
    R-->>T: exit 0
```

**模拟数据 —— 第一次轮询后 `runtime/state.json`（节选）：**

```json
{
  "schema": 2,
  "role": "LEADER",
  "lastReadAt": "2026-09-02T09:01:03+08:00",
  "buckets": [
    {
      "bucketId": "default",
      "windows": [
        { "windowType": "primary",   "usable": true, "windowDurationMins": 300,   "usedPercent": 0, "resetsAt": 1788050400 },
        { "windowType": "secondary", "usable": true, "windowDurationMins": 10080, "usedPercent": 0, "resetsAt": 1788655200 }
      ]
    }
  ],
  "anchors": { "day": null, "count": 0, "lastAnchorAt": null }
}
```

对应 `status.cmd` 输出（节选）：

```text
Task installed      : YES
Last task run       : 2026-09-02 09:01:03  (Success)
Polling interval    : 60 min
This machine role   : LEADER
Last quota read     : 2026-09-02T09:01:03+08:00
 5h window          : 0% used, reset 2026-09-02 14:00
 7d window          : 0% used, reset 2026-09-09 14:00
Last error          : none
```

## 2. 周期判断模式（schedule 为空，默认）

由 keeper 判断时机，三个触发器按优先级：重置 > 空闲判定 > 空闲兜底。

### 2.1 空闲判定触发（场景 1：从来没启动过 Codex）

前提：从未锚定（`anchors.count=0`）+ 第一次观测只是基线。

```mermaid
sequenceDiagram
    participant T as 计划任务
    participant R as runner.ps1
    participant G as 守卫 Test-ShouldAnchor
    participant X as codex exec
    T->>R: 10:00 第2次轮询（还是零用量）
    T->>R: 11:00 第3次轮询
    R->>G: 有两次记录、从未锚定、primary usedPercent=0
    G-->>R: should=true (triggerKind=idle, eventId=SHA-256("idle|2026-09-02"))
    R->>X: "Reply exactly OK."（空工作目录）
    X-->>R: exit 0
    R->>R: VERIFY 二次读取 → ANCHOR_EXECUTED
    Note over R: 静默期 300 分钟开始
```

| 时间 | 轮询看到 | 守卫判定 | 动作 |
|------|---------|---------|------|
| 09:01 | 0% 用量，重置 14:00 | 第一次观测，只有基线 | 只记录 |
| 10:00 | 0% 用量，重置 14:00 | 从未锚定，但上次记录是 09:01 基线（本次记录还只是第二次观测） | 只记录 |
| 11:00 | 0% 用量，重置 14:00 | 从未锚定 + 第二次观测成立 + 零用量 → **触发** | **CLI 一次** |
| 11:00~16:00 | 用量 0%（CLI 消耗极小） | 静默期内 | 不触发 |
| 16:00 | 重置时间 14:00→19:00（窗口滚动了） | 重置事件优先级最高 | **CLI 一次**（triggerKind=reset） |

### 2.2 窗口重置触发（用完 5 小时额度）

判定条件：`旧 resetsAt 已过期 && 新 resetsAt > 旧 resetsAt`。

```mermaid
sequenceDiagram
    participant C as codex app-server
    participant R as runner.ps1
    participant E as 事件识别 Get-StateEvents
    R->>C: 15:00 轮询
    C-->>R: primary resetsAt: 1788050400(14:00已过) → 1788068400(19:00)
    R->>E: 对比上一轮快照
    E-->>R: WINDOW_RESET_OBSERVED eventId=SHA-256("default|primary|300|...|reset")
    R->>X: codex exec（锚定新窗口）
    R->>H: ANCHOR_EXECUTED → history
```

**模拟数据 —— 每次轮询的快照对比：**

| 轮询时刻 | 5h 窗口 | 7d 窗口 | 事件 |
|---------|---------|---------|------|
| 14:00 | 100% 已用，resetsAt=1788050400（=14:00，未过） | 不变 | 无（"等于"不算过期） |
| 15:00 | 3% 已用，resetsAt=1788068400（19:00） | 不变 | `WINDOW_RESET_OBSERVED` → 锚定 |
| 19:00 | 100% 已用，resetsAt=1788068400（=19:00，未过） | 不变 | 无 |
| 20:00 | 5% 已用，resetsAt=1788086400（24:00） | 不变 | `WINDOW_RESET_OBSERVED` → 锚定 |

### 2.3 空闲兜底触发（keepalive）

前提：已有过至少一次锚定；距上次锚定 ≥ `keepaliveIntervalMinutes`（默认 300）且期间没观测到任何重置。

```mermaid
flowchart LR
    A[上次锚定 15:00] -->|300 分钟无重置| B[20:00 轮询]
    B --> C{"keepalive 槽位已处理?<br/>eventId = SHA-256(keepalive 1788072000)"}
    C -->|否| D[触发 keepalive 锚定]
    C -->|是| E[跳过]
```

**模拟数据：**

| 轮询 | 判定 |
|------|------|
| 16:00~19:00 | 无重置事件；距 15:00 锚定 < 300 分钟 → 静默 |
| 20:00 | 距 15:00 锚定恰好 300 分钟 → **触发 keepalive 锚定** |
| 20:00+ | 下一兜底槽位 = 24:00 之后（5h 边界） |

## 3. 每日定时模式（schedule 非空，与判断互斥）

配置 `codex.autoAnchor.schedule=["09:30","21:00"]` 后，**判断触发器全部停用**：
重置/空闲/兜底不再触发，只有时间点驱动。

```mermaid
sequenceDiagram
    participant T as 计划任务
    participant R as runner.ps1
    participant G as 守卫
    T->>R: 09:00 轮询（槽位 09:30 未到）
    G->>R: 拒绝 - timer mode, no due slot
    T->>R: 10:00 轮询（已过 09:30）
    R->>G: 槽位 09:30 今天没处理过
    G->>R: should=true (triggerKind=schedule)
    R->>X: CLI 一次
    Note over G: 重置事件若同轮到达也被忽略
```

**模拟数据 —— 一天两槽位：**

| 轮询时刻 | 槽位状态 | 动作 |
|---------|---------|------|
| 09:00 | 09:30 未到 | 拒绝（timer mode; no due slot） |
| 10:00 | 09:30 已过，未处理 | **触发** eventId=SHA-256(`schedule|2026-09-02|09:30`) |
| 11:00~20:00 | 09:30 已处理；21:00 未到 | 拒绝 |
| 22:00 | 21:00 已过，未处理 | **触发** |
| 次日 10:00 | 新一天 09:30 未处理 | **再触发**（每天最多一次/槽位） |

## 4. 立即触发（anchorOnApply，任何模式可用）

`anchorOnApply=true` 时，每次 `install.cmd` / `apply-config.cmd` 后 runner 立即带
`-ForceAnchor` 参数运行一次：绕过静默期与模式判断，仍受每日上限约束。

```text
09:30  apply-config.cmd → runner -ForceAnchor
       → guard: force 触发（eventId=SHA-256(force|<当前分钟>)）
       → codex exec → ANCHOR_EXECUTED
09:31  又点了一次 apply-config.cmd
       → guard: forced anchor already executed this minute → 拒绝
10:00  再点 apply-config.cmd（新分钟槽位）
       → 再触发一次（每日上限 6 次内）
```

## 5. 多机互斥（Leader 租约）

两台机器（Home PC `a1b2…`、Laptop `9f8e…`）共用一个 Private 日志仓库。
租约文件 `coordination/lease.json` 在 `cqk/coordination` 分支，Git push 冲突 = CAS。

```mermaid
sequenceDiagram
    participant A as Home PC
    participant G as Private 仓库 (cqk/coordination)
    participant B as Laptop
    A->>G: 09:01 fetch lease.json（空）
    A->>G: push lease{owner=a1b2,expires=09:46} → 成功
    Note over A: LEADER
    B->>G: 09:01 fetch lease.json
    B-->>B: 有活跃租约 owner=a1b2 → PASSIVE
    Note over B: 只写心跳，不碰 Codex
    A->>G: 每轮续租（expiresAt 顺延）
    Note over B: 10:31 Home PC 关机
    B->>G: 10:31 租约已过期（09:46+grace5）→ 接管
    B->>G: push lease{owner=9f8e} → 成功
    Note over B: 新 LEADER
```

**模拟数据 —— `coordination/lease.json`：**

```json
{
  "schema": 1,
  "ownerId": "a1b2c3d4e5f64789a0b1c2d3e4f5a6b7",
  "ownerLabel": null,
  "acquiredAt": "2026-09-02T09:01:01+08:00",
  "expiresAt": "2026-09-02T09:46:01+08:00"
}
```

（`ownerLabel` 默认不写：`logging.includeMachineLabel=false`，隐私默认关闭。）

## 6. 集群级退避（Global Backoff）

一台机器遇到 429 / 认证错误后写入 `coordination/backoff.json`，
**其他机器接管 Leader 也绕不过去**——整个集群一起等。

```mermaid
sequenceDiagram
    participant A as Home PC (LEADER)
    participant G as 仓库 coordination/backoff.json
    participant B as Laptop (新 LEADER)
    A->>A: 10:00 读额度遇 429
    A->>G: push backoff{until=11:00, reason=429}
    A-->>A: 本地 BACKOFF（60 分钟）
    Note over A: 10:00 Home PC 关机
    B->>G: 10:31 接管租约成功
    B->>G: 读 backoff.json → active until 11:00
    B-->>B: GLOBAL_BACKOFF_SKIP（只续租，不碰 Codex）
    Note over B: 11:00 退避过期，恢复查询
```

**模拟数据 —— `coordination/backoff.json`：**

```json
{
  "schema": 1,
  "until": "2026-09-02T11:00:00+08:00",
  "reason": "429",
  "sourceOwnerId": "a1b2c3d4e5f64789a0b1c2d3e4f5a6b7"
}
```

本地日志对应行（`runtime/logs/keeper-2026-09-02.jsonl`）：

```json
{ "ts": "2026-09-02T10:31:02+08:00", "level": "INFO", "event": "GLOBAL_BACKOFF_SKIP", "machineId": "9f8e…", "role": "BACKOFF", "error": "until 2026-09-02T11:00:00+08:00 (429, set by a1b2…)" }
```

## 7. 可审计历史（history 分支）

普通轮询零写入；只有重要事件（重置/锚定/Leader 变更/错误）经 durable outbox
推送到 `cqk/history` 分支，路径按日期+机器隔离，多机并存不覆盖：

```text
history/
  2026-09-02/
    a1b2c3d4…/
      20260902T150001_WINDOW_RESET_OBSERVED_<fileId>.json
      20260902T150004_ANCHOR_EXECUTED_<fileId>.json
    9f8e7d6c…/
      20260902T103101_LEADER_CHANGED_<fileId>.json
  summary/
    2026-09-02/
      a1b2c3d4….json
      9f8e7d6c….json
```

**模拟数据 —— `ANCHOR_EXECUTED` 事件文件（净化白名单字段）：**

```json
{
  "ts": "2026-09-02T15:00:04+08:00",
  "event": "ANCHOR_EXECUTED",
  "machineId": "a1b2c3d4e5f64789a0b1c2d3e4f5a6b7",
  "role": "LEADER",
  "mode": "AutoAnchor",
  "runId": "2026-09-02T15:00:01+08:00",
  "windows": { "5h": { "usedPercent": 3, "resetsAt": 1788068400 } },
  "anchor": {
    "phase": "ANCHORED",
    "trigger": "reset",
    "durationSecs": 12,
    "execExitCode": 0,
    "verified": true
  },
  "version": "0.9.0-beta"
}
```

**模拟数据 —— `summary/2026-09-02/a1b2….json`：**

```json
{
  "type": "daily-summary",
  "date": "2026-09-02",
  "machineId": "a1b2c3d4e5f64789a0b1c2d3e4f5a6b7",
  "counts": { "QUOTA_SNAPSHOT_CHANGED": 4, "WINDOW_RESET_OBSERVED": 2 },
  "anchors": 3,
  "errors": 0,
  "updatedAt": "2026-09-02T22:00:05+08:00"
}
```

## 8. 失败保护（fail-closed 一览）

任何不确定状态都拒绝锚定，宁可不触发也不误触发：

| 情形 | 守卫输出（真实 reason 文本） |
|------|------|
| 当日已锚定 6 次 | `daily anchor cap reached (6/6)` |
| 静默期内 | `minimum anchor gap not elapsed (42 < 300 min)` |
| 轮询读取失败 | `quota read failed this cycle; … fails closed` |
| 429 后本机退避中 | 角色直接 `BACKOFF`，日志 `BACKOFF_SKIP` |
| 集群退避生效 | 角色直接 `BACKOFF`，日志 `GLOBAL_BACKOFF_SKIP` |
| 远程仓库不可达（多机） | `remote coordination unreachable (unreachable); fail closed` |
| 租约丢失 | `lease lost during claim (role=PASSIVE)` |
| 认证错误 | `open error present: AUTH_ERROR` |
| 首次观测就想锚定 | `first observation; idle detection needs two poll records` |

---

**与代码的对应关系**：本页所有 eventId 格式、字段名、路径、reason 文本均摘自
`scripts/state-machine.ps1` / `scripts/leader-lease.ps1` / `scripts/global-backoff.ps1` /
`scripts/github-sync.ps1` / `scripts/logger.ps1` / `scripts/status.ps1`。
数据为演示用模拟值（时间戳、machineId、百分比），不是真实账号数据。
