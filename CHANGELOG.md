# Changelog

## Unreleased

### Production readiness（2026-09-12，尚未发布）
- 接续 CQK-040 WIP，补齐运行期执行配置门禁；校验失败的重置事件留待下一轮，已存在 Claim 的事件退出待处理队列。
- runtime/local history/outbox 共用执行审计字段与脱敏规则；损坏待发记录不会随成功批次被删除。
- 分离尝试、成功、失败计数和时间；保守迁移旧 count，明确未启动时退还次数，不确定执行保留次数。
- 客户端统一错误类型和 retryable；安装额度探测最多两轮、四次传输尝试，提供中文分级诊断。
- Status 默认离线读取执行配置缓存，`status.cmd -Live` 刷新；校验无效、不可用、过期纳入总体状态。
- 修复 `.cmd` 启动器尾部多余引号，批处理使用 Git 原始 CRLF 字节保证源码和 ZIP 入口一致。
- 修复 Windows PowerShell 5.1 超时只终止 `.cmd` 包装器、遗留 Codex 子进程的问题；共享进程树终止同时覆盖 app-server 和 `codex exec`。
- 新增边界与入口回归；`tests/run-all.ps1 -ExcludeGitPush` 明示跳过本地 Git push 套件，不能替代完整发布验收。
- 发布限制与验证证据见 `docs/production-readiness.md`；未执行真实模型调用、双机 soak、tag 或 Release。

### Added
- **发布打包流程（CQK-035）**：新增 `codex-quota-keeper/tools/build-release.ps1`——从
  `git archive <commit>` 直接构建发布 ZIP（只包含已提交文件，「不打包本机状态」是结构性
  保证；blob 字节与入口时间戳取自 commit，同一 commit 重复构建 SHA256 一致），写入
  GNU `sha256sum` 格式的 SHA256SUMS.txt 并回读自检。内置门禁：工作树脏检查（仅限打包前缀）、
  仓库级 secret scan、禁止条目（runtime/ / history/ / config.json / .env / .pem / .key /
  .pfx / .git/）与必需条目（runner.ps1 / install.cmd / config.example.jsonc / README.md）
  双向检查；`-VerifyOnly` 只校验既有产物。脚本不发布任何东西，`gh release create` 命令仅
  打印供人工执行。runbook 见 `docs/release-engineering.md`（含 CQK-034 只读检查结论与
  Ruleset 建议）。
- 新增 `codex-quota-keeper/tools/build-release.ps1` 的回归测试
  `tests/build-release.test.ps1`（10 组）：在一次性 git 仓库里驱动完整构建，覆盖禁入/
  必需条目门禁、SHA256SUMS 各种真实格式解析、篡改/缺失检测、版本从 commit 读取、
  可复现构建、脏树门禁、本机状态拒载与 secret 门禁联动。
- `docs/release-engineering.md`：GitHub 仓库安全配置现状、main 分支保护 Ruleset
  （`main-protection`，2026-09-09 经用户授权启用并读回核对：禁 force push / 禁删除 +
  5 个真实 required check context、bypass 为空；**实测**该规则同样拦直接
  `git push main`——GH013「5 of 5 required status checks are expected」，本文档早先
  「只拦合并」的说法按实测纠正，日常落 `main` 须走分支 + PR + CI 绿 + 合并；含
  ruleset API 的 payload 坑位与可原样重建的 JSON）、发布 runbook、
  §21 发布前 DoD 对照表。secret scanning 相关设置在 push 前复核时端点返回 404，
  按「读不到即 Unknown、不自行开关」如实标注，未对任何平台配置做额外改动。

### Changed
- AutoAnchor 新增**执行模型与思考等级配置**（`codex.autoAnchor.model` /
  `codex.autoAnchor.reasoningEffort`，默认均为空）：配置后锚定执行的
  `codex exec` 分别透传 `-m <model>` 与 `-c model_reasoning_effort=<effort>`；
  留空则完全不传，沿用本机 `~/.codex/config.toml` 默认（现网行为不变）。
  校验只约束安全形态（模型：字母/数字/`.`/`_`/`-`、1-100 字符；思考等级：小写字母
  开头、小写字母/数字/`-`、1-30 字符）而非语义白名单——合法档位随 CLI/模型演进，
  填错在执行时被 CLI 拒绝并走既有 fail-closed ABORTED 路径。每次锚定的 history
  审计记录新增实际使用的 `model` / `reasoningEffort` 字段（未配置时省略）。
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

### Fixed
- **CI 上的行尾与时间戳宿主依赖**（10 处断言，PS 7 与 WinPS 5.1 表现一致，本地全绿而
  `windows-latest` 全红）：
  - 新增根目录 `.gitattributes`，只把 `codex-quota-keeper/tests/golden/*.txt` 与
    `codex-quota-keeper/.gitignore` 钉成 `text eol=lf`。CI 检出按 `core.autocrlf=true`
    交付 CRLF 副本，而 golden 面板是逐行字节比对（并断言不含 CR）、`.gitignore` 是被
    `(?m)^tools/dist/?$` 锚定匹配——行尾多一个 CR 就双双失败。**刻意不写 `* text=auto`
    也不碰 `.cmd` / `.ps1`**：不顺手归一化既有内容，也不给 `.cmd` 换成 LF。
  - `tests/status-assessment.test.ps1` 里那条 `RUNNER_ERROR` 日志原先手写死 `+08:00`；
    UTC runner 上按本地时间解析就成了 8 小时前的旧判定，越过 130 分钟的时效阈值翻成
    `stale-verdict`（视为已恢复），§10 的升级 finding 随之消失。改为经
    `Write-VerdictLog` + `ConvertTo-IsoString` 带出本机偏移（同文件其余调用一直是这么
    写的），并给该 helper 补上 `-ErrorText` 参数。
- **单机 claim 的对端在建瞬间被误判为「存储不可读」**（`tests/anchor-claim.test.ps1`
  的并发组在 CI 上偶红、本地全绿，PS 7 与 WinPS 5.1 一致——是真竞态不是运行时差异）：
  赢家走 `FileMode.CreateNew` 独占创建后还要写盘，而读侧此前用 `[IO.File]::ReadAllText`
  （按 `FileShare.Read` 打开），恰好在对端持有写句柄时抛 sharing violation；写侧
  `File.Open(path, CreateNew, Write)` 的实际共享模式是 `FileShare.None`（不传参≠`Read`，
  已用跨进程矩阵实测），所以在 create 与 flush 之间**任何**读者都进不来。于是
  `Read-LocalAnchorClaim` 把一个健康的对端 claim 报成 `claim store unreadable; fail closed`。
  修法是让读侧与写侧都能穿过这个窗口，而不是放宽断言：
  - 读侧改 `File.Open(..., Read, FileShare.ReadWrite)`，并把返回值从「`$null` 或抛异常」
    扩成三态 `@{read; empty; record}`（访问失败不再抛出跳出重试循环）；
  - 写侧显式 `FileShare.Read`——`CreateNew` 本身才是互斥步骤（文件已存在必抛，与共享
    模式无关），放开读句柄不削弱互斥，对端只能观察 claim 成形、仍不能写；
  - **空文件是有效 claim 而非坏存储**：重试预算耗尽后，0 字节/全空白记录按
    `event already CLAIMED (by ); no retry` 拒绝（文件存在即已占坑，owner 未知，
    赢家若死在此处也维持拒绝——at-most-once 守卫的正确 fail-closed 形态）；只有
    目录/ACL/卷错误、或有字节但永远解析不出的内容才继续报 `claim store unreadable`。
  新增回归组用跨进程 holder（持有独占创建超过读者全部重试预算）钉死这条路径：回退
  本次修复即复现 `FAIL: locked-but-valid claim is not called a broken store`。
  `docs/scenarios.md` §fail-closed 一览与 `docs/soak-runbook.md` F6 的判据/行号引用同步更新。

### Docs
- `docs/release-engineering.md`（见 Added）。
- 新增 `docs/soak-runbook.md` 双机 soak + 故障注入操作单（§21 发布前 DoD 的实机一项）：
  零额度、零真实仓库的整套夹具——`codex.command` 指向包装 `tests/fixtures/mock-appserver.ps1`
  的 `D:\soak\bin\codex.cmd`、本地裸仓库充当协调/日志仓库、`anchor-args.txt` 作为模型调用
  次数的唯一地面真值；含 4 小时挂机正常路径、F1~F7 七个故障注入（429、传输层故障不误判、
  Git 断网、history push 失败、锚定执行失败、crash claim、租约接管）与判定表/记录区，
  每条判据都标注了它在实机上的落盘位置（`state.json` / `keeper-*.jsonl` /
  `history\events-*.jsonl` / 远端 blob）与 grep 形态。
- `codex-quota-keeper/README.md`「快速开始」补充从 Release 下载与校验 ZIP 的说明；补 `status.ps1`
  参数表（`-Live` / `-Detailed` / `-Language en-US` / `-NoColor` / `-KeeperRoot` / `-ConfigFile`，
  日常入口 `status.cmd` 不转发参数）；`queryTimeoutSeconds` 上限（180 秒）与派生计划任务时限
  （`Get-KeeperTaskExecutionTimeLimit`，CQK-031）文档同步。
- 新增 `docs/scenarios.md` 场景详解页：每个仓库处理场景（首次轮询、空闲判定、窗口重置、
  keepalive、每日定时、立即触发、Leader 租约、集群退避、history 推送、fail-closed 一览）
  配真实格式的模拟数据（state.json / lease.json / backoff.json / history 事件文件 /
  summary / 守卫 reason 文本）与 Mermaid 时序图；两份 README 在对应章节加跳转。
- 快速开始建议把 `codex-quota-keeper` 复制到固定部署目录（计划任务绑定安装路径、
  runtime 数据与机器身份随目录走，避免与源码更新互相干扰）。
- 明确计划任务触发节奏：锚点 = 注册时刻 +1 分钟、按 `poll.intervalMinutes` 重复、
  AtLogOn 触发器、`StartWhenAvailable` 补跑、`apply-config.cmd` 重锚点、
  安装 probe 不算轮询、首轮 first observation。
- 新增「更新升级」流程说明：合并覆盖部署目录（保留 config.json / runtime / history）、
  重装 `install.cmd` 同名替换不产生多任务、新配置项需手动放开注释。
- **计划任务启动器改为 wscript + 生成的 `.vbs`**（`runtime/hidden-launch.vbs`）：
  此前直接执行 `powershell.exe -WindowStyle Hidden`，conhost 仍会在每次计划触发时
  闪现数百毫秒黑框；改为 `wscript.exe` 经 `WScript.Shell.Run(..., 0, False)` 启动后
  窗口从创建起即隐藏，闪窗消除。`anchorOnApply` 强制锚定的即发即忘启动同样改走
  `runtime/hidden-launch-forced-anchor.vbs`。`.vbs` 在每次 install / apply-config
  时幂等重新生成。
- **修复读失败分类：传输层故障不再被误判为 429**。app-server 报错包装文本
  （"failed to fetch codex **rate limits**"）总是包含 "rate limit"，旧的
  `429|usage.?limit|rate.?limit` 正则让每次断网/代理离线都按 429 设 60 分钟退避。
  现在按 `errorKind`（TIMEOUT/EOF）+ 传输层措辞（"error sending request"、
  connection refused/reset 等）识别网络故障，只设 10 分钟 `network` 退避、下一轮
  轮询即恢复；真正的限流（429 / "too many requests" / "usage limit exceeded" /
  "rate limit exceeded"）仍保持 60 分钟 `429` 退避。

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
