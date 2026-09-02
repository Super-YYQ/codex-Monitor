# Changelog

## Unreleased

### Added
- AutoAnchor 新增**空闲判定触发（场景 1）**：keeper 从未锚定过、第二次轮询记录仍是零用量
  时（默认 60 分钟一轮，约一小时后），判定"Codex 没人用"并自动执行一次 CLI 调用；
  触发 eventId 按天确定性生成（`idle|yyyy-MM-dd`），当日只触发一次。随后进入
  `minimumGapMinutes`（默认 300 = 5 小时）静默期，再次触发等窗口真正滚动。
- AutoAnchor 的 keepalive 语义改为**空闲兜底**：存在首次锚定后，距上次锚定超过
  `keepaliveIntervalMinutes`（默认 `300`，`0` = 关闭）仍未观测到窗口重置时再自触发一次；
  此前"从未锚定即自触发"的行为由空闲判定取代。触发 eventId 按 keepalive 时间槽确定性生成，
  与重置触发共用幂等守卫与每日上限。
- AutoAnchor **单机（LOCAL_ONLY）可用**：未配置协调仓库时跳过远端 CAS Claim 与租约重验证，
  以本地 runner 锁 + `state.processedEventIds` 去重承担 at-most-once；此前单机配置下
  AutoAnchor 会被「无租约/无远端 Claim」fail-closed 拦截，永远无法触发。
- 新增 `codex.autoAnchor.anchorOnApply`（默认 `false`）：设为 `true` 后每次运行
  `install.cmd` / `apply-config.cmd` 都立刻强制执行一次锚定（等不及静默期时
  "现在就来一次"）——不受最小间隔限制、不需要重置，仍受每日上限与 fail-closed
  约束，同一分钟内的重复请求只执行一次（`-ForceAnchor` 增量参数）。
- 新增 `codex.autoAnchor.schedule`（每日定时模式，默认 `[]` = 关闭）：`"HH:mm"` 数组
  （本地时间、24 小时制、必须补零）——每个时间点后的第一次轮询触发一次 CLI，
  纯定时、不判断重置/空闲/兜底场景；eventId 按天+槽位确定性生成
  （`schedule|yyyy-MM-dd|HH:mm`），同一槽位每天最多一次，不受静默期限制
  （仍受每日上限与 fail-closed 约束）。
- **`schedule` 定时模式与周期判断模式互斥**（按需二选一）：配置任意槽位即进入纯定时
  模式——重置/空闲/兜底判断停用、重置事件被忽略；清空 `schedule` 回到周期判断模式。
  `anchorOnApply` 立即触发不属于模式，任何模式下都可用。
- 删除错误的「统一重置（两个窗口同刻续期）」测试组：统一重置在配额协议里没有独立
  信号，表现为普通窗口滚动，由既有窗口重置检测覆盖，无需（也无法）单独识别。

### Changed
- `codex.autoAnchor.minimumGapMinutes` 默认 60 → **300**（5 小时静默期：一次锚定后窗口内
  不再触发，force 除外）；`keepaliveIntervalMinutes` 默认 240 → **300**（一个 5 小时窗口，
  与静默期一致）。
- 计划任务 action 增加 `-WindowStyle Hidden`：定时/安装触发的 runner 运行不再弹出可见
  PowerShell 控制台窗口（原先每次轮询都会闪一个黑色窗口）。
- 修复 status 中 AutoAnchor 恒显 OFF：`status.ps1` 改用 shape-agnostic 访问器
  `Test-AutoAnchorEnabled`（v2 嵌套配置下旧写法 `codex.autoAnchor -eq $true` 恒为 false）。
- status 新增「Anchor backstop」行：显示空闲兜底间隔与上次锚定时间（AutoAnchor 开启时）。
- status 新增「Scheduled anchor」行：显示每日定时槽位列表（AutoAnchor 开启时）。
- runner 的 lastReadAt 改为在 AutoAnchor 钩子之后记录：空闲判定依赖上一次轮询记录来区分
  "第一次观测"与"第二次观测"，首轮不得被误判为已有人观测过。
- runner 的 AutoAnchor 租约判定兼容本地选举：`role=LEADER` 且无远端租约（LOCAL_ONLY）
  同样视为可锚定。配置校验：`keepaliveIntervalMinutes` 非 0 时必须 ≥ `minimumGapMinutes`。
- `github.coordination.enabled` 与 `github.historySync.enabled` 示例默认改为 `false`：
  单机复制配置即可零配置运行；多机需先 `setup-log-repo.ps1` 再开启。
  代码内置默认值（`Get-DefaultConfig`）同步为 `false`（此前代码默认仍为 true）。
- `codex.proxy` 校验放行 `socks5://` / `socks5h://`（是否被 codex 识别取决于其自身 HTTP 栈，
  失败仍回退直连一次；CQK-020）。
- 文档明确：keeper 不指定模型/思考等级（额度读取为 app-server 协议方法；AutoAnchor 沿用
  本机 Codex CLI 默认配置）。
- 新增 `config.example.jsonc` JSONC 模板（支持 `//` 与 `/* */` 注释，每项带中文说明，
  自定义字段注释掉、取消注释即生效；`.json` 后缀下注释会被编辑器标红，故模板用 `.jsonc`）；
  配置加载器支持 JSONC。

### Docs
- 快速开始建议把 `codex-quota-keeper` 复制到固定部署目录（计划任务绑定安装路径、
  runtime 数据与机器身份随目录走，避免与源码更新互相干扰）。
- 明确计划任务触发节奏：锚点 = 注册时刻 +1 分钟、按 `poll.intervalMinutes` 重复、
  AtLogOn 触发器、`StartWhenAvailable` 补跑、`apply-config.cmd` 重锚点、
  安装 probe 不算轮询、首轮 first observation。
- 新增「更新升级」流程说明：合并覆盖部署目录（保留 config.json / runtime / history）、
  重装 `install.cmd` 同名替换不产生多任务、新配置项需手动放开注释。

## 0.9.0-beta (2026-08-30)

MonitorOnly 首个公开 Beta。按《codex-Monitor_仓库审查与开发计划_v1.0》完成
协议兼容、配置语义、Windows 启动器、多机数据一致性与 AutoAnchor 分布式重构。

### Added
- Quota v2 快照模型：buckets（bucketId/windowType）+ 元数据 + rawMetadata，
  官方 schema 契约 fixtures 与契约测试（CQK-001/002）。
- 集群级 Global Backoff（coordination/backoff.json），租约接管无法绕过退避（CQK-008）。
- 不可变 history（history/<date>/<machineId>/...）+ durable outbox + sync-state（CQK-009/010）。
- 专用日志仓库绑定 marker、origin 指纹与业务分支名拒绝（CQK-011）。
- AutoAnchor 分布式 CAS Claim（coordination/events/<eventId>.json）与执行前租约重验证（CQK-013/014）。
- 统一外部命令启动器 Resolve-ExecutableLaunchSpec（exe/ps1/cmd/bat，npm codex.cmd 可用）（CQK-004）。
- GitHub Actions：PS7/PS5.1 测试、契约测试、PSScriptAnalyzer、secret scan（CQK-017/018）。

### Changed
- 配置 schema v2：poll / github.coordination / github.historySync / codex.autoAnchor 嵌套结构；
  v1 平铺键自动迁移（CQK-005）。
- logging.includeMachineLabel 默认 false，false 时本地与远程 history 均不含 machineLabel（CQK-006）。
- Runner 完成阶段自动执行日志保留期清理（CQK-007）。
- EventRecord 统一增加 runId / version / errorKind 字段。
- 协调/历史分支默认名改为 cqk/coordination、cqk/history。

### Security
- 脱敏覆盖 ghp_/gho_/ghu_/ghs_/ghr_/github_pat_ 与 URL userinfo（CQK-012）。

### 升级说明
- 从 0.1.x 升级：config.json 建议按 config.example.jsonc 重写（旧键会自动迁移）；
  runtime/state.json 会自动迁移到 schema 2（旧窗口快照迁入 default bucket）；
  日志仓库需运行一次 scripts/setup-log-repo.ps1 完成绑定。
