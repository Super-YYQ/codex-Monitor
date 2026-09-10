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