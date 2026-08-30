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
5. `f91c693` **步骤5 logger.ps1 + 测试**
   - `scripts/logger.ps1`：runtime/logs/keeper-YYYY-MM-DD.jsonl（03 文档 §11 schema：ts/level/event/
     machineId/role/mode/windows/anchor/error，错误文本入库前脱敏）；history/events-*.jsonl 净化白名单记录
     （prompt/会话/凭证字段一律丢弃）；history/summary-YYYY-MM-DD.json 每日滚动汇总（counts 累积/anchor/错误计数/
     最后快照）；Invoke-LogRetention 按 retentionDays 清理本地 runtime/logs 与 history（不动远程 Git 历史）；
     Get-RecentErrors 供 status.ps1 读取最近 ERROR。
   - `tests/logger.test.ps1`：6 组全过（schema 字段存在性、脱敏、history 白名单、汇总累积、保留期、最近错误排序）。
   - 修复 common.ps1 深转换函数单元素数组被 PowerShell unroll 的问题（`return ,$list`），并全量回归通过。
6. `3f85a17` **步骤6 preflight + leader-lease + github-sync + 测试**
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
7. `d6df316` **步骤7 runner.ps1 主流程 + 端到端测试**
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
8. `086dabd` **步骤8 auto-anchor.ps1（实验，默认关）+ 测试**
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
9. `48edc35` **步骤9 install/uninstall/apply-config/status/status-json + 测试**
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
    - 交付物核对（对齐 doc/03 §2 目录）：scripts/ 14 个脚本齐备（含 common/status-json 两个实现期补充），
      tests/ 10 个测试文件 + mock fixture + run-all 入口，4 个 .cmd 入口与 config.example.json 就位；
      config.example.json 补齐文档 02 §6 的 task 段。
    - 敏感信息扫描：仓库无 token/密钥；auth.json 仅在注释与文档中以禁止性说明出现；
      脱敏由测试断言保障（token/refresh_token/Bearer/sk- 均被清除）。
    - 验收标准逐条核对（doc/04 §9）：零常驻（runner 单次运行退出）、status 只读秒级返回、
      租约 CAS 保证单 Leader、MonitorOnly 默认且无模型调用路径、429/认证退避、
      history 仅净化数据、TTL 接管、卸载删任务/历史可选——均有对应实现与测试。
    - task_plan.md / findings.md 更新为完成状态，并记录实现期踩坑清单。







## 下一步
- 开发任务全部完成。后续使用：复制 config.example.json → config.json 后运行 install.cmd；
  AutoAnchor 保持关闭，除非用户明确接受 doc/04 §11 风险清单。
