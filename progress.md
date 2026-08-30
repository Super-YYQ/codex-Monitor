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
3. **步骤3 quota-client.ps1 + mock app-server 测试**（本次 commit）
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

## 下一步
- 步骤4：`scripts/state-machine.ps1`（事件识别 QUOTA_SNAPSHOT_CHANGED/WINDOW_RESET_OBSERVED/WINDOW_DISAPPEARED/
  LIMIT_REACHED/AUTH_ERROR/SCHEMA_UNKNOWN/LEADER_CHANGED + SHA-256 eventId 幂等）+ 测试。
