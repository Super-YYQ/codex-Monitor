# 进度

## 当前阶段
- 按 task_plan.md 分步实现 `codex-quota-keeper/`（PowerShell 7，PowerShell 5.1 仅入口层兼容）。

## 完成记录
1. `0974d8b` 骨架：README/.gitignore/config.example.json + cmd 入口（status/install/uninstall/apply-config）。
2. `ccc02a3` **步骤2 common.ps1 + 测试**
   - `scripts/common.ps1`：路径/配置加载与校验（含 5 分钟下限、autoAnchor 需 mode=AutoAnchor）、
     JSON 读写（原子写、JSONL、PS5.1 兼容的深度转 hashtable）、ISO 时间与 epoch、
     SHA-256（eventId 用）、脱敏 Hide-SensitiveText/Sanitize-Record（history 白名单键）、
     runtime/machine.json 随机机器标识、backoff 窗口、双层的本地互斥（named mutex + lock file，含僵尸 PID 破锁）、
     Invoke-External（参数数组化、超时、PS5.1 ArgumentList 回退）、Resolve-CodexCommand。
   - `tests/test-helper.ps1`（断言助手）、`tests/run-all.ps1`（汇总入口，失败退出码 1）、
     `tests/common.test.ps1`：全过（默认保守值、配置下限拒绝、机器 ID 稳定、
     退避过期、脱敏覆盖 token/refresh_token/Bearer/sk-、JSONL、二次加锁被拒、僵尸锁可破、epoch 往返）。
3. `1daa971` **步骤3 quota-client.ps1 + mock app-server 测试**
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
4. `a554138` **步骤4 state-machine.ps1 + 测试**
   - `scripts/state-machine.ps1`：runtime/state.json 读写（New/Load/Save，旧文件缺键自动补默认值，
     processedEventIds 上限 200）；事件识别（03 文档 §7 全部 7 类 + READ_FAILED）——
     QUOTA_SNAPSHOT_CHANGED 每轮最多聚合 1 条、WINDOW_RESET_OBSERVED 判定=旧 resetsAt 已过期且新窗口更新
     且 eventId=SHA-256(`<minutes>|<prevResetsAt>|reset`) 跨机一致、WINDOW_DISAPPEARED 只记录不推断 reset、
     LIMIT_REACHED/AUTH_ERROR/SCHEMA_UNKNOWN/LEADER_CHANGED；
     Test-ShouldAnchor 幂等守卫：mode+autoAnchor 双开关、Leader 租约、未处理 eventId、
     最小间隔、每日上限、无 429/认证/未知 schema 错误、远程不可达 fail-closed。
   - `tests/state-machine.test.ps1`：11 组全过（含 eventId 与文档示例格式一致、守卫 9 种拒绝路径）。
5. `4b2a71b` **步骤5 logger.ps1 + 测试**
   - `scripts/logger.ps1`：runtime/logs/keeper-YYYY-MM-DD.jsonl（03 文档 §11 schema：ts/level/event/
     machineId/role/mode/windows/anchor/error，错误文本入库前脱敏）；history/events-*.jsonl 净化白名单记录
     （prompt/会话/凭证字段一律丢弃）；history/summary-YYYY-MM-DD.json 每日滚动汇总（counts 累积/anchor/错误计数/
     最后快照）；Invoke-LogRetention 按 retentionDays 清理本地 runtime/logs 与 history（不动远程 Git 历史）；
     Get-RecentErrors 供 status.ps1 读取最近 ERROR。
   - `tests/logger.test.ps1`：6 组全过（schema 字段存在性、脱敏、history 白名单、汇总累积、保留期、最近错误排序）。
   - 修复 common.ps1 深转换函数单元素数组被 PowerShell unroll 的问题（`return ,$list`），并全量回归通过。
6. `a5dd80d` **步骤6 preflight + leader-lease + github-sync + 测试**
   - `scripts/github-sync.ps1`：git plumbing（临时 GIT_INDEX_FILE + hash-object/update-index/commit-tree/push）
     实现 CAS 推送，完全不触碰日志仓库的检出工作区；push 被拒（non-FF）= 抢占失败；
     repoPath 白名单（必须与 keeper 项目目录互不嵌套、必须是 git 仓库）；stderr 脱敏；
     Sync-HistoryToGitHub 推送净化事件文件，失败绝不影响主流程。
   - `scripts/leader-lease.ps1`：coordination 分支 lease.json 读写；TTL+grace 判活；
     Invoke-LeaderElection 完整实现文档 §10 伪代码（抢租约/续租/被动让位/过期接管/takeoverOnExpiry 开关/
     push 竞争失败转 PASSIVE）；远程不可达 → DEGRADED（fail-closed，绝不自称 Leader）；github 关闭 → LocalOnly。
   - `scripts/preflight.ps1`：配置校验、codex 可执行解析、git 可用性、repoPath 白名单、runtime 可写、
     机器标识生成；可选 -ProbeCodex 只读额度探测（安装器用）。
   - `scripts/common.ps1`：Invoke-External 支持 -Environment；新增 ConvertTo-IsoString
     （PS7 ConvertFrom-Json 会把 ISO 字符串转 DateTime，直接 [string] 化会变本地化格式）。
   - tests：github-sync（白名单/根提交推送/stale-parent 被拒/missing branch/端到端同步/失败隔离）、
     leader-lease（判活 grace/获取/让位/续租保 acquiredAt/过期接管/禁止接管/CAS 竞争唯一赢家/不可达降级/local-only）、
     preflight（happy/probe 成功/probe 失败/缺 codex/坏配置/坏仓库）。
   - 修复 tests/run-all.ps1：改为每个测试文件独立 pwsh 子进程运行（原方案子 scope 计数器不互通）；
     7 个测试文件全过。
7. `a10a4e2` **步骤7 runner.ps1 主流程 + 端到端测试**
   - `scripts/runner.ps1`：完整实现文档 03 §5 主流程——LoadConfig → 双层本地互斥（被占则 SKIP 退出 0）→
     preflight（失败 exit 1）→ 退避检查（BACKOFF_SKIP）→ Leader 选举（PASSIVE 只写心跳不碰 Codex）→
     只读额度轮询 → 事件识别 → LEADER_CHANGED → AutoAnchor 钩子（auto-anchor.ps1 存在才启用）→
     重置事件 eventId 标记 processed → state/心跳持久化 → 运行日志 + 净化 history + 每日 summary →
     续租 → history 分支同步（commit message 按文档规范 quota: reset observed / keeper: leader changed /
     quota: daily summary）。错误处理按文档 03 §14：429 → 60 分钟退避、认证错误 → 120 分钟退避、
     读取失败保留旧窗口并标记 stale、异常 exit 2。
   - 设计取舍：GitHub 不可达时角色为 DEGRADED（按文档 02 §11 状态机定义，本地查询继续、
     绝不自称 Leader、AutoAnchor 由守卫拦截），比直接 PASSIVE 保留本地监控价值。
   - mock 增加 rate-limit（429）与 reset（窗口重置）模式。
   - `tests/runner.test.ps1`：10 组端到端全过（首轮 LEADER 基线、无变化静默、重置检测+eventId 落地+远程同步、
     PASSIVE 不查询、429 退避跳过、认证 2h 退避、失败保留旧数据、坏配置 exit 1、并发锁 SKIP、
     local-only 不碰远程协调分支）。
   - 排障记录：`pwsh -File` 对未声明的命名参数不报错而是塞进 $args——runner 参数统一命名 -ConfigFile。
8. `15af5e1` **步骤8 auto-anchor.ps1（实验，默认关）+ 测试**
   - `scripts/auto-anchor.ps1`：Test-AnchorPromptAllowed 白名单（≤120 字符、无 shell 元字符、
     参数数组传递、绝不接受远程下发）；Get-RemoteProcessedEventIds/Add-RemoteProcessedEventIds
     实现 coordination 分支 processed-events.jsonl 第二层 event lock（文档 02 §8）；
     Invoke-AutoAnchorIfNeeded 完整守卫链：本地幂等守卫 → 远程查重（不可达 fail-closed）→
     prompt 白名单 → codex exec（空工作目录 runtime/anchor-work）→ 二次读取验证 →
     ANCHORED / ABORTED（验证失败不重试模型）→ before/after 快照写入 history（prompt 文本永不落盘）。
   - 守卫拒绝（未执行任何调用）记 ANCHOR_SKIPPED；进入执行后失败才记 ANCHOR_ABORTED。
   - runner 集成：anchor 事件进入 history 同步，commit message `quota: anchor executed`。
   - **修复 Push-RepoBlobs 关键缺陷**：原实现每次提交从空树构建，会抹掉分支上已有文件
     （租约续期会清掉 processed-events 标记、history 分支会丢历史文件）；
     现改为 `read-tree <parent>` 保留原树仅覆盖指定路径，并全量回归验证。
   - `tests/auto-anchor.test.ps1`：8 组全过——默认双开关不执行、完整流程（重置→exec→验证→ANCHORED）、
     同事件只执行一次、第二台机器被远程 marker 拦截、exec 失败 ABORTED、验证失败 ABORTED 不重试、
     每日上限端到端。
   - 测试基建：mock 增加 exec 子命令（CQK_MOCK_EXEC）与读取倒计时（验证失败场景）；
     多机器场景共用 origin 时需先过期租约/清空 marker。
9. `e37526c` **步骤9 install/uninstall/apply-config/status/status-json + 测试**
   - `scripts/install.ps1`：环境校验（PS 版本/git/codex/repo 白名单）→ 只读 quota probe →
     机器标识 → 注册当前用户 Scheduled Task（codex-quota-keeper.Check，Interactive+Limited 无需管理员，
     MultipleInstances=IgnoreNew、StartWhenAvailable 允许休眠唤醒后补跑、AllowStartIfOnBatteries）；
     New-KeeperTaskParameters 纯构建可测。RepetitionDuration 用 3650 天（TimeSpan.MaxValue 在 Win11
     生成越界 XML 被拒）。
   - `scripts/apply-config.ps1`：校验并重注册任务更新轮询间隔；低于 5 分钟下限被拒绝。
   - `scripts/uninstall.ps1`：删除任务；本地 history 默认保留，-DeleteHistory 才删除（文档 04 §9）。
   - `scripts/status.ps1` / `status-json.ps1`：只读状态采集（任务安装/启用/上次结果/下次运行、
     轮询间隔与配置一致性、codex 可用性、可选 -Live 只读认证探测、本机 runner 进程、
     Leader/租约视图、最后额度快照（STALE 标记）、最近错误、日志仓库可达性、AutoAnchor OFF/EXPERIMENTAL
     醒目标识、local-only 模式 MULTI-PC UNSAFE 警告），文本输出对齐文档 02 §4 样例。
   - `tests/install-status.test.ps1`：7 组全过（任务参数构建、真实注册/30 分钟改期/下限拒绝/
     status 文本与 JSON 输出/卸载保留或删除历史）。
   - 修复：`New-ScheduledTaskSettingsSet` 参数名（AllowStartIfOnBatteries/DontStopIfGoingOnBatteries）；
     dot-source 带 param 的脚本会覆盖调用方同名变量（status-json/apply-config 采集后引用）。
10. **步骤10 全量核对 + 收尾**（本次 commit）
    - 全量测试：`pwsh tests/run-all.ps1` 10 个测试文件全部通过（common / quota-client / state-machine /
      logger / github-sync / leader-lease / preflight / runner / auto-anchor / install-status）。
    - 交付物核对（对齐 docs/design/03 §2 目录）：scripts/ 14 个脚本齐备（含 common/status-json 两个实现期补充），
      tests/ 10 个测试文件 + mock fixture + run-all 入口，4 个 .cmd 入口与 config.example.json 就位；
      config.example.json 补齐文档 02 §6 的 task 段。
    - 敏感信息扫描：仓库无 token/密钥；auth.json 仅在注释与文档中以禁止性说明出现；
      脱敏由测试断言保障（token/refresh_token/Bearer/sk- 均被清除）。
    - 验收标准逐条核对（docs/design/04 §9）：零常驻（runner 单次运行退出）、status 只读秒级返回、
      租约 CAS 保证单 Leader、MonitorOnly 默认且无模型调用路径、429/认证退避、
      history 仅净化数据、TTL 接管、卸载删任务/历史可选——均有对应实现与测试。
    - task_plan.md / findings.md 更新为完成状态，并记录实现期踩坑清单。







## 第二轮：仓库审查整改（依据 docs/design/codex-Monitor_仓库审查与开发计划_v1.0.docx，基线 bb8151a）

### 完成记录
R1. `440e87f` **CQK-001/002 quota v2 解析器重构 + 官方 schema 契约 fixtures**
    - QuotaSnapshot 模型：buckets[]（bucketId/bucketName/planType/windows[]）+ sourceSchemaVersion +
      accountPlanType + rateLimitReachedType/credits/spendControlReached + rawMetadata。
    - 解析改为白名单制：仅 primary/secondary 视为窗口键；未知键进入 rawMetadata（仅原始类型），
      不再遍历所有键当窗口；rateLimitsByLimitId 多 bucket 优先，rateLimits 兼容为单 bucket。
    - 可选/空字段降级窗口信息而不判失败（windowDurationMins/resetsAt 允许 null）；
      仅根层级无法识别、或无任何可用窗口且无任何已知元数据时才 SCHEMA_UNKNOWN fail-closed。
    - tests/fixtures/schema/ 7 个官方契约 fixture（current-v2/secondary-null/null-window-fields/
      multi-bucket/credits/unknown-metadata/unrecognized-root）全部通过；
      mock app-server 升级 v2 形状并新增 multi-bucket/secondary-null/null-fields/credits/
      unknown-meta/unrecognized-root 模式；保留 windows 扁平视图供消费者过渡使用。

R2. `1f7dc9a` **CQK-003 状态机升级 bucket/window 模型**
    - 窗口唯一键 = bucketId|windowType（Get-WindowKey/Get-BucketWindowMap），多 bucket 同名窗口互不覆盖。
    - eventId v2 = SHA-256(bucketId|windowType|windowDuration|previousResetsAt|reset)，跨机确定。
    - null 字段容错：resetsAt/usedPercent/duration 任一为 null 时跳过对应比较与 reset 推断，保留 partial 状态。
    - state.json schema=2（buckets 模型）；schema-1 旧 windows 迁移到 default bucket，避免升级后误报 appeared。
    - 新增配置访问器（Get-AutoAnchorConfig/Get-CoordinationConfig/Get-HistorySyncConfig/Get-PollConfig/
      Get-LoggingConfig），v1 平铺与 v2 嵌套配置形状均可用，为 CQK-005 配置重构铺路。
    - runner/status/auto-anchor 消费者切换到 buckets；status 显示 bucket 上下文并跳过不可用窗口。
    - 又一次函数返回单元素数组被 unroll（ConvertTo-StateBuckets 漏加逗号）——已在函数注释中标注此约束。
    - 全量 10 个测试文件回归通过。

R3. `2c12c39` **CQK-005/006/007 配置语义重构 + 行为验收**
    - 配置 v2 schema（§6.1）：poll{intervalMinutes,minimumIntervalMinutes}、
      github{coordination{enabled,repoPath,branch},historySync{enabled,push,branch,eventsOnly}}、
      codex.autoAnchor{enabled,prompt,maxPerDay,minimumGapMinutes}、logging.includeMachineLabel 默认 false。
    - Convert-LegacyConfig：v1 平铺键自动映射到 v2（含测试），v2 键优先，schemaVersion 升 2。
    - 全部脚本改用形状无关访问器（Get-CoordinationConfig/Get-HistorySyncConfig/Get-PollConfig/
      Get-LoggingConfig/Get-AutoAnchorConfig）。
    - 行为兑现（§6.2，均有测试）：historySync.push=false 阻断一切 history push（coordination 独立）；
      includeMachineLabel=false 时本地/远程 history 无 machineLabel（默认关闭）；eventsOnly 普通轮询零远程写入；
      retentionDays 由 Runner 完成阶段自动执行（CQK-007，失败仅记录）；coordination.enabled=false → LOCAL_ONLY。
    - EventRecord（§12）：runId/version/errorKind 字段入运行日志与 history 记录。
    - 协调/历史分支默认名改 cqk/coordination、cqk/history（为 CQK-011 分支防护铺路）。
    - 修复 runner 的 AutoAnchor 门控仍比较旧布尔键的问题。
    - 全量 10 个测试文件回归通过。

R4. **CQK-004 统一外部命令启动器**（本次 commit）
    - Resolve-ExecutableLaunchSpec：.exe 直接运行；.ps1 经 pwsh/powershell -NoProfile；.cmd/.bat 经
      %ComSpec% /d /s /c；裸命令名走 PATH 解析后按扩展名递归。quota-client、auto-anchor、mock 全部走它。
    - cmd/bat 采用原始参数串 `/d /s /c ""exe" "args""`（/s 剥外层引号）——.NET ArgumentList 的
      \" 转义与 cmd 引号规则不兼容，会损坏命令行（实测踩坑）；Invoke-External 增加 -RawArguments。
    - npm codex.cmd 端到端测试通过（mock-appserver.cmd 包装器，PS7 下验证）。
    - 全量 10 个测试文件回归通过。

R5. **CQK-008 Global Backoff**（本次 commit）
    - 新增 scripts/global-backoff.ps1：coordination/backoff.json {schema, until, reason, sourceOwnerId, setAt}，
      Get-GlobalBackoff/Set-GlobalBackoff（CAS push，best-effort 失败不影响主流程）。
    - Runner：Leader 选举后、额度读取前检查全局退避——生效时 Leader 只续租不访问 Codex（GLOBAL_BACKOFF_SKIP）；
      429 → 全局 60 分钟、AUTH_ERROR → 全局 120 分钟（与本地退避同时设置）。
    - tests/global-backoff.test.ps1：6 组全过——marker 推读、过期失活、Leader 跳读、
      租约接管后不得绕过退避（第二台机器接管后仍被全局退避拦截、零查询）、退避期租约续持、
      清除后恢复正常、coordination 关闭时惰性。
    - 全量 11 个测试文件回归通过。

R5b. runner.test.ps1 适配集群退避：429/auth 场景后推送过期记录清除全局退避；
     429 段断言改为 GLOBAL_BACKOFF_SKIP 并验证接管不绕过。全量 11 文件回归通过。

R6. **CQK-009/010 不可变 history + durable outbox**（本次 commit）
    - 新增 Write-OutboxEvent：重大事件先落 runtime/outbox/<id>.json（reset 用确定性 eventId，
      其他事件用 时间戳+runId+随机后缀），任何 push 尝试之前持久化。
    - 新增 Sync-OutboxToGitHub：扫描 pending outbox → 推送为不可变远程布局
      history/<date>/<machineId>/<stamp>_<EVENT>_<id>.json + summary/<date>/<machineId>.json；
      路径按机器隔离，Leader 切换绝不覆盖他机审计数据（CQK-009）。
    - push 成功后才写 runtime/sync-state.json（sent 台账，保留最近 100 条）并清空 outbox；
      CAS 冲突/网络失败/凭证失败均保留 pending 下轮重试（CQK-010）。
    - auto-anchor 事件也走 outbox；runner 的同步阶段替换为 outbox 驱动；
      Sync-HistoryToGitHub 保留用于旧流程兼容。
    - 测试：远端不可变路径格式断言、push=false 时 outbox 保留 pending、
      修复配置后下一轮自动排空 outbox 并写 sync-state（故障注入重试闭环）。
    - 全量 11 个测试文件回归通过。

R7. **CQK-011/012 专用仓库绑定 + 脱敏加固**（本次 commit）
    - Initialize-LogRepo（scripts/setup-log-repo.ps1）：向日志仓库写入 marker
      .codex-quota-keeper-repository.json（repoId/createdFor/allowedBranches），并在 runtime/log-repo.json
      记录 repoId + origin 指纹（URL 去 userinfo 后 SHA-256）；幂等——重复初始化保留 repoId。
    - Test-LogRepoBinding 推送门禁：未初始化/repoPath 不匹配/marker 缺失/repoId 篡改/origin 变更/
      分支不在 allowedBranches 一律 fail-closed；main/master/develop/release/trunk/dev 等业务分支名
      即使写入 marker 也强制拒绝。marker blob 随每次 push 携带（远程自描述）。
    - 四个推送路径（租约续期、全局退避、outbox 同步、anchor 事件标记）全部过绑定门禁。
    - CQK-012：Hide-SensitiveText 新增 ghp_/gho_/ghu_/ghs_/ghr_/github_pat_ 系列与 URL userinfo 脱敏；
      Invoke-Git stderr 自动脱敏。
    - 测试：绑定防篡改/幂等/业务分支拒绝/marker 缺失/未初始化拒绝 + token 脱敏断言；
      全量 11 个测试文件回归通过。

R8. **CQK-013/014 AutoAnchor 分布式 Claim 重构**（本次 commit）
    - 新协调数据：coordination/events/<eventId>.json {state: CLAIMED|COMPLETED|FAILED|EXPIRED,
      ownerId, claimedAt, claimExpiresAt, completedAt, result}，替代旧的 processed-events 事后标记。
    - Claim-AnchorEvent：事件文件不存在时 CAS push 创建 CLAIMED；push 被拒 = 他机抢占；任何已存在
      事件文件（CLAIMED/COMPLETED/FAILED/EXPIRED）一律阻止执行——不确定结果永不重试，宁可漏一次。
    - CQK-014 Test-LeaseRevalidation：Claim 成功后、模型调用前重新确认租约仍属本机且剩余时间
      覆盖安全执行窗口；不满足 → 事件标记 EXPIRED 且绝不调用模型。
    - 执行后 COMPLETED/FAILED；COMPLETED push 失败留在 CLAIMED，同样阻止他机重试。
    - 移除 Get/Add-RemoteProcessedEventIds；processedEventIds 仅本地去重（§13）。
    - Push-RepoBlobs 支持 -RemovePaths（测试清理用）且空 Blobs + RemovePaths 不再提前返回。
    - 全量 11 个测试文件回归通过。

R9. **CQK-015/016 并发与故障注入测试**（本次 commit）
    - 新增 tests/concurrency.test.ps1（两台模拟机器 + 一个 bare origin）：
      双机抢租约唯一赢家；双机并发 Claim 同一 reset 仅一个 CLAIMED 且赢家=租约持有者；
      Claim 后租约易手 → 重验证失败 → 事件标 EXPIRED → 全机禁执行（at-most-once）；
      exec 成功但 COMPLETED push 失败（marker 篡改注入）→ 事件留 CLAIMED → 他机拒绝重试；
      history 推送竞争：两台机器的不可变事件文件并存且各自 outbox 排空。
    - 全量 12 个测试文件回归通过。

R10. **CQK-017/018/019 工程化 + 版本 0.9.0-beta**（本次 commit）
     - .github/workflows/test-windows.yml：pwsh-tests（PS7 全量）、ps51-tests（Windows PowerShell 5.1
       全量）、contract-tests（官方 schema fixtures）；security.yml：PSScriptAnalyzer（Error 阻断）+
       自定义 secret scan（sk-/ghp_/gho_/ghu_/ghs_/ghr_/github_pat_/私钥/明文口令模式）。
     - PSScriptAnalyzerSettings.psd1（豁免控制台输出等用例）。
     - 根 README（一句话定位/快速开始/多机/AutoAnchor 风险/支持矩阵/Troubleshooting）、
       LICENSE（MIT）、SECURITY.md、CHANGELOG.md（0.9.0-beta + 升级说明）、
       docs/architecture.md、docs/operations.md、docs/security-model.md。
     - 版本升至 0.9.0-beta；codex-quota-keeper/README 配置表对齐 v2 schema。
     - 本机双运行时验证：PS7 与 PS5.1 下 12 个测试文件全部通过。
     - CQK-020（双机 soak test 数天运行）属部署验收，需真实两机环境，交付时由部署方执行。

---

## 第三轮：设计文档 v2.0（CQK-021~035，基线 c7260f7c）

R11. `532f063` **CQK-021 默认 lease TTL 与 poll 周期关系校验**（本次 commit）
    - 默认 `leader.leaseTtlMinutes` 45→180（poll=60 的 3 倍）。
    - Test-ConfigShape 新增关系校验：`leaseTtlMinutes >= max(2*poll, poll+grace+CQK_SCHEDULING_JITTER_MINUTES=5)`，
      违反即拒绝（消除“租约在一轮轮询之间过期 → Leader 双机 flapping”）。
    - schedulingJitter 取内部常量而非配置键（与关系校验精神一致、避免 schema 变动）。
    - 同步：config.example.jsonc、两级 README 配置表；测试：common.test.ps1 边界组
      （2*poll 边界、poll+grace+jitter 边界、grace 抬高要求）、install-status New-Cfg 3x 裕量、
      legacy fixture 45→90。全量 12 文件 PS7 通过。

R12. `91b0106` **CQK-022 计划任务持久化自定义 -ConfigFile**（本次 commit）
    - 缺陷：仅 -ForceAnchor 路径向 runner.ps1 传 -ConfigFile，正常定时任务的命令行不带参数，
      runner 静默回退 `<KeeperRoot>\config.json` —— 自定义配置只在安装那一刻生效。
    - Get-KeeperHiddenLauncherSpec 正常路径也写 `-KeeperRoot "<abs>" -ConfigFile "<abs>"`
      （空值解析为 Get-ConfigPath 默认并 GetFullPath）；
      Register-KeeperTask / New-KeeperTaskParameters / Invoke-KeeperInstall / apply-config
      重注册全链路贯通 ConfigFile（参数均默认 ''，旧调用签名兼容）。
    - 测试：install-status 工作区改用非默认 `custom-config.json`（默认回退文件不存在，
      丢参即断言失败）；新增 VBS 内容断言（-ConfigFile、精确路径、-KeeperRoot、
      定时 vbs 不含 -ForceAnchor）、安装后端到端读 vbs 验证、apply-config 重注册后仍保持、
      强制锚定 vbs 同样带自定义路径。全量 12 文件 PS7 通过 + install-status 单文件 PS5.1 通过。

R13. `91d1dc1` **CQK-024 Backoff 期间继续 coordination maintenance**
    - 原则修正：退避 = 「禁止 Codex 访问」，不是「Runner 直接退出」。原实现在 local backoff
      分支只写 heartbeat 就 exit，既不重试 marker 也不续租——租约会在退避中途过期，
      对端接管后立刻开始轮询，正好绕过本机刚受到的 429 惩罚。
    - 新增 durable 队列 `runtime/pending-global-backoff.json`（common.ps1 三件套
      Get/Set/Clear-PendingGlobalBackoff）：远程写失败且原因可自愈时落盘，绝不错过静默丢弃。
    - global-backoff.ps1 重构出 `Resolve-GlobalBackoffWrite`（fetch→单调 deadline 判定→CAS push）
      供即时写与每轮重试共用；`Set-GlobalBackoff` 失败按 `$CQK_BACKOFF_RETRYABLE` 分类入队，
      `binding:*`（需人工）与 `push-rejected`（对端已写）不入队；
      新增 `Sync-PendingGlobalBackoff` 每轮入口，保留**原始绝对 until**（重试不得延长惩罚）、
      窗口已过直接丢弃、coordination 关闭直接丢弃、队列只保留更长 deadline。
    - runner.ps1：maintenance 提到 backoff 分支**之前**，因此 BACKOFF / LEADER / PASSIVE /
      DEGRADED 每条路径都会重试（无队列时零远程访问）；BACKOFF 分支内新增
      renew-or-acquire 租约（Invoke-LeaderElection 从不动他机活租约，故不会偷租约）+
      Save-LocalLeaseView，仍零额度读取、`lastReadAt` 不变、角色/心跳保持 BACKOFF，然后 exit 0。
      事件：`GLOBAL_BACKOFF_PUBLISHED` / `GLOBAL_BACKOFF_RETRY_FAILED`(ERROR)。
    - 故障注入：`Rename-Item` 移走 bare origin——clone 的 origin URL 不变，故 preflight 与
      绑定门禁仍通过，只有 fetch/push 失败（= 真实断网形状）。
    - 测试：global-backoff.test.ps1 新增 10 组（退避滴答续租+零读取、写失败入队、重试保留
      deadline、真实退避滴答发布、**普通滴答同样排空队列**、重试失败保队列、过期窗口丢弃、
      最长 deadline 合并、coordination 关闭丢弃、coordination 不可达时仍为安全本地退避且
      AutoAnchor 失败关闭）。全量 12 文件 PS7 + PS5.1 双运行时通过；PSScriptAnalyzer Error=0。
    - 文档：docs/scenarios.md 新增 §6.1「marker 没 push 出去怎么办」（含 Mermaid）。
    - 测试期修掉自身缺陷 3 处：使用了不存在的 `Assert-GreaterOrEqual`；`New-TestConfig` 只合并
      一层，部分覆盖 autoAnchor 会丢 prompt/maxPerDay 导致配置校验失败（改为完整 hashtable）；
      deadline 断言把 JSON 文档当时间戳解析（`[DateTime]::MinValue` → 永真假绿，改为比较
      `Get-GlobalBackoff.until`）。

R14. `718893a` **CQK-023 LOCAL_ONLY AutoAnchor 本地 durable Claim**
    - 修掉两个产品缺陷：
      ① 单机从来没有 claim 工件——at-most-once 全靠 runner 互斥体 + `state.processedEventIds`，
        而后者只在 `codex exec` **返回之后**才落盘（runner.ps1:240）。崩在 exec 与 persist 之间
        = 下一个滴答重新锚定 = 用户被重复计费。
      ② 旧的 `if (-not $localOnly)` 直接跳过 COMPLETED/FAILED 终态写回，单机 claim 无从收尾。
    - 新增 `scripts/anchor-claim.ps1`：统一 Claim/Complete/Fail/Exists/Mark-Expired 门面 +
      `$LocalOnly` 存储选择器。LOCAL_ONLY → `runtime/anchor-claims/<eventId>.json`
      （`FileMode.CreateNew` 独占创建，本地版 CAS）；Distributed → `coordination/events/<eventId>.json`
      （Git CAS push，从 auto-anchor.ps1 原样搬来，保留同名薄包装给 concurrency.test.ps1）。
      两侧同一记录形状（8 键固定顺序）、同一条规则：**任何已存在的 claim（CLAIMED/COMPLETED/
      FAILED/EXPIRED）都拦住执行**——结果不确定永不再试。
    - CLAIMED 在模型调用**之前**写；`claimExpiresAt` 只是 TTL 提示（`max(2, ceil(qtos×3/60)+1)×2` 分钟），
      不是释放键。exec 前跳过（prompt 不合规 / 找不到 codex）释放为 FAILED 并标 processed，
      否则 idle 一天一次会把这个 eventId 永久钉死。
    - CQK-014 租约复核仍走统一门面：`Mark-AnchorClaimExpired`（EXPIRED，不重试）。
    - 新增 `Invoke-AnchorClaimRetention`：只扫终态（CLAIMED 永不老化），按文件 mtime 判定，
      `≤0` / 目录不存在直接返回 0；挂在 runner 收尾（runner.ps1:315-325），与日志保留期同一
      `Get-Command` 守卫、同一个 try。
    - 序列化器 `ConvertTo-AnchorClaimRecordJson`：逐键手写、`-Depth 1`、显式 `$null → 'null'`。
      PS5.1 的 `ConvertTo-Json -Depth 0` 抛异常，且把 `$null` 标量渲染成空串。
    - 测试期发现并修掉第 3 个真实缺陷：`[string]$Result` 参数在 **5.1 和 7 上都会**把传入的
      `$null`（以及它自己的 `$null` 默认值）强制成 `''`，于是干净的 COMPLETED claim 在**两种
      backing**里都写成 `"result":""`——凭空捏造一个失败原因，且打破「两侧记录逐字段一致」的承诺。
      修法是 `Get-AnchorClaimResultValue` 在三处构造点把空白归一为 `$null`，不是放宽断言。
    - `tests/anchor-claim.test.ps1` 10 组：LOCAL_ONLY 记录形状（exec 前即可读到 CLAIMED +
      可解析 result）、四种已存在状态全部拒、崩溃窗口（CLAIMED 残留 → 下一滴答零模型调用）、
      执行与 state 落盘之间对端 claim 落地仍被拒、store 不可读时 fail closed 而非「看起来是空的」、
      finalize 不能复活 EXPIRED/终态、retention 只清终态不清 CLAIMED、四进程抢同一
      CreateNew 恰好一个赢、统一门面按 backing 路由且两侧措辞一致、分布式回归。双运行时通过。
    - 测试自身踩坑：`ProcessStartInfo` 在两侧都没有实例 `Start()`（用静态
      `[Diagnostics.Process]::Start($psi)`），且该调用位于顶层 try 内——异常被吞掉导致第 9、10 组
      **静默不跑**；`Assert-False/True` 形参是 `[bool]`，PowerShell 拒绝把 `$null`（报错里显示成 `""`）
      或 `''` 转成 `[bool]`，字段可能为 null 时必须用 `Assert-Null` 或显式比较。
    - 全量 13 文件 PS7 + PS5.1 双运行时通过；PSScriptAnalyzer Error=0（新增 warning 全部是
      Approved Verbs 家族对 `Claim-`/`Finalize-`/`Mark-` 的既有风格告警，与 auto-anchor 同源）。
    - 文档：docs/scenarios.md 新增 §5.1「锚定的至多一次保证」（含崩溃时间线 Mermaid + 真实
      CLAIMED 文件内容），§8 fail-closed 表补 5 行 claim 相关原因文本。

R15. `07c8c8f` **CQK-025 Get-StatusAssessment 健康诊断层**
    - 新增 `scripts/status-assessment.ps1`（三层架构的中间层，§8/§15.1）：
      `Get-KeeperStatus`（事实）→ **`Get-StatusAssessment`（overall + findings）** → 渲染层（CQK-026 起）。
      本层**只读**：从不调用 `Set-*`、不写 state、不写日志（§9.2 红线，测试直接断言
      state.json 逐字节不变、runtime 无新文件、日志零新增行）。
    - §9.2 契约：`overall = HEALTHY|WARNING|ERROR`；`summary` 固定三串中文之一
      （`运行正常` / `存在需要注意的配置` / `运行异常`）；`findings[] = {code,severity,title,action,
      titleEn,actionEn,detail?,observedAt}`。code/severity 英文、title/action 中文、detail 英文并携带
      原始值，一律过 `Hide-SensitiveText`；detail 为空时**键整个消失**（不是空串）。
    - §10.1 `Get-StatusOverall` 纯函数：任一 ERROR→ERROR；否则任一 WARNING→WARNING；否则 HEALTHY，
      INFO 永不降级。`Set-StatusSummary` 是 summary 的唯一改写点。
    - §10/§16 规则表全部落地：配置/任务/认证/额度新鲜度/coordination/租约/退避/锚定/AutoAnchor
      模式与横幅/lastError 与 verdict 流恢复降级（`LAST_ERROR_RECENT` 在 verdict 显示已恢复时降为 INFO）。
      fail-fast 头部：status 为空或 `configOk=false` 时**只出一条** `CONFIG_INVALID`。
    - `Get-StatusAnchorBlock`（面板「当前自动锚定被安全阻止」）复刻 **runner 完整判定链**而非只抄守卫：
      退避（`runtime/backoff.json`）与 Leader 租约是 `Test-ShouldAnchor` **之外**的门，故上提为第 1、2 步；
      守卫内部顺序原样保留，**每日上限排在额度新鲜度之前**（封顶才有人能操作，过期另有 `QUOTA_STALE`）。
      详见 docs/scenarios.md §8.1（8 行条件→code/severity→真实 detail 文本对照表）。
    - 不新增 `Get-KeeperStatus` 字段——派生事实（backoff、claim、processedEventIds、verdict 尾行）
      全部经 `Load-KeeperState` / `Get-BackoffState` / 只读日志尾部取得，守住 §7/§22 的 schema 红线。
    - 新增 `tests/status-assessment.test.ps1`（15 个 `Start-TestGroup`、201 处断言）：规则表逐条、守卫链优先级与直连
      （`-LocalOnly`+PASSIVE→`$null`、`-QuotaStale`+`-BackoffActive`→BACKOFF_ACTIVE、`maxPerDay 0`→`$null`）、
      形状容错（缺字段/畸形时间戳不抛异常）、§9.2 契约（含零写入）、脱敏组。
    - **修掉一个阻塞性可移植缺陷**：两个新文件此前无 BOM，Windows PowerShell 5.1 按 cp936 解码，
      中文字节对会吃掉右引号使 tokenizer 错位（38 + 5 个 UnexpectedToken 报错，特征 `未开?`）。
      加 UTF-8 BOM 后 5.1 原生解析 0 错误。规则：**`.ps1` 里只要非 ASCII 出现在字符串字面量中就必须带 BOM**
      （对应 PSScriptAnalyzer 规则 `PSUseBOMForUnicodeEncodedFile`）。
      注意仓库里 3 个既有文件（`scripts/common.ps1` 的中文只在注释里，但 `tests/common.test.ps1:52` 的
      `≈`、`tests/auto-anchor.test.ps1:73` 的中文 prompt 字面量在引号内）今天无 BOM 也能解析通过——
      那是 UTF-8 字节对与紧随其后的引号是否恰好配成 cp936 双字的**字节巧合**，不是可以依赖的规律；
      5.1 全仓 35 个 .ps1 原生解析当前 0 错误，本次不改它们以把改动限制在 CQK-025 范围内。
    - PS7 下另修 4 处测试夹具自身缺陷（clock 注入边界、`rateLimitReachedType` 样例值应为 `'primary'`
      而非 `'rate_limit_reached'`、退避时间戳格式为 `yyyy-MM-dd HH:mm:ss`、`Clear-Backoff` 缺失导致
      相邻用例串状态）。全量 14 文件 PS7 + PS5.1 双运行时通过；PSScriptAnalyzer Error=0。

R16. `bf57bc7` + `9e105f7` **CQK-026~030 Status 中文诊断面板（渲染层）**
    - 新增 `scripts/status-display.ps1`（819 行，三层架构的最外层）：
      `Get-StatusDisplayModel`（派生字段）→ `Get-StatusDisplayLines`（逻辑行对象）→
      `Write-StatusConsole`（唯一上色点）。`status-json.ps1` 英文 schema 一行未动（§7/§22 红线）。
      **渲染层与 assessment 层按红线要求分成两个 commit**：`bf57bc7` 只动判断层
      （抽出 `Get-StatusAnchorToday`，面板与 verdict 共用「今日锚定次数」规则，避免
      上限告警说 6/6 而面板显示 0/6），`9e105f7` 才是渲染层 + 测试 + golden。
    - §11/§12 七分区（总体状态 / 计划任务 / Codex / AutoAnchor / 多机协调 / Codex 额度 /
      异常与建议），术语映射集中一处；未识别值降级为 `未知（RAW）` 而非留空，
      角色/模式/严重度都保留原始英文码便于对照日志。
    - **§11.1 列对齐不变式**：`$CqkStatusLabelCol = 18`、`$CqkStatusValueCol = 20`，
      冒号恒在第 18 个**显示单元格**。`Get-CqkDisplayWidth` 按 CJK 双格计算——
      `'本机 ID'` 5 字符 7 格、`'当前状态'` 4 字符 8 格，**字符数与格数对两个标签的排序方向
      相反**，用 `[string]::Length` 补齐会让两处冒号差出两格。续行同样落到第 20 格。
    - §13 颜色契约：不把 ANSI 拼进字符串，逻辑行是 `@{text;color}`，只在 `Write-Host`
      时上色；`[正常]/[注意]/[异常]/[信息]/[关闭]` 前缀自带语义，所以 `-NoColor`、重定向、
      golden 文件零信息损失。`Write-StatusRow` 的 `-Severity` 与 `-Color` 互斥（同时给出即抛，
      且在写行**之前**抛，不留半行）。测试用 `6>&1` 捕获 `InformationRecord`，文本在
      `MessageData.Message`（`$rec.Text` 是空的），未上色行的 ForeColor 报 `Gray` 而非 `$null`
      ——因此「没上色」必须断言为 `-notcontains $SevColors`，不能断言 `≠ $null`。
      两个方向都测（关色时 0 行着色、开色时 >0 行着色、每条红行文本必含 `[异常]`），
      否则「渲染器干脆不上色」也能骗过测试。
    - §14 `-Language en-US` = v2.0 之前的英文事实清单，实现搬进 `Write-StatusTextEn`；
      `status.ps1` 里的 `Write-StatusText` 保留 `[hashtable]` 签名改成 shim，两条路径不会各自漂移。
      英文面板断言「无 CJK 字符」且「绝不上色」。
    - §15.2 派生字段：配额**剩余**百分比（`100 - used` 并 clamp 到 0~100）、窗口中文名按
      分钟数推导（不硬编码 5h/7d）、数据新鲜度、AutoAnchor `judgment`/`schedule` 双模式与
      `下一个槽位`（槽位等于当前时间算明日）、执行模型/思考等级留空即 `沿用 CLI 默认`、
      `今日已执行` 来自共享 helper、`当前锚定` 行由 finding 流驱动（INFO 不带建议行）。
      缺 `config.json` 与配置存在但值为 0 是两回事，两个 case 都测。
    - §17.2 golden：`tests/golden-fixtures.ps1` 是四份快照的**唯一**数据来源，
      `golden-update.ps1` 重写、`status-display.test.ps1` 逐行比对，另跑跨快照对齐扫描
      （padding 从行文本反推，不调用渲染器自己的公式），改 padding/术语必须显式重生成快照。
      快照 UTF-8 **无 BOM** + LF + 结尾换行；重生成后 md5 逐字节一致，证明渲染确定。
      4 个场景各钉一个不同行为（关态基线 / INFO 静默期 / schedule 槽位+模型 / 多机 ERROR+脱敏），
      并断言 ERROR 排在 WARNING 前、已使用→剩余→重置时间顺序。
    - 新增 `tests/status-display.test.ps1`：15 组 **528 项检查**，pwsh 7.6.5 与
      Windows PowerShell 5.1.19041 双运行时全绿；全量 `tests/run-all.ps1` 15 文件双运行时通过。
    - **两条 PS 语言级坑（都写成回归测试）**：
      ①函数 `return @(...)` 在**只有一个元素**时会被摊平成 `String`，`(F)[0]` 就变成 `Char`，
      `.EndsWith()` 直接抛——保型写法是 `return ,$array`（空/单/多三种长度在两个运行时行为一致）；
      ②`@($List[object])` 在两个运行时都报 `Argument types do not match`，必须用 `[object[]]` 强转
      （`[object[]]$null`→0 个，`[object[]]$hashtable`→1 个）。
    - BOM 规则复述：`.ps1` 里非 ASCII 只要出现在**字符串字面量**中就必须带 UTF-8 BOM，否则 5.1
      按 cp936 解码把中文字节对当成双字吃掉右引号、tokenizer 错位；只在注释里出现（如 `§`）可免。
      `Write` 类工具产出的是无 BOM 文件，落盘后要补 `ef bb bf`。
    - CI 一致性：`PSScriptAnalyzerSettings.psd1` 只把 Error 作为门禁，全仓 Error=0；
      新增的唯一 warning 是 `Get-StatusDisplayLines` 的复数名词提示（非门禁项）。

R17. `349e15c` + `98e7f17` **CQK-031/032 发布工程：任务时限推导 + mode 动态描述**
    - CQK-031 首先纠正一个语义误解：`codex.queryTimeoutSeconds` 约束的是**每一次 JSON-RPC 等待**，
      不是一整轮。一次尝试含 2 次等待（`initialize` id=1、`account/rateLimits/read` id=7）；配了
      代理则尝试数翻倍为 2（CQK-020：从不第三次），故只读预算 = `q * 2 * attempts`。AutoAnchor 再加
      `Max(60, q*3)` 执行窗口 + 第二次完整校验读取；远程同步再加有界的
      `CQK_GIT_SYNC_BUDGET_SECONDS = 240`。于是 `q=180` + 代理 + AutoAnchor ≈ 2220 s ≈ 37 min——
      旧的固定 15 分钟 `ExecutionTimeLimit` 会在半途杀掉它。
    - 四个消费方（安装器的 limit、校验器的硬失败、anchor 模块的 `q*3` 执行窗口、状态面板的告警）共用
      `Get-CodexTickBudgetSeconds` 这一个算术源；测试用断言
      `task limit equals the derived limit (single source of truth)` 钉死，防止四处各自猜测。
    - **设计决策**：预算 vs poll 的规则**只**写在 `Test-ConfigShape`（硬失败），
      `Get-KeeperTaskExecutionTimeLimit` 只 clamp 到 `poll - 2 min` 并报 `cappedByPoll`。所以
      `cappedByPoll` 是**合法配置上的告警**，不是非法配置的症状——只读状态面板正是配置出问题时用户
      伸手要拿的工具，绝不能被校验规则挡住而抛异常。安装层测试把这条分界钉成两个 case：poll=13
      （合法但被 clamp，11 min）与 poll=11（硬失败）。
    - 行为变化（值得注意）：默认 MonitorOnly **带**远程同步的安装，现在推导 260~280 s → 落到 10 分钟
      下限，而不是旧的固定 15 分钟（仍 ≥ 有界 git 最坏情况），已显式断言防回归。
    - PS 坑（新）：`ScheduledTaskSettingsSet.ExecutionTimeLimit` 回读是 ISO 8601 时长**字符串**
      （`PT10M`）而非 TimeSpan，`.TotalMinutes` 恒为 0；测试必须用
      `[System.Xml.XmlConvert]::ToTimeSpan($raw).TotalMinutes` 解析。
    - CQK-032：`Get-KeeperTaskDescription` 按 mode + 锚定是否**真的**上膛生成描述（`mode=AutoAnchor`
      本身不够，runner 只在 `codex.autoAnchor.enabled=true` 时锚定）。中途修掉一版会说谎的描述：
      `mode=AutoAnchor` + 锚定关闭时曾字面输出 `(MonitorOnly)`，改为恒回显 `(mode=$mode)`。
      `apply-config.ps1` 经 `Register-KeeperTask` 重注册，所以老安装下次 apply-config 自动更新描述。
    - 测试：`common.test.ps1` 新增 1 组（上限边界 180 通过 / 181 拒绝、四段预算算术、硬失败边界
      poll=12 通过 / poll=11 拒绝）；`install-status.test.ps1` 新增 2 组（安装后的 settings 携带推导值、
      描述文案三个方向 + 255 字符上限）；`status-assessment.test.ps1` 新增 1 组并把
      `TASK_TIME_LIMIT_TIGHT` 注册进 catalog 契约清单。全量 15 文件 PS7 + PS5.1 双运行时通过。

R18. `a4a1004` **CQK-033 Secret Scan：删掉整目录排除，改成按字面量豁免**
    - 原 `security.yml` 的扫描步骤是内联 `Where-Object { $_.FullName -notmatch '\\tests\\' }`，
      一行改动就能让 ~20 个测试文件和全部 golden 快照悄悄脱离扫描，且仓库里没有任何东西会发现。
      所以修法不是「把排除范围缩小」，而是**根本没有路径排除** + 把逻辑挪进
      `tests/secret-scan.ps1`（CI 与本地同一份）并新增 `tests/secret-scan.test.ps1` 断言它：
      **可断言的覆盖率才是覆盖率**，写在 YAML 里的正则不是。
    - 豁免粒度是**字面量**而不是文件：4 个合成假 token 先 `Replace()` 掉，再对**每个文件**跑全部
      6 个模式，所以往 fixture 里粘一个真 token 照样失败（已测）。清单外文件出现这些假 token 是
      **finding**，不是 pass——粘假 token 和粘真 token 在扫描器看来没有区别。
    - 三个反向腐化检查（缺一个就会重新变成盲区）：字面量没被任何文件使用 → `stale fixture allowlist
      entry`；allowlist 文件不在了 → `allowlisted fixture file is not present in the scan`；
      `$MustScan` 文件没被 walk 到 → `scan is blind`（附实际文件数）。读不了的文件报
      `unreadable file` 而不是当干净处理。
    - **自证陷阱（第一次实现踩的坑）**：声明假 token 的文件本身就是它的一次「使用」，所以
      stale 检查永远不会触发——第一版故意加一个不存在的字面量仍然输出「No credential patterns
      found」。修法是把 `$self`（声明处）从**计数**和**匹配**里都排除掉，而不只是排除匹配。
    - **PS 路径坑（真因，两个运行时都复现）**：`(Resolve-Path -LiteralPath $Root).Path` 会返回
      **8.3 短路径**（`C:\Users\ADMINI~1\...`），而 `Get-ChildItem` 的 `FullName` 返回**长路径**
      （`C:\Users\Administrator\...`）；用短前缀长度去 `Substring` 长路径，得到的相对路径是
      `b8b6/codex-quota-keeper/tests/...`（temp 目录名的尾巴），于是所有 allowlist 比较静默失效、
      测试以 3 个「找不到」失败。改用 `(Get-Item -LiteralPath $Root).FullName`，并把 Substring
      前面加 `StartsWith($base + '\')` 守卫——形态不匹配时**退回绝对路径**，让 `$MustScan` 大声失败，
      而不是悄悄产出垃圾路径。（`Resolve-Path -Relative` 两个运行时都给 `.\a\b\c.txt`，也可用。）
    - 测试写法教训：断言用**精确整串** `@($issues) -contains "$file matches $pattern"`，模式句柄
      按**前缀查找**（`$P_GHP` 等）而不是下标；原来的 `Where-Object { $_ -match 'api_key' }` 只匹配
      问题文本里的字，模式本身写错也能通过。CI wiring 断言必须先**剥掉注释行**再判
      `-notmatch '\\tests\\'`，否则 YAML 里那段「解释旧过滤器」的注释会让负向断言假绿。
      已用合成回归（把旧过滤器塞回 `run:`）验证三条断言确实会红。
    - 全量 `tests/run-all.ps1` **16 文件** PS7 + PS5.1 双运行时通过；`pwsh -NoProfile -File
      codex-quota-keeper/tests/secret-scan.ps1` 在仓库根实跑 = 74 文件、exit 0。
    - 遗留：PSScriptAnalyzer 只扫 `codex-quota-keeper/scripts`，新脚本在 `tests/` 下**不被 lint**（与
      其余测试脚本一致，非本次引入）。

### 下一步
- P2 组剩余 CQK-034/035：GitHub Ruleset/required checks（**仅文档建议 + 只读检查**；本会话 github MCP
  连接失败 400 "Authorization header is badly formatted"，需用户修复后才能真正核对 secret scanning /
  push protection，读不到的一律记 `Unknown`，不得自行开关）、v0.9.0-beta 打包（ZIP + SHA256 + 升级说明）。
- 收尾：README / `config.example.jsonc` 默认值同步（需补 `-Language` / `-NoColor` / `-Detailed`、
  `queryTimeoutSeconds` 上限与推导出的 `ExecutionTimeLimit`）、`config.example.jsonc:90` 的 120/200
  字符提示词上限措辞与 `Test-AnchorPromptAllowed` 对齐、CHANGELOG、双机 soak + 故障注入。
- **需用户决定的遗留风险（未擅自修）**：本地 `core.autocrlf=true` 且仓库**没有 `.gitattributes`**，
  而 `status-display.test.ps1:674` 断言 golden 快照字节里不含 `` `r ``。若某次 checkout 做了 CRLF
  转换，该断言会在代码正确的前提下失败；git 每次提示「LF will be replaced by CRLF」即其症状。
  加 `.gitattributes` 属仓库级行为变更，留给用户定夺。
- `git push` 等待用户明确要求，并按全局规则先对待推送内容做只读敏感信息检查。

