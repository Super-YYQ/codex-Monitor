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

## 真机协议核对（codex 0.153.4，本机 app-server 实测，非文档假设）
用临时探针脚本（放在仓库外的 `%TEMP%`，避免被 secret-scan 扫到）直连本机
`codex app-server`，`initialize` → `initialized` → 各方法。**文档 §15 的假设全部成立，
且拿到精确 wire 形状**：

- `initialize` → `{userAgent, codexHome, platformFamily, platformOs}`。
- `config/read`（`params={}`）→ `{ config: { ...几十上百个键... } }`。其中与 Profile 有关的只有
  `model:"gpt-6-astra"`、`model_reasoning_effort:"xhigh"`、`model_provider:null`。
  **同一 blob 里还有 `notify:[绝对 exe 路径]`、`desktop.enabled-reasoning-efforts:[...]`、
  `shell_environment_policy.set.*SHA256S`、`permissions`、`instructions`、本机路径** ——
  §23 白名单不是可选项，绝不允许 `ConvertTo-Json` 整个 result 进日志/历史。
- `model/list`（`params={}`）→ `{ data: [...], nextCursor: null }`；条目字段：
  `id, model, upgrade, upgradeInfo, availabilityNux, displayName, description, modelSpecialty,
  hidden, supportedReasoningEfforts, defaultReasoningEffort, inputModalities, isDefault, ...`。
- **`supportedReasoningEfforts` 是对象数组 `[{reasoningEffort, description}]`，不是字符串数组**
  —— L3 校验必须先投影 `.reasoningEffort`，按字符串比会永远判失败。（这一条纠正了开工前的设计假设。）
- **分页真实存在**：`params={limit:2}` → `n=2, nextCursor=2`；cursor 是服务端返回的不透明值，
  必须原样回传 `params.cursor`。`params={cursor:'bogus-cursor'}` → JSON-RPC
  `{"code":-32600,"message":"invalid cursor: bogus-cursor"}` —— **坏 cursor 是硬错误，不是「没有下一页」**，
  分页循环若把它当终止条件就会「只取第一页就判模型不存在」（正是 §5.2 L2 明令禁止的失败模式）。
- `includeHidden:true` → 7 条；默认 → 5 条（隐藏条目默认被排除）。真实目录里
  `gpt-6-astra`(isDefault=true, default=low, 支持 low/medium/high/xhigh/max/ultra)、
  `gpt-5.6-sol`、`gpt-5.6-terra`(default=medium)、`gpt-5.6-luna`(无 ultra)、
  `gpt-5.5`(只有 low/medium/high/xhigh)。**各模型支持的思考等级确实不同 ⇒ L3 是真校验，不是形式。**
- `account/read` → `{account:{type,email,planType}}` 含 **PII 邮箱** ⇒ 不进入 Profile 路径，永不落盘。
- **服务端会插发通知**（实测 `{"method":"remoteControl/status/changed",...}`）夹在响应之间：
  任何新调用方必须按 `id` 匹配，不能「读下一行」。生产里 `Wait-AppServerResponse` 的
  id 不等则 `continue` 已经处理了这点，抽层时要保留。
- 本机 codex 包内 **不附带任何协议/JSON schema 文件**，实测是唯一可靠的发现路径。

结论：CQK-037/038 不再依赖假设，mock 夹具按上面的真实形状（含对象数组思考等级、数字 cursor、
hidden 条目）来写，仓库内仍然不出现任何静态模型白名单。

## CQK-038 实现期得出的解析语义（2026-09-11，本人实现结论，非外部内容）

- **一次解析 = 一个 app-server 会话**：`config/read` 与 `model/list` 共用同一子进程，否则
  §6.2「与真正 `codex exec` 相同环境」无法成立。可测性靠 mock 在 `initialize` 时往
  `CQK_MOCK_SESSIONS_FILE` 追加一行来证明，而不是靠读代码信任。
- **Profile 路径没有代理直连回退**，这与额度读路径**故意相反**。额度读回退只是换个网络出口；
  Profile 回退会替「另一个环境」答题，再拿这个答案去给 exec 放行 —— 比读不到更糟。
- **hidden == 已退役，判 INVALID 但理由不同**。「不在目录」和「在目录但 hidden」是同一个 verdict、
  两种修法（改 typo vs 换模型）。客户端因此总是带 `includeHidden:true` 再判。
- **条目缺 `supportedReasoningEfforts` → UNAVAILABLE / `SCHEMA_UNKNOWN`，不是 VALID**。
  §21 的 fail-closed 读法：不声明能力的目录证明不了任何事。
- **`retryable` 只由 `Get-CodexErrorRetryable` 从 `errorKind` 推出**（§11 唯一实现点）：
  `PROFILE_INVALID` 永远 false（同一目录下次还是同一答案），`PROFILE_UNAVAILABLE` 通常 true
  但「是否真重试」由上层策略决定 —— §11 里 Runtime 对 UNAVAILABLE 要 fail closed。
- **§14.1 缓存是 7 键白名单投影**（`effectiveModel` / `effectiveReasoningEffort` / `modelProvider` /
  `modelSource` / `reasoningEffortSource` / `validation` / `validatedAt`）。不含 configured*、不含
  validationReason、不含 errorKind/retryable、不含目录。测试用「投毒 hashtable」证明投影不信任输入。
- **运营陷阱（会反复咬人）**：`catalog-timeout` / `timeout` 夹具 `Start-Sleep -Seconds 120`。
  残留 mock 进程会抢走子进程 spawn，让**完全无关**的测试组报 `TIMEOUT`/`UNAVAILABLE`。
  查残留要用 `Get-CimInstance Win32_Process` 且**按 `Name` 过滤 + 排除自身 PID**：探测命令自身
  含 `mock-appserver`（Git 的 bash 包装也含），否则「查到 1 个」是假的；再核 `CreationDate` 年龄。
- **扫描器会扫测试文件自己**：测试里想放一个「长得像 token」的假值，必须**拼接构造**
  （`'sk-' + 'should-never' + '-be-written'`），否则 `sk-[A-Za-z0-9_\-]{20,}` 直接把
  `secret-scan.test.ps1` 打挂。`secret-scan.test.ps1` 早就遵守这条，新测试撞上去才发现。

## CQK-039 门禁接线期得出的结论（2026-09-11，本人实现结论，非外部内容）

- **`Test-ConfigShape` 自带 `codex.queryTimeoutSeconds >= 5` 硬下限**（common.ps1 L1 规则）。
  这直接决定了「armed 配置 + 故意写坏模型」这类测试**不可能跑得比 5s 更快**：把 timeout 调成 2s
  不会让门禁更快失败，而是让配置在 L1 就被判「格式非法」，`Load-Config` 阶段就 return，
  **Profile 门根本不会执行**。表现是 `$blocked.profile` 为 `$null`、后面几条断言连坏 —— 一个
  典型的「假绿/假红互串」。因此测试夹具默认 `-Timeout 5`，并在构造函数里 **fail-fast**：
  `Test-ConfigShape` 一有 issue 就 `throw "New-ArmedCfg produced an L1-invalid config"`，
  避免将来 L1 规则变化时，格式问题又一次伪装成 Profile 判定。
- **`issues` 与 `warnings` 必须是两个列表**：本仓库里任何非空 `issues` 都等价于 `ok=$false`。
  若把 MonitorOnly 的模型笔误塞进 `issues`，就等于把「只读安装」变成不可安装 —— 正是 §7
  门禁表明确禁止的那一格。门禁用 `$Stage`（Install/Apply）在文案里区分「任务未注册」与
  「既有计划任务保持不变」，因为两者对操作者的含义不同。
- **「Apply 失败不得改动既有计划任务」是免费的，前提是顺序对**：`Register-KeeperTask` 是对
  live 任务的 read-modify-write，**没有回滚**。所以唯一安全次序是门禁在两次 Register 调用
  **之前**返回；这样「部分更新」状态在设计上不可能出现，测试也只需断言 live 任务的
  interval/Description 仍是旧值即可，不需要 uninstall/re-register 往返。
- **UNAVAILABLE 不写 cache**（VALID 与 INVALID 都写）。读失败对 Profile 一无所知，把上一次
  真实 verdict 覆盖掉会让离线面板**撒谎**。这条是 §14.1「缓存只存最后一次安全值」的必然推论。
- **§14.1 缓存恰好 7 个白名单键 ⇒ §14 面板里的 支持思考等级 / 等级校验 / 校验原因
  根本不可能来自缓存**，只能来自 `-Live`（`supportedReasoningEfforts` / L3 结论 /
  `validationReason` 都不在投影里，§23 也不允许进）。CQK-046 实现时必须按「离线面板少三行」
  设计措辞，而不是留空或猜值 —— 这是本 ticket 提前撞到的边界。
- **`docs/` 也在 `tests/secret-scan.ps1` 扫描范围内**：progress.md 里一句「避免写 token 字面量」
  的说明只要**原文引用**了 token 形状字符串，就会把全仓扫描打挂。结论：**规划笔记本身也要脱敏**，
  描述凭据形状时用文字而不是字面量。
