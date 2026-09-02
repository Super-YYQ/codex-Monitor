# Codex Monitor

用户级 Codex（ChatGPT 套餐）额度监控与多机互斥工具。按固定周期通过官方 `codex app-server` 读取额度状态，用专用 Private Git 仓库实现跨机器单 Leader 协调，并把净化后的额度/事件日志写入本地 JSONL + 可选的远程不可变 history 用于审计。

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

1. 需要 Windows 10/11、PowerShell 7（入口兼容 Windows PowerShell 5.1）、
   可运行的 Codex CLI 或 Desktop 且当前用户已登录。
   **建议先把 `codex-quota-keeper` 整个目录复制到固定部署目录**（如 `D:\Tools\codex-quota-keeper`）
   再继续——计划任务绑定安装路径，且 `runtime/` 数据与机器身份随部署目录走；
   不要在源码 Git 仓库里直接运行（虽然 `runtime/`、`config.json`、`history/` 已被
   `.gitignore` 忽略不会污染仓库，但源码更新/回退仍会干扰运行中的副本）。
2. 打开部署目录，复制 `config.example.jsonc` 为 `config.json`——模板是 JSONC（带中文注释，
   编辑器按 JSONC 渲染无报错），取消注释即可自定义，未配置的字段使用内置默认值（完整字段表见下方「配置」章节）。
3. 双击 `install.cmd`（安装前先做一次只读 quota probe，通过后注册当前用户计划任务，**无需管理员**）。
4. 双击 `status.cmd`，确认 `Task installed=YES`、`Enabled=YES`、`Codex CLI=READY`。
5. 改完配置后双击 `apply-config.cmd` 生效；卸载双击 `uninstall.cmd`（本地历史默认保留）。
6. 多机模式：准备一个专用 Private Git 仓库，在每台机器执行
   `pwsh scripts/setup-log-repo.ps1 -RepoPath <日志仓库路径>` 完成绑定，再把
   `config.json` 的 `github.coordination.enabled` 与 `github.historySync.enabled` 置为 `true`（默认关闭）。

---

## 配置（`config.json` 在哪改、怎么改）

配置文件是 `codex-quota-keeper/config.json`（从 `config.example.jsonc` 复制而来）。
**模板与运行时配置都支持 JSONC**（`//` 行注释与 `/* */` 块注释；字符串里的 `//` 如代理 URL 不受影响），
模板中每个字段都附中文说明，取消注释即可自定义。注意：`config.json` 是 `.json` 后缀，
部分编辑器会按严格 JSON 把注释标红——可删除注释行，或把该文件的语言关联改为 JSONC/JSON with Comments。
**改完任意字段后双击 `apply-config.cmd`**，它会校验配置并更新 Windows 计划任务
（轮询周期与启动条件）。幂等，可反复执行。

### 定时 / 轮询

| 字段 | 默认 | 说明 |
|------|------|------|
| `poll.intervalMinutes` | `60` | **额度轮询周期（分钟）**，即计划任务的重复间隔；必须 ≥ `minimumIntervalMinutes`（低于 5 会被拒绝） |
| `poll.minimumIntervalMinutes` | `5` | 允许的最小间隔下限（验证用） |
| `task.name` | `CodexQuotaKeeper.Check` | Windows 计划任务名 |
| `task.startWithWindows` | `true` | 开机自启 |
| `task.runIfNetworkAvailable` | `true` | 仅在有网络时运行 |
| `task.wakeToRun` | `false` | 是否允许唤醒计算机执行 |

> **触发节奏**：任务以「安装时刻 +1 分钟」为锚点（`-Once` 触发器），按 `poll.intervalMinutes`
> 重复；`startWithWindows=true`（默认）另加登录触发；关机错过的周期由 `StartWhenAvailable`
> 在可运行时补跑。改配置执行 `apply-config.cmd` 会重注册任务，锚点重置为当时 +1 分钟。
> 安装时的一次性只读 quota probe 不算轮询（不保存状态），首次正式运行是 first observation，
> 空历史下不产生事件。

### 多机协调（Leader 租约）

| 字段 | 默认 | 说明 |
|------|------|------|
| `leader.enabled` | `true` | 是否启用单 Leader 租约**机制**（机制层；多机互斥还需 `github.coordination.enabled=true`） |
| `leader.label` | `Home PC` | 本机标签（便于在 status/审计里区分机器） |
| `leader.leaseTtlMinutes` | `45` | 租约 TTL（≈轮询周期 3 倍） |
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
| `codex.autoAnchor.keepaliveIntervalMinutes` | `300` | 空闲**兜底**触发间隔（分钟）：存在首次锚定后，距上次锚定超过该值仍未观测到窗口重置即由 keeper 再触发一次（默认 = 一个 5 小时窗口）；`0` = 关闭兜底（空闲判定与重置触发仍生效） |
| `codex.autoAnchor.anchorOnApply` | `false` | **立即触发 CLI**：设为 `true` 后，每次运行 `install.cmd` / `apply-config.cmd` 都立刻强制执行一次锚定（不等 300 分钟静默期、不受最小间隔限制；仍受每日上限与 fail-closed 约束，同一分钟内的重复请求只执行一次） |
| `codex.autoAnchor.schedule` | `[]` | **每日定时模式（与周期判断互斥）**：`"HH:mm"` 数组（本地时间、24 小时制、必须补零）。配置任意槽位即切换为纯定时模式——每个时间点后的第一次轮询触发一次 CLI，不做重置/空闲/兜底判断，重置事件被忽略；清空数组回到周期判断模式（重置/空闲/兜底生效）。同一时间点每天最多一次，不受静默期限制（仍受每日上限与 fail-closed 约束） |

> **关于模型与思考等级**：keeper 从不指定模型或推理等级——额度读取是 app-server 的
> `account/rateLimits/read` 协议方法，**不调用模型**；AutoAnchor 的 `codex exec` 不带
> `--model` / 推理等级参数，完全沿用你本机 Codex CLI 的默认配置（`~/.codex/config.toml`
> 的 `model` / `model_reasoning_effort` 等），所以这里没有也不应有对应配置项。
> 若 codex CLI 默认模型指向 gpt-5 类主力模型，AutoAnchor 即按该模型发送。

> 配置 schema 标注为 v2；旧版平铺键（如 `pollIntervalMinutes`、`github.repoPath`）会
> 在加载时自动迁移，无需手工改写。

---

## 多机协调（单 Leader）

> 租约抢占/接管、集群退避、history 推送的逐分钟模拟数据见 **[docs/scenarios.md](docs/scenarios.md)**。

- 每台机器一个随机 `machineId`（不用 MAC / 序列号）。
- 租约在 Private 仓库的 `cqk/coordination` 分支；Git push 冲突作为 CAS，
  任意时刻最多一个 Leader 查询额度。
- 集群级 Global Backoff：任何机器遇到 429/认证错误后，其余机器接管也不会绕过退避。
- 日志仓库必须专用：`setup-log-repo.ps1` 写入 marker（repoId）+ origin 指纹绑定，
  推送前校验，main/master 等业务分支名被强制拒绝。

## AutoAnchor（实验，默认关闭）

> 每种触发场景的完整时间线模拟（真实格式的状态快照、事件文件、守卫拒绝原因、Mermaid 图）
> 见 **[docs/scenarios.md](docs/scenarios.md)**。

触发方式（真正调用 Codex CLI 模型）。**两种模式互斥，按需二选一**：

**模式 A：周期判断模式（`schedule` 为空，默认）**——由 keeper 判断何时该锚定：

1. **窗口重置触发**：检测到额度窗口重置后，自动发送一个无业务意义的最小 Prompt
   以锚定下一轮窗口（需要你先使用过 Codex）。
2. **空闲判定触发（从没启动过 Codex 的场景）**：keeper 从未锚定过，且第二次轮询记录
   （默认 60 分钟一轮）仍是零用量时，判定"Codex 没人用"，自动执行一次 CLI 调用；
   随后 5 小时静默（`minimumGapMinutes` 默认 300），要等窗口真正滚动才会再次触发。
3. **空闲兜底触发（keepalive，默认 300 分钟）**：存在首次锚定后，连续 5 小时仍未观测到
   任何重置（也没人使用 Codex），keeper 再自触发一次；`0` = 关闭兜底。

**模式 B：每日定时模式（`schedule` 非空）**——不做任何判断，到点就打：

4. **每日定时（schedule）**：`codex.autoAnchor.schedule`（如 `["09:30","21:00"]`）时，
   每个时间点后的第一次轮询触发一次 CLI——固定时刻、纯定时，重置/空闲/兜底判断全部
   停用、重置事件被忽略；也不需要你使用过 Codex。同一时间点每天最多一次。

**立即触发（anchorOnApply）不属于模式，任何模式下都可用**：`codex.autoAnchor.anchorOnApply=true`
时，每次运行 `install.cmd` / `apply-config.cmd` 后会立刻强制执行一次锚定——"现在就来一次"，
不等静默期、不需要重置、也不需要你本人使用 Codex。

- **官方未明确背书该用途**；OpenAI《使用条款》对"规避限制"存在解释风险，本项目不承诺零风控。
- 默认 `codex.autoAnchor.enabled=false`，安装器不会自动开启。
- 开启后仍有完整约束：每日上限、最小间隔、429/认证/未知 schema/远程不可达一律 fail-closed；
  多机（配置了协调仓库）另有分布式 CAS Claim（同一事件全局最多一次副作用）与执行前租约重验证；
  **单机（未配置协调仓库）同样可用**——本地 runner 锁 + state 去重保证至少一次副作用语义。
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
pwsh tests/run-all.ps1

# Windows PowerShell 5.1
powershell -ExecutionPolicy Bypass -File tests/run-all.ps1
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
- [docs/scenarios.md](docs/scenarios.md) — 场景详解：每个处理场景的真实模拟数据与图
- [docs/architecture.md](docs/architecture.md) — 模块与数据流
- [docs/operations.md](docs/operations.md) — 部署、多机与日常运维
- [docs/security-model.md](docs/security-model.md) — 安全边界与隐私设计
- [docs/findings.md](docs/findings.md) — 开发发现与决策记录
- [docs/progress.md](docs/progress.md) — 实现进度
- [docs/task_plan.md](docs/task_plan.md) — 开发任务计划
- [SECURITY.md](SECURITY.md) — 漏洞报告与安全策略
- [CHANGELOG.md](CHANGELOG.md) — 版本历史与升级说明

## License

[MIT](LICENSE) © 2026 Super-YYQ