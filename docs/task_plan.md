# Codex Quota Keeper — 开发任务计划

依据 `docs/design/` 下四份设计文档（01 合规、02 架构、03 详细设计、04 部署运维），
在当前仓库根目录实现 `codex-quota-keeper/` 项目。

## 设计要点（从文档提取）
- **双模式**：默认 MonitorOnly（只读额度、记录）；AutoAnchor 实验默认 false。
- **零常驻**：Windows Task Scheduler 定时触发 `runner.ps1`，跑完即退出。
- **单 Leader**：复用 Private GitHub 仓库做分布式租约（`coordination/lease.json`），Git push 冲突作 CAS。
- **只读官方协议**：Codex app-server `account/rateLimits/read`，不碰 auth.json/网页。
- **安全**：不写 token、纯净日志、repoPath 白名单、参数数组化、mock 测试。

## 目标文件树
```
codex-quota-keeper/
  README.md
  .gitignore
  status.cmd
  install.cmd
  uninstall.cmd
  apply-config.cmd
  config.example.jsonc
  scripts/
    common.ps1
    install.ps1
    uninstall.ps1
    apply-config.ps1
    runner.ps1
    status.ps1
    status-json.ps1
    preflight.ps1
    quota-client.ps1
    state-machine.ps1
    leader-lease.ps1
    logger.ps1
    github-sync.ps1
    auto-anchor.ps1
  tests/
    common.test.ps1
    state-machine.test.ps1
    logger.test.ps1
    runner.test.ps1
    quota-client.test.ps1
```

## 分步 commit 顺序
1. 骨架：README/.gitignore/config.example.json + cmd 入口。
2. scripts/common.ps1（配置加载、路径、退避窗口、脱敏等共享设施）＋ 单元测试。
3. quota-client.ps1（app-server 协议）＋ mock 测试。
4. state-machine.ps1（事件识别/幂等 eventId）＋ 测试。
5. logger.ps1（JSONL/净化/保留期）＋ 测试。
6. preflight.ps1 + leader-lease.ps1 + github-sync.ps1。
7. runner.ps1 + 测试。
8. auto-anchor.ps1（实验，默认关）。
9. install/uninstall/apply-config + status/status-json。
10. 全量断言、文档对齐核对、收尾。

## 状态（2026-08-30 全部完成）
- [x] 骨架
- [x] common
- [x] quota-client
- [x] state-machine
- [x] logger
- [x] preflight/lease/sync
- [x] runner
- [x] auto-anchor
- [x] install/status
- [x] 收尾核对

---

# 第三轮：设计文档 v2.0（2026-09-08）CQK-021~035

依据 `C:\Users\Administrator\Desktop\codex-Monitor_最新仓库审查与Status中文诊断面板设计_v2.0.docx`。
基线 c7260f7c。实施顺序按文档 §19。

## 阶段 A：P1 核心修复（CQK-021~024）
- [x] CQK-021 默认 poll/lease TTL 关系修复 + 配置关系校验
  - 默认 leaseTtlMinutes 改 180（poll=60）；校验规则：
    leaseTtlMinutes >= max(2*poll.intervalMinutes, poll.intervalMinutes + grace + schedulingJitter)
    违反时校验失败；README / config.example.jsonc / 测试同步。
- [x] CQK-022 计划任务持久化自定义 -ConfigFile
  - New-KeeperTaskParameters 增加 ConfigFile；Get-KeeperHiddenLauncherSpec 正常任务路径也传
    ConfigFile；安装时解析绝对路径写入 VBS；端到端测试：自定义 ConfigFile 安装后读 VBS 内容
    确认同一路径。
- [x] CQK-024 Backoff 期间继续 coordination maintenance（先于 023，安全闭环）
  - Backoff 拆为「禁止 Codex 访问」而非「退出 Runner」；仍续租、补写 pending global backoff
    marker、写 heartbeat/status；新增 runtime/pending-global-backoff.json 持久化远程写失败；
  - 每次任务滴答即使 local backoff active 也尝试补写 pending marker；
  - coordination 不可达时本地安全退避，AutoAnchor 继续失败关闭 (fail closed)。
- [x] CQK-023 LOCAL_ONLY AutoAnchor 本地 durable Claim
  - 统一 Claim 抽象（IAnchorClaimStore 语义）：Claim/Complete/Fail/Exists；
  - LocalOnly → runtime/anchor-claims/<eventId>.json；Distributed → coordination/events（Git CAS）；
  - LOCAL_ONLY 在 codex exec 前原子创建 CLAIMED 文件；任何 CLAIMED/COMPLETED/FAILED/UNKNOWN
    阻止自动重试；COMPLETED/FAILED 由 retention 清理；并发与崩溃 (crash) 测试基于统一接口。

## 阶段 B：Status 中文诊断面板（CQK-025~030）
- [x] CQK-025 Get-StatusAssessment 健康诊断层（overall/findings，§10 规则表、§16 新增规则）
- [x] CQK-026 默认中文分区输出 + 中文术语映射（§11/§12；采集/判断/渲染三层分离；
      不改 Get-KeeperStatus 字段；LOCAL_ONLY 单机=INFO 不警告）
- [x] CQK-027 Quota 剩余百分比、窗口中文名、数据新鲜度
- [x] CQK-028 AutoAnchor judgment/schedule 模式友好展示（§11.2/11.3）
- [x] CQK-029 颜色/NoColor/PS5.1 中文兼容测试（文本前缀 [正常]/[注意]/[异常]/[信息]/[关闭]）
- [x] CQK-030 golden output 快照测试（MonitorOnly healthy / AA judgment / AA schedule / Multi-PC error）

## 阶段 C：P2 发布工程（CQK-031~035）
- [x] CQK-031 queryTimeout 上限约束（120~180 秒）与 Task ExecutionTimeLimit 关系
- [x] CQK-032 Task Description 根据 mode 动态生成
- [x] CQK-033 Secret Scan 缩小 tests 排除范围（只 allowlist fake-token fixture）
- [x] CQK-034 GitHub Ruleset / required checks（文档仅建议；仓库 API 侧只读检查）
- [x] CQK-035 v0.9.0-beta Release 打包流程（ZIP+SHA256+升级说明；推送前遵守用户 push 规则）

## 收尾
- [x] 全量测试 PS7 + PS5.1 回归通过（17 文件，R19）
- [x] README / config.example.jsonc 默认值同步
- [x] CHANGELOG 更新

## 决策记录
- 阶段顺序采用文档 §19：021 → 022 → 024 → 023 → Status 组 → P2 组。
- Status 重构不改 status-json.ps1 英文 schema（§7/§22 红线）。
- CQK-034 Ruleset 创建属 GitHub 平台配置变更，需用户决定；开发侧仅准备/检查。
- CQK-031：预算/上限校验只写在 Test-ConfigShape（硬失败），推导函数只 clamp + 报 cappedByPoll；
  这样只读 Status 面板永远不会被校验规则挡住（面板正是配置出问题时要用的手段）。

---

# 第四轮：P0 修复优化设计 v3.0（2026-09-10）CQK-036~048

依据 `C:\Users\Administrator\Desktop\codex-Monitor_P0级修复优化设计_v3.0.docx`
（提取文本 469 行，见 findings.md「v3.0 文档要点」）。基线 `cdca944`。实施顺序按文档 §18。
目标：8 个 P0 问题全部关闭，13 张工单 CQK-036~048。

## 阶段 D：审计唯一性（CQK-036）
- [x] CQK-036 Anchor Audit 双写消除 → Single Writer（Runner 是唯一 Event Persistence Owner）
  - auto-anchor.ps1 不再调用 Write-OutboxEvent / Write-HistoryEvent；
  - 新增 `anchorInvocationId`；多个 trigger claim 可映射同一 invocation，但 invocation audit 只有一条；
  - Runner 侧持久化 anchor 事件时携带完整 anchorInfo（含全部 eventIds，修掉 `$claimed[0]` 丢触发）。

## 阶段 E：执行配置语义校验（CQK-037 + 038）
- [x] CQK-037 抽出共享 JSON-RPC 会话层（app-server-client.ps1）：Start/Initialize/Invoke/Stop
      + Invoke-CodexRateLimitsRead / Invoke-CodexConfigRead / Invoke-CodexModelList；禁止复制三份客户端；
      `model/list` 必须处理 nextCursor 分页 + 严格页/条上限（§15.1）。
- [x] CQK-038 Execution Profile Resolver 三层语义校验：L1 形态 → L2 本机 CLI 模型目录 → L3 思考等级；
      来源永远是本机 Codex CLI 自身，**仓库内不写任何静态模型白名单**。

## 阶段 F：安装/运行期门禁（CQK-039 + 040）
- [ ] CQK-039 Install/Apply armed gate：mode=AutoAnchor + enabled=true 硬阻断；MonitorOnly 或
      enabled=false 仅警告；UNAVAILABLE fail closed；Apply 失败不得改动既有计划任务。
- [ ] CQK-040 运行期 Claim **之前**做 live Profile 复验：INVALID/UNAVAILABLE → 不 claim、不 exec、下一轮再试。

## 阶段 G：审计与计数（CQK-041 + 042）
- [ ] CQK-041 审计记录 configured* / effective* / provider / source / validation 三处一致
      （runtime log、local history、remote history）。
- [ ] CQK-042 锚定计数 attemptCount/successCount/failedCount/lastAttemptAt/lastSuccessAt；
      Profile 校验失败**不计数**；每日上限仍走 attemptCount；§24 旧 `count` 迁移，不伪造 successCount。

## 阶段 H：错误分类与重试（CQK-043 + 044 + 045）
- [ ] CQK-043 统一 errorKind + retryable（由底层客户端产出）；runner 正则判定改为读字段。
- [ ] CQK-044 Install probe 有界重试：最多 2 Rounds（每 Round = proxy + direct），
      低层尝试 ≤4，绝不第 5 次；Round 间隔 2s；仅 NETWORK_ERROR/TIMEOUT/EOF 重试。
- [ ] CQK-045 中文分级 Install Preflight（【配置文件】/【Codex CLI】/【AutoAnchor 执行配置】/
      【额度接口】/【计划任务】+ [正常]/[注意]/[异常]）；app-server 原始错误降级到 Detailed/日志。

## 阶段 I：Status 可见性（CQK-046）
- [ ] CQK-046 Status「AutoAnchor 自动锚定」区扩充 Execution Profile + `runtime/execution-profile.json`
      缓存（只含白名单字段）；默认 status.cmd **不发** live catalog 网络请求；`status -Live` 才刷新。

## 阶段 J：测试矩阵（CQK-047）
- [ ] CQK-047 T01~T20 测试矩阵；T19 PS7 + T20 WinPS 5.1 全绿。
      夹具 `tests/fixtures/mock-appserver.ps1` 必须新增 `config/read` / `model/list`（含分页）响应
      ——现有 `default { }` 会静默吞掉新方法，导致超时而非明确失败。

## 阶段 K：发布门禁（CQK-048）
- [ ] CQK-048 双机真机 soak + 故障注入 = Release Gate —— **由用户排期执行**；
      完成前不打 tag / 不建 Release。文档与 `docs/soak-runbook.md` 同步新增判据。

## 收尾
- [ ] run-all.ps1 PS7 + WinPS 5.1 双运行时全绿；PSScriptAnalyzer ERRORS=0；secret-scan 通过
- [ ] golden 面板按新输出重生成；README / config.example.jsonc / CHANGELOG / docs/scenarios.md 同步
- [ ] 落 main：feature branch → PR → CI 绿 → merge（禁直接 push main，GH013 实测）