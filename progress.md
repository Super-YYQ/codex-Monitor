# 进度

## 当前阶段
- 按 task_plan.md 分步实现 `codex-quota-keeper/`（PowerShell 7，PowerShell 5.1 仅入口层兼容）。

## 完成记录
1. `ee5859b` 骨架：README/.gitignore/config.example.json + cmd 入口（status/install/uninstall/apply-config）。
2. `95221cd` **步骤2 common.ps1 + 测试**
   - `scripts/common.ps1`：路径/配置加载与校验（含 5 分钟下限、autoAnchor 需 mode=AutoAnchor）、
     JSON 读写（原子写、JSONL、PS5.1 兼容的深度转 hashtable）、ISO 时间与 epoch、
     SHA-256（eventId 用）、脱敏 Hide-SensitiveText/Sanitize-Record（history 白名单键）、
     runtime/machine.json 随机机器标识、backoff 窗口、双层的本地互斥（named mutex + lock file，含僵尸 PID 破锁）、
     Invoke-External（参数数组化、超时、PS5.1 ArgumentList 回退）、Resolve-CodexCommand。
   - `tests/test-helper.ps1`（断言助手）、`tests/run-all.ps1`（汇总入口，失败退出码 1）、
     `tests/common.test.ps1`：全过（默认保守值、配置下限拒绝、机器 ID 稳定、
     退避过期、脱敏覆盖 token/refresh_token/Bearer/sk-、JSONL、二次加锁被拒、僵尸锁可破、epoch 往返）。
3. `2f1fddd` **步骤3 quota-client.ps1 + mock app-server 测试**
   - `scripts/quota-client.ps1`：`codex app-server` 子进程 JSON-RPC（initialize → initialized →
     `account/rateLimits/read` id=7）；按 `windowDurationMins` 归一化窗口（不假设 primary=5h/secondary=7d）；
     缺失 secondary 合法；未知窗口名原样保留；`rateLimitReachedType` 透传；
     结构不可识别 → `SCHEMA_UNKNOWN` fail-closed；错误分类 AUTH_ERROR/PROTOCOL_ERROR/TIMEOUT/EOF/SETUP_ERR；
     超时 kill 子进程；每次读取新建进程、读完即退（零常驻）。
   - `tests/fixtures/mock-appserver.ps1`：11 种模式 mock（normal/no-secondary/swapped/fractional/
     extra-window/limit-reached/unknown-schema/auth-error/protocol-error/timeout/start-failure），无真实凭证。
   - `tests/quota-client.test.ps1`：13 组全过（连跑两次稳定）。
   - 排障记录：①子进程 stdin 编码必须用 `UTF8Encoding($false)`，`[Encoding]::UTF8` 会写 BOM 破坏 JSON-RPC 首行；
     ②rateLimits 只校验实际存在的键（单窗口合法），`rateLimitReachedType` 是合法非窗口字段。
4. `eabd90e` **步骤4 state-machine.ps1 + 测试**
   - `scripts/state-machine.ps1`：runtime/state.json 读写（New/Load/Save，旧文件缺键自动补默认值，
     processedEventIds 上限 200）；事件识别（03 文档 §7 全部 7 类 + READ_FAILED）——
     QUOTA_SNAPSHOT_CHANGED 每轮最多聚合 1 条、WINDOW_RESET_OBSERVED 判定=旧 resetsAt 已过期且新窗口更新
     且 eventId=SHA-256(`<minutes>|<prevResetsAt>|reset`) 跨机一致、WINDOW_DISAPPEARED 只记录不推断 reset、
     LIMIT_REACHED/AUTH_ERROR/SCHEMA_UNKNOWN/LEADER_CHANGED；
     Test-ShouldAnchor 幂等守卫：mode+autoAnchor 双开关、Leader 租约、未处理 eventId、
     最小间隔、每日上限、无 429/认证/未知 schema 错误、远程不可达 fail-closed。
   - `tests/state-machine.test.ps1`：11 组全过（含 eventId 与文档示例格式一致、守卫 9 种拒绝路径）。
5. **步骤5 logger.ps1 + 测试**（本次 commit）
   - `scripts/logger.ps1`：runtime/logs/keeper-YYYY-MM-DD.jsonl（03 文档 §11 schema：ts/level/event/
     machineId/role/mode/windows/anchor/error，错误文本入库前脱敏）；history/events-*.jsonl 净化白名单记录
     （prompt/会话/凭证字段一律丢弃）；history/summary-YYYY-MM-DD.json 每日滚动汇总（counts 累积/anchor/错误计数/
     最后快照）；Invoke-LogRetention 按 retentionDays 清理本地 runtime/logs 与 history（不动远程 Git 历史）；
     Get-RecentErrors 供 status.ps1 读取最近 ERROR。
   - `tests/logger.test.ps1`：6 组全过（schema 字段存在性、脱敏、history 白名单、汇总累积、保留期、最近错误排序）。
   - 修复 common.ps1 深转换函数单元素数组被 PowerShell unroll 的问题（`return ,$list`），并全量回归通过。


## 下一步
- 步骤6：`scripts/preflight.ps1` + `scripts/leader-lease.ps1`（Git 租约 CAS）+ `scripts/github-sync.ps1` + 测试。
