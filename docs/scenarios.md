# 运行场景

本文只描述当前 schema 3 行为。所有时间均为机器本地时间。

## 1. 默认 MonitorOnly

配置保持 `mode=MonitorOnly`、`autoAnchor.enabled=false`。每轮只读取额度、更新快照并写必要事件；
不会调用模型，也不会创建到期闹钟。

## 2. schedule 对齐工作窗口

配置：`schedule=["08:55","13:55"]`，`anchorOnExpiry=[]`。

| 时间 | primary 快照 | 结果 |
|---|---|---|
| 08:55 | `resetsAt` 为空/已过期 | 生成当天 08:55 的 schedule event，调用一次 |
| 08:56 | 验证得到未来 `resetsAt` | 保存新快照，08:55 event 已处理 |
| 13:55 | primary 仍在运行 | 消费 13:55 槽位，不调用模型 |
| 14:30 | 任务迟到超过一个轮询周期 | 迟到槽位只消费，不补打 |

schedule 是 Windows 原生每日触发器，不依赖周期轮询恰好命中分钟。

## 3. secondary 到期补空档

配置：`schedule=[]`，`anchorOnExpiry=["secondary"]`。

1. 成功读取到 secondary 的未来 `resetsAt`，写入 `expiryTrack`。
2. `.AnchorAlarm` 被设置为该时刻 +1 分钟。
3. 闹钟启动 runner；runner 最多等锁 60 秒，再读取当前快照。
4. 若 secondary 仍有未来 `resetsAt`，记 skip 并把闹钟改指下一次；若已过期或消失，生成 expiry event。
5. Claim 成功后只调用一次，验证成功并更新 `expiryTrack`；同一旧到期点不会再次执行。

首次观测到一个从未有过 `resetsAt` 的缺失窗口时不会凭空猜测到期事件；只有当前响应明确给出该窗口但
`resetsAt` 为空，或 `expiryTrack` 曾记录过有效到期点而窗口后来消失，才可触发。

## 4. schedule 与 expiry 同轮到期

配置：`schedule=["08:55"]`，`anchorOnExpiry=["secondary"]`。两者在同一轮都 due 时，各自保留
eventId 并分别 Claim，最终合并为一次物理执行；history 的 `triggerEventIds` 包含全部原因。

## 5. 显式立即触发

`anchorOnApply=true` 只在安装/应用配置时提出一次显式 force。它不依赖 schedule 或 expiry，也不受
`minimumGapMinutes` 限制，但仍受每日上限、认证、schema、执行画像、Leader 与协调仓库门禁。

## 6. 网络与服务端限制

| 故障 | 当前机器 | 其他机器 |
|---|---|---|
| DNS/TLS/TIMEOUT/EOF | 本轮失败并本机退避 | 不受影响，可继续选举/查询 |
| 429 / usage limit | 本轮 fail-closed | 写集群退避，接管也不能绕过 |
| 认证失败 | 本轮 fail-closed | 写集群退避，直到修复/到期 |
| 未知 schema | 保留旧快照为 stale，不执行模型 | 不伪造窗口状态 |

## 7. 并发与崩溃

- 周期任务持锁时闹钟到达：闹钟等待，拿锁后重新查询；等待超时则安全退出，后续周期会再次协调。
- 执行前进程崩溃并留下 CLAIMED：相同 eventId 永久阻止自动重试，避免不确定结果造成双扣；需人工调查。
- 同一轮 primary 与 secondary 同时到期：两个 Claim、一次执行、一次审计；失败也按一次实际尝试计数。

## 8. 旧配置迁移

包含 `keepaliveIntervalMinutes` 的配置可以加载，但该键被忽略并输出提示。常见迁移：

```jsonc
// 旧："keepaliveIntervalMinutes": 300
// 新：
"anchorOnExpiry": ["primary"]
```

若不希望自动调用模型，保持 `schedule=[]` 与 `anchorOnExpiry=[]`。
