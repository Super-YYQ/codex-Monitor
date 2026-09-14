# Soak 与发布门禁

本 runbook 用于验证无法由纯 mock 单元测试证明的时间、电源、真实账号和多机行为。AutoAnchor 默认关闭；
任何真实模型调用必须由操作者明确开启并记录。

## 1. 自动化前置门禁

```powershell
pwsh codex-quota-keeper/tests/run-all.ps1
powershell.exe -NoProfile -File codex-quota-keeper/tests/run-all.ps1
git diff --check
```

要求：PowerShell 7 与 Windows PowerShell 5.1 相关测试通过；任务计划程序集成测试使用唯一临时任务名，
并在 finally 中清理。若环境策略拒绝注册任务，记录为环境阻塞，不得把它伪装成通过。

## 2. Phase 0：真实额度语义观察

在 `MonitorOnly` 下连续记录至少一次自然窗口变化，禁止启用 AutoAnchor。对 primary/secondary 分别记录：

- 调用前后的 `usedPercent`、`resetsAt`、窗口是否消失；
- 人工使用 Codex 后是否只改变用量，还是改变 `resetsAt`；
- 到期时是立刻生成新窗口、字段变空，还是 bucket 消失。

结论标记为：A（到期后空档，调用才重启）、B（服务端自动滚动）、C（字段/模型与预期不同）。
该观察决定推荐哪些窗口启用 `anchorOnExpiry`，但不得用猜测替代证据。

## 3. 单机 schedule soak

1. 配置两个相隔至少一个测试窗口的 schedule 槽位，保持 `anchorOnExpiry=[]`。
2. 让第一个槽位面对未运行 primary，确认一次执行、一次验证、当天不重复。
3. 让第二个槽位面对运行中的 primary，确认槽位被消费且模型调用数不增加。
4. 让机器错过一个槽位超过 `poll.intervalMinutes`，恢复后确认只消费、不补打。

证据：任务历史、runtime JSONL、state 的 processedEventIds、claim 终态和模型调用审计。

## 4. expiry alarm soak

1. 在清醒机器上配置 `anchorOnExpiry=["secondary"]`，确认 `.AnchorAlarm` 指向
   `secondary.resetsAt + 1 分钟`。
2. 到点后确认 runner 重新读取当前快照；窗口仍运行时不得执行，窗口已到期时只执行一次。
3. 成功后确认闹钟改指新的 `resetsAt + 1 分钟`；关闭配置后确认闹钟被删除。
4. 分别测试锁空闲与主任务持锁场景；后者应等待后重新检查，而不是按旧快照执行。

## 5. 休眠与唤醒

在支持唤醒计时器的物理 Windows 机器上分别测试 `task.wakeToRun=false/true`。记录 BIOS、Windows
电源计划、`powercfg /waketimers`、任务历史与实际唤醒时间。虚拟机或禁用 wake timer 的设备不能证明
唤醒能力；README 只能描述“请求唤醒”，不能承诺硬件一定唤醒。

## 6. 故障注入

| 注入 | 预期 |
|---|---|
| DNS/TLS/TIMEOUT/EOF | READ_FAILED + 本机退避；远程无 global backoff |
| 429 | fail-closed；global backoff 可被另一台机器观察 |
| AUTH_ERROR | 不执行模型；修复登录前持续退避 |
| SCHEMA_UNKNOWN | 旧窗口 stale；不创建虚假 expiry event |
| 执行启动失败 | 退还预留 attempt；没有 invocationId |
| 执行结果不确定 | 保留 attempt 与 claim 终态；绝不自动重试 |

## 7. 双机 soak

两台真实机器绑定同一个专用 Private 仓库，至少覆盖：

- 同一 expiry event 并发抢占只有一个 Claim 获胜；
- Leader 在 Claim 后失去租约，执行前重验证阻止模型调用；
- 单机网络错误不冻结另一台，429/认证错误会冻结两台；
- Leader 关机后按 TTL 接管，旧 CLAIMED 不被新 Leader 自动重试。

## 8. 发布判定

自动化全绿只是必要条件。发布前还需明确记录：Phase 0 结论、真实 schedule/expiry 各一次、休眠唤醒
结果、双机 CAS/接管结果、发布包 secret scan 与可复现哈希。任一项未执行应标记“未验证”，不能写成
“生产就绪”。
