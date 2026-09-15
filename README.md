# Codex Monitor（仅 Windows）

当前开发分支的修复、验证范围和未关闭的发布门禁见 [产品就绪审查](docs/production-readiness.md)。

用户级 Codex（ChatGPT 套餐）额度监控与多机互斥工具。

- 按固定周期通过官方 `codex app-server` 读取额度。
- 可使用专用 Private Git 仓库，让多台电脑由一个 Leader 执行。
- 本地保存额度和事件日志，可选同步净化后的历史记录。

[![PowerShell 7 unit + integration tests](https://github.com/Super-YYQ/codex-Monitor/actions/workflows/test-windows.yml/badge.svg)](https://github.com/Super-YYQ/codex-Monitor/actions/workflows/test-windows.yml)
[![security](https://github.com/Super-YYQ/codex-Monitor/actions/workflows/security.yml/badge.svg)](https://github.com/Super-YYQ/codex-Monitor/actions/workflows/security.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> **默认 MonitorOnly**：只读额度、写日志、做互斥，**不调用模型**、不抓网页、
> 不读取 `auth.json`、不需要常驻 UI。`AutoAnchor` 是默认关闭的实验功能，见
> [AutoAnchor](#autoanchor实验默认关闭)。

---

## 它能做什么

- **读额度**：调用 Codex 官方 app-server 的 `account/rateLimits/read`（v2 多 bucket 快照），
  不解析 `auth.json`、不访问网页、不伪造客户端身份。
- **多机互斥**：多台电脑通过 Private 仓库租约实现任意时刻最多一个 Leader 查询额度，
  其余机器 PASSIVE。
- **集群退避**：任何机器遇到 429 / 认证错误后写入全局退避，其他机器接管也无法绕过。
- **可审计**：本地 JSONL 全量日志 + 可选的远程不可变 history（字段白名单、脱敏）。
- **零常驻**：由 Windows 计划任务到点拉起、跑完即退，无托盘、无后台进程。

## 不做的事

不监控任意网页/服务；不修改 Codex 安装文件；不上传账号凭证（`auth.json` / token / 会话）；
不绕过服务端限流。

---

## 目录结构

```
codex-quota-keeper/   工具本体（scripts / tests / 安装入口）
docs/                 设计交付文档（docs/design/*.docx）+ 架构 / 运维 / 安全模型与开发记录
```

---

## 快速开始

**准备环境**：Windows 10/11、PowerShell 7，以及已登录的 Codex CLI 或 Desktop。
入口兼容 Windows PowerShell 5.1。

1. **放置工具**：把 `codex-quota-keeper` 目录复制到固定部署目录，
   例如 `$env:LOCALAPPDATA\CodexQuotaKeeper`。
2. **创建配置**：复制 `config.example.jsonc` 为 `config.json`。
   模板带中文注释；未配置字段使用内置默认值。
3. **安装**：双击 `install.cmd`。只读额度探测通过后，注册当前用户计划任务，**无需管理员**。
4. **检查**：双击 `status.cmd` 查看任务、认证和额度状态。

> **部署目录要保持固定**：计划任务绑定安装路径，`runtime/` 保存机器身份和运行状态。
> 请使用源码仓库之外的目录，避免源码更新或回退影响正在运行的副本。

### 日常操作

| 操作 | 入口 |
|---|---|
| 查看状态 | `status.cmd` |
| 修改配置后生效 | `apply-config.cmd` |
| 卸载（默认保留本地历史） | `uninstall.cmd` |

### 可选：多机模式

准备专用 Private Git 仓库，在每台电脑的部署目录执行：

```powershell
pwsh scripts/setup-log-repo.ps1 -RepoPath <日志仓库路径>
```

绑定完成后，在 `config.json` 中开启 `github.coordination.enabled` 和
`github.historySync.enabled`，再运行 `apply-config.cmd`。

---

## 按场景了解触发规则

[运行场景详解](codex-quota-keeper/docs/scenarios.md) 用具体日期、时间和额度数值说明程序行为。

| 常见问题 | 对应场景 |
|---|---|
| 不开 AutoAnchor，或开启但不设置触发器 | [模式与配置组合](codex-quota-keeper/docs/scenarios.md#s01) |
| 设置 09:00，提前用过／没用过 | [每日定时](codex-quota-keeper/docs/scenarios.md#s02) |
| secondary 正常到期／提前重置 | [正常到期](codex-quota-keeper/docs/scenarios.md#s04) · [提前重置](codex-quota-keeper/docs/scenarios.md#s05) |
| 上游统一重置后，程序多久会发现 | [统一重置时间线](codex-quota-keeper/docs/scenarios.md#s06) |
| 关机、迟到、退避、每日上限、多机并发 | [查看场景导航](codex-quota-keeper/docs/scenarios.md) |

## 配置（`config.json` 在哪改、怎么改）

编辑部署目录中的 `config.json`，模板来自 `config.example.jsonc`。

- **支持注释**：`//` 行注释与 `/* */` 块注释均可；代理 URL 中的 `//` 不受影响。
- **编辑器提示**：如果注释被标红，将语言模式切换为 JSONC / JSON with Comments。
- **应用修改**：保存后双击 `apply-config.cmd`，校验配置并更新计划任务；可重复执行。

### 定时 / 轮询

| 字段 | 默认 | 说明 |
|------|------|------|
| `poll.intervalMinutes` | `60` | **额度轮询周期（分钟）**，即计划任务的重复间隔；必须 ≥ `minimumIntervalMinutes`（低于 5 会被拒绝） |
| `poll.minimumIntervalMinutes` | `5` | 允许的最小间隔下限（验证用） |
| `task.name` | `CodexQuotaKeeper.Check` | Windows 计划任务名 |
| `task.startWithWindows` | `true` | 开机自启 |
| `task.runIfNetworkAvailable` | `true` | 仅在有网络时运行 |
| `task.wakeToRun` | `false` | 请求 Windows 从睡眠/休眠唤醒；不能从关机唤醒，实际能力还受硬件与电源策略限制 |
| `task.alarmName` | `""` | 一次性到期检查任务名；空值使用 `<task.name>.AnchorAlarm` |

**后台任务如何运行**

| 触发方式 | 执行时间 |
|---|---|
| 周期轮询 | 安装时刻 +1 分钟首次执行，之后按 `poll.intervalMinutes` 重复 |
| 登录触发 | `startWithWindows=true` 时启用 |
| 每日定时 | 按 `schedule` 中的时间执行 |
| 到期检查 | 单独的一次性计划任务，在选定额度窗口到期后检查 |

> **到期检查任务在后台静默执行，不弹窗、不播放铃声。**
> 配置键 `task.alarmName` 和任务名后缀 `.AnchorAlarm` 保留兼容。

- 关机期间错过的周期，由 `StartWhenAvailable` 在可运行时补跑。
- `apply-config.cmd` 会重注册任务，将周期起点重置为当时 +1 分钟。
- 安装探测不保存状态；首次正式轮询建立基线，不产生窗口重置事件。

### 多机协调（Leader 租约）

| 字段 | 默认 | 说明 |
|------|------|------|
| `leader.enabled` | `true` | 是否启用单 Leader 租约**机制**（机制层；多机互斥还需 `github.coordination.enabled=true`） |
| `leader.label` | `Home PC` | 本机标签（便于在 status/审计里区分机器） |
| `leader.leaseTtlMinutes` | `180` | 租约 TTL；须 ≥ `max(2×轮询周期, 轮询周期 + grace + 5)`，否则租约会在一轮轮询之间过期导致 Leader 抖动 |
| `leader.graceMinutes` | `5` | 时钟漂移 / 网络延迟容忍 |
| `leader.takeoverOnExpiry` | `true` | 租约过期后允许他人接管 |

### 协调与历史仓库（GitHub）

| 字段 | 默认 | 说明 |
|------|------|------|
| `github.coordination.enabled` | `false` | 租约协调开关（默认关闭 = 单机 LOCAL_ONLY；多机时先 `setup-log-repo.ps1` 再开启，false 时多机不安全） |
| `github.coordination.repoPath` | — | 专用 Private 日志仓库本地路径（多机必填） |
| `github.coordination.branch` | `cqk/coordination` | 协调分支 |
| `github.historySync.enabled` | `false` | 是否同步净化后的 history（默认关闭，多机开启） |
| `github.historySync.push` | `true` | 是否 push history 分支 |
| `github.historySync.branch` | `cqk/history` | history 分支 |
| `github.historySync.eventsOnly` | `true` | 只同步重要事件（普通轮询零写入） |

> **`leader.enabled` 与 `github.coordination.enabled` 是两个独立层级**，不是重复开关：
> `leader.enabled` = 机制层（是否启用单 Leader 租约机制）；
> `github.coordination.enabled` = 传输层（租约是否经专用仓库做**跨机器**协调）。
> 两者**任一为 false 即进入本地模式**（LOCAL_ONLY：本机始终以 Leader 身份运行，
> 不 fetch/push 远端租约，status 会提示 MULTI-PC UNSAFE）。

| `leader.enabled` | `github.coordination.enabled` | 效果 |
|---|---|---|
| `true` | `true` | **多机互斥**（完整模式，唯一需要仓库的组合） |
| `true` | `false` | **单机默认**（LOCAL_ONLY，不碰 git） |
| `false` | `true` | 不抢租约，仅用仓库同步 history |
| `false` | `false` | 纯单机，完全不碰 git |

### 日志

| 字段 | 默认 | 说明 |
|------|------|------|
| `logging.retentionDays` | `90` | 本地日志 / history 保留天数，runner 每轮自动清理 |
| `logging.includeMachineLabel` | `false` | 隐私开关：`machineLabel` 是否写入 history |

### Codex 与 AutoAnchor

| 字段 | 默认 | 说明 |
|------|------|------|
| `codex.command` | `auto` | codex 可执行文件（`auto` 自动探测，已兼容 exe/ps1/cmd/bat / npm codex.cmd） |
| `codex.queryTimeoutSeconds` | `20` | 额度查询超时（秒） |
| `codex.proxy` | （空） | codex 出入站代理 URL（如 `http://127.0.0.1:7890`、`socks5://127.0.0.1:7891`）；空 = 直连 |
| `codex.autoAnchor.enabled` | `false` | **实验功能开关，默认关闭，安装器不会自动开启** |
| `codex.autoAnchor.prompt` | `Reply exactly OK.` | 锚定用的最小 Prompt（支持中文等 Unicode，长度 ≤ 200；仍禁用换行与 shell 元字符） |
| `codex.autoAnchor.maxPerDay` | `6` | 每日最大执行次数 |
| `codex.autoAnchor.minimumGapMinutes` | `300` | 「静默期」：两次锚定的最小间隔（分钟）；一次 CLI 调用后至少等这么久才会再触发（anchorOnApply 强制触发除外） |
| `codex.autoAnchor.anchorOnApply` | `false` | 安装或应用配置时请求立即锚定；每日本地最多实际尝试一次，不等静默期，仍受每日总上限与运行期校验约束 |
| `codex.autoAnchor.schedule` | `[]` | 每日 `"HH:mm"` 时间点；每个槽位每天最多一次，详见下方触发规则 |
| `codex.autoAnchor.anchorOnExpiry` | `[]` | 到期补空档窗口：`"primary"` / `"secondary"`；另建一次性到期检查任务 |
| `codex.autoAnchor.model` | `""` | **锚定执行的模型**：配置后传 `codex exec -m <model>`（如 `gpt-5-codex`）；留空 = 不传，沿用本机 `~/.codex/config.toml` 默认。仅允许字母/数字/`.`/`_`/`-`，1–100 字符 |
| `codex.autoAnchor.reasoningEffort` | `""` | **锚定执行的思考等级**：配置后传 `-c model_reasoning_effort=<值>` 覆盖（如 `low`）；留空 = 不覆盖，沿用 CLI 默认。小写字母开头，仅小写字母/数字/`-`，1–30 字符；合法档位随 CLI/模型演进，填错在执行时按 fail-closed 记 ABORTED |

**模型与思考等级**

- 额度读取使用 `account/rateLimits/read`，不调用模型。
- AutoAnchor 未指定模型时，沿用本机 `~/.codex/config.toml` 的配置。
- `codex.autoAnchor.model` / `reasoningEffort` 只覆盖锚定执行的配置。
- 执行前校验模型和思考等级，审计日志记录实际生效值，便于查证。

> 配置 schema 标注为 v2；旧版平铺键（如 `pollIntervalMinutes`、`github.repoPath`）会
> 在加载时自动迁移，无需手工改写。

---

## 多机协调（单 Leader）

> 两台电脑接管、退避与并发的时间线见 **[多机与故障场景](codex-quota-keeper/docs/scenarios.md#s11)**。

- 每台机器一个随机 `machineId`（不用 MAC / 序列号）。
- 租约在 Private 仓库的 `cqk/coordination` 分支；Git push 冲突作为 CAS，
  任意时刻最多一个 Leader 查询额度。
- 集群级 Global Backoff：任何机器遇到 429/认证错误后，其余机器接管也不会绕过退避。
- 日志仓库必须专用：`setup-log-repo.ps1` 写入 marker（repoId）+ origin 指纹绑定，
  推送前校验，main/master 等业务分支名被强制拒绝。

## AutoAnchor（实验，默认关闭）

> 配置组合、具体时间、额度数值与触发结果见 **[运行场景详解](codex-quota-keeper/docs/scenarios.md)**。

真正调用模型的自动触发器有两个，彼此独立、可以同时启用：

1. **每日定时（schedule）**：例如 `["08:55","13:55"]`，用于把 primary 的 5h 窗口
   对齐工作时间。计划任务到点后 runner 会重新读取额度；primary 已在运行时不会调用模型，
   该槽位仍会被消费，避免稍后补打。

2. **到期补空档（anchorOnExpiry）**：例如 `["secondary"]`，仅当选定窗口没有运行
   （到期、为空、消失或已确认空闲）时触发一次。
   独立的一次性到期检查任务在最近到期时间 +1 分钟启动 runner，成功读取后更新执行时间。

**空闲判断与去重**

- `0%` 且到期时间接近「当前时间 + 完整窗口长度」时，先等待连续观测确认时间随查询后移。
- 单次 `0%` 不足以判断空闲；定时槽位暂不消费，仍受一个轮询周期的补跑期限约束。
- 同一空闲期保留上一真实到期点，跨轮询、跨重启去重；预测时间后移不会生成新到期事件。
- 已确认空闲时不设置不断后移的到期检查任务；后续周期轮询继续检查。

重置事件仍写入审计日志，但不再触发模型；旧 `keepaliveIntervalMinutes` 会被忽略并给出迁移提示，
如需连续衔接 primary 窗口，改用 `anchorOnExpiry:["primary"]`。两个自动触发器均为空时，
即使 AutoAnchor 已 armed 也只查询额度，不会自动调用模型。

**立即触发（anchorOnApply）**

在 AutoAnchor 已启用且 `codex.autoAnchor.anchorOnApply=true` 时，运行
`install.cmd` / `apply-config.cmd` 会请求立即锚定。
每个本地自然日最多实际尝试一次，不受最小间隔限制，仍执行其他校验。

### 手动重置后的记录

旧窗口尚未到期时，如果已用比例下降或真实到期时间改变，记录
**到期前额度恢复／窗口重置**（`QUOTA_RECOVERED_EARLY`）。

| 记录内容 | 字段 |
|---|---|
| 额度桶与窗口 | `quotaChange.bucketId`、`windowType` |
| 前后已用比例 | `previousUsedPercent`、`usedPercent` |
| 前后到期时间 | `previousResetsAt`、`resetsAt` |
| 恢复原因 | `reason=unknown`，额度快照本身不能证明使用了重置卡 |

事件写入本地运行日志、历史记录和待同步记录，并计入每日汇总。
工具采用新的额度状态和到期时间；恢复事件本身不会触发模型调用。

> 每小时采样可能错过「用完 → 重置 → 继续使用」的中间瞬间。
> 日志反映两次成功读取之间的变化，不会补造充值操作或精确发生时间。

### 执行约束

- **官方未明确背书该用途**；OpenAI《使用条款》对"规避限制"存在解释风险，本项目不承诺零风控。
- 默认 `codex.autoAnchor.enabled=false`，安装器不会自动开启。
- 开启后仍有完整约束：每日上限、expiry 最小间隔、429/认证/未知 schema/远程不可达一律 fail-closed；
  多机（配置了协调仓库）另有分布式 CAS Claim（同一事件全局最多一次副作用）与执行前租约重验证；
  **单机（未配置协调仓库）同样可用**——本地 runner 锁、持久 Claim 和 state 去重共同限制同一事件最多一次调用；结果不确定时不重试。
- 每次执行的 before/after 额度快照写入 history，便于审计。

---

## 支持矩阵

| 平台 | 版本 |
|------|------|
| Windows | 10 / 11 |
| PowerShell | 7.x（推荐），5.1（入口与测试兼容） |
| Codex | CLI 或 Desktop 提供的 app-server（npm 安装的 codex.cmd 支持） |
| Git | 任意现代版本（Credential Manager / SSH） |

---

## 运行测试

测试是纯 PowerShell 断言 + mock app-server，**无需真实 OpenAI 凭证**：

```powershell
# PowerShell 7
pwsh codex-quota-keeper/tests/run-all.ps1

# Windows PowerShell 5.1
powershell -ExecutionPolicy Bypass -File codex-quota-keeper/tests/run-all.ps1
```

CI（GitHub Actions）在每次 push / PR 上运行：PS 7 与 PS 5.1 全量测试、官方 schema
契约测试、PSScriptAnalyzer、秘钥扫描。

---

## Troubleshooting

| 现象 | 处理 |
|------|------|
| Task NOT FOUND | 重新运行 `install.cmd`；确认当前 Windows 用户 |
| LastResult != 0 | 查看 `codex-quota-keeper/runtime/logs`；手动 `pwsh scripts/runner.ps1 -Verbose` |
| AUTH ERROR | 先在 Codex CLI/Desktop 重新登录，再 `status.cmd --live` |
| PASSIVE unexpectedly | 查看远程 lease owner/expiry；等待 TTL 到期接管，不要手工删 lease |
| DEGRADED (Git) | 检查日志仓库 fetch/push 凭证；确认 `setup-log-repo.ps1` 已执行 |
| SCHEMA_UNKNOWN | Codex 协议可能升级；先回 MonitorOnly 等待适配版本 |
| codex.cmd 启动失败 | 确认 `codex.command` 指向可执行文件；launcher 已兼容 exe/ps1/cmd/bat |

---

## 文档

- [docs/design/](docs/design/) — 中文设计交付文档（合规调研、总体架构、详细设计、部署运维、仓库审查）
- [运行场景详解](codex-quota-keeper/docs/scenarios.md) — 12 类场景：配置组合、具体数值、处理时间与跳过原因
- [docs/soak-runbook.md](docs/soak-runbook.md) — 双机 soak + 故障注入操作单（发布前 DoD）
- [docs/architecture.md](docs/architecture.md) — 模块与数据流
- [docs/operations.md](docs/operations.md) — 部署、多机与日常运维
- [docs/security-model.md](docs/security-model.md) — 安全边界与隐私设计
- [docs/findings.md](docs/findings.md) — 开发发现与决策记录
- [docs/review-2026-09-13.md](docs/review-2026-09-13.md) — 项目审查：触发模型、架构、缺陷、安全与优化建议
- [docs/design/autoanchor-trigger-redesign-design-v1.0.md](docs/design/autoanchor-trigger-redesign-design-v1.0.md) — AutoAnchor 触发模型重设计开发设计说明书（依据 review-2026-09-13，工作项 CQK-049~064）
- [docs/progress.md](docs/progress.md) — 实现进度
- [docs/task_plan.md](docs/task_plan.md) — 开发任务计划
- [SECURITY.md](SECURITY.md) — 漏洞报告与安全策略
- [CHANGELOG.md](CHANGELOG.md) — 版本历史与升级说明

## License

[MIT](LICENSE) © 2026 Super-YYQ
