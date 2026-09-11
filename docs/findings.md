# 开发发现与决策记录

## 环境
- Windows 11、Git Bash、Python 3.12（用于提取 docx）。
- 目标语言：PowerShell（文档明确技术栈为 PowerShell 7，兼容 5.1 入口层）。
- 无 node/npm 假设，纯脚本 + 测试用 Pester。

## 关键决策
- 项目放根目录 `codex-quota-keeper/`（文档示意的部署名）。
- 测试：用简洁的 PHPUnit 风格断言函数，避免强依赖 Pester 版本；仍可 `-Passthru` 手工跑。
- 所有配置默认保守：mode=MonitorOnly、autoAnchor=false、poll 15 分钟。
- 租约 CAS 用 `git push` non-fast-forward 冲突实现（文档 10 节伪代码）。

## 待确认
- 无（设计文档足够具体，直接照做）。

## 进度
- [x] 提取并阅读 4 份 .docx（已转 UTF-8 到设计要点）。
- [x] 实现（见 task_plan.md 分步，10 步全部完成，见 progress.md 完成记录）。

## 实现期新增发现（踩坑记录）
- `pwsh -File` 对未声明的命名参数静默塞入 `$args` 而不报错。
- 子进程 stdin 编码必须 `UTF8Encoding($false)`；`[Encoding]::UTF8` 首写会带 BOM 破坏 JSON-RPC。
- PS7 `ConvertFrom-Json` 会把 ISO 时间字符串自动转 `[DateTime]`，重新 `[string]` 化会变本地化格式。
- PowerShell 函数返回单元素数组会被 unroll（`return ,$list` 防御）。
- `@($null).Count` 为 1（判断空集合需先过滤 null）。
- dot-source 带 `param` 的脚本会在调用方作用域用默认值覆盖同名变量。
- Win11 拒绝 `RepetitionDuration=[TimeSpan]::MaxValue`（越界 XML），用 3650 天代替。
- git plumbing 提交必须 `read-tree <parent>` 保留原树，否则每次推送会抹掉分支上其它文件。

---

# v3.0（P0 Hardening）实施前核对：文档结论 vs 代码现状

文档：`C:\Users\Administrator\Desktop\codex-Monitor_P0级修复优化设计_v3.0.docx`
（提取文本 `C:\Users\Administrator\AppData\Local\Temp\docx30\doc.txt`，469 行）。基线 `cdca944`。

## 8 个 P0 问题逐条对照真实源码（全部成立）
| 问题 | 代码证据 | 结论 |
|------|---------|------|
| P0-01 Anchor 审计双写 | `auto-anchor.ps1:266-284` 直接 `Write-OutboxEvent` + `Write-HistoryEvent`，Runner `runner.ps1:254-273` 对同一 `ANCHOR_EXECUTED/ABORTED` 再写一次 | 确认双写；且 `$anchorRecord.eventId = [string]$claimed[0]` 丢掉合并触发的其余 eventId |
| P0-02 model/effort 只校验形态 | `common.ps1:721-735` 注释「Deliberately NOT a semantic whitelist」；无 `config/read` / `model/list` 任何调用点 | 确认；需新增三层语义校验，数据源只能是本机 CLI |
| P0-03 Install 不拦 armed AutoAnchor | `install.ps1:197-240` `Invoke-KeeperInstall` 只有 preflight + 单次 probe，无 mode/enabled 联合门禁 | 确认；Apply 失败会留下半成品任务的风险真实存在 |
| P0-04 运行期不复验 Profile | `auto-anchor.ps1` 从 claim（:148）到 exec（:212）之间无任何 profile 校验 | 确认；复验必须插在 Claim **之前** |
| P0-05 审计缺 configured/effective 区分 | `$anchorInfo`（:222-237）只有 `model`/`reasoningEffort` 两个字段，来源与校验态不落盘 | 确认 |
| P0-06 锚定计数只有 `count` | `auto-anchor.ps1:240-243` 写 `@{day;count;lastAnchorAt}`；`state-machine.ps1:40` 同形 | 确认；§24 迁移见下 |
| P0-07 错误分类靠上层正则 | `runner.ps1:176-192` 用 `errorKind` + 一大坨 `(?i)` 文本正则判网络/429；`quota-client.ps1:373-389` 只识别 AUTH_ERROR，其余全 `PROTOCOL_ERROR` | 确认；`retryable` 字段根本不存在 |
| P0-08 Status 看不到执行配置语义 | `status.ps1:143` 只 echo 配置里的 model/effort 字符串；无 profile 缓存文件概念 | 确认 |

## 关键设计约束（会咬人的地方）
- **`mock-appserver.ps1` 的 `default { }` 静默吞未知方法**（:1-326 的 method switch）。加 `config/read`
  / `model/list` 调用而不扩 mock，症状是**超时挂等**而不是明确报错 —— 每个新 RPC 方法必须与 mock 同一 commit 落地。
- **`anchors.count` 旧形状被钉死的地方（§24 迁移消费点）**：`status.ps1:143`、
  `status-assessment.ps1:247-248`、`state-machine.ps1:339` 每日上限、`auto-anchor.test.ps1`
  约 11 处断言（含 :278 手写状态）、`docs/scenarios.md` §1/§7。改形状必须同时改这些，否则
  Status 面板会静默显示 0。
- **`SETUP_ERROR`（文档措辞）vs `SETUP_ERR`（代码/测试实际值，`quota-client.ps1:414/420/429`，
  `quota-client.test.ps1:232/305`）**：运维可见字符串，需按文档统一为 `SETUP_ERROR` 并同批改
  测试与文档，不能悄悄改一半。
- **`CQK_JSONRPC_WAITS_PER_ATTEMPT = 2`**（`common.ps1` 预算区）当前含义是「一次尝试里 initialize + read
  两次等待」。同一会话追加 `config/read` + `model/list` 会改变该常量的含义，进而影响
  `Get-CodexAttemptBudgetSeconds` / `Get-KeeperTaskExecutionTimeLimit`（CQK-031）与计划任务时限的关系；
  CQK-044 的「最多 4 次低层尝试」也要在同一预算模型下核算，不能各自 clamp。
- **`proxy='fallback'` 与 ≤4 尝试上限的交互**：现在 `Invoke-CodexRateLimitsRead` 是 proxy→direct 共 2 次、
  绝不第 3 次（`quota-client.test.ps:277/293` 钉死）。CQK-044 的 2 Round 只能加在 Install 层，
  读侧本身的重试语义不能变，否则这三条断言会红。
- **P0-04 复验点必须在 Claim 前**：Claim 之后才发现 INVALID 会撞上「CLAIMED 永不老化」闸门
  （`anchor-claim.ps1` retention 明确不清 CLAIMED），该 eventId 当天就死了。
- **Apply 失败不动既有任务**：`Register-KeeperTask` 是 read-modify-write `Set-ScheduledTask`，
  门禁必须放在任何任务写操作之前，而不是失败后回滚。
- **§22 非目标**（别越界）：不加新触发类型、不重写为 Python/.NET、**不在仓库里硬编码模型清单**、
  不做 GUI/Web、不做无界重试、不把 `config/read` 全量倒进日志。
- **§23 隐私**：`config/read` 只允许取 `model` / `model_reasoning_effort` / `model_provider` 三字段；
  目录不落盘全量；`execution-profile.json` 只存白名单字段（model/effort/provider/source/validation/validatedAt），
  绝不含 token / 账号详情 / 完整配置。

## 待验证的外部事实
- 本机 `codex app-server` 是否真的提供 `config/read` 与 `model/list`、响应字段名与分页 cursor 字段名。
  实现按文档 §15 的假设写，并用 mock 覆盖；真机差异留给 CQK-048 soak 暴露（不因此阻塞开发）。