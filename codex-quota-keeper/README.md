# Codex Quota Keeper

Windows 上按周期读取 Codex（ChatGPT 计划）额度状态、跨多台电脑做单 Leader 互斥、
双击即可查看状态、可选同步到 Private GitHub 用于审计的工具。

> ⚠️ **默认 MonitorOnly**：只读取官方 app-server 的额度状态、记录日志、做多机互斥，
> **不会**发起任何模型调用。`AutoAnchor` 是实验功能，默认关闭，见下文第 6 节风险说明。

## 设计原则

- **官方能力优先**：只调用 Codex 官方 app-server 的 `account/rateLimits/read`，不解析
  `auth.json`、不抓 ChatGPT 网页、不伪造客户端身份。
- **零常驻 UI**：没有托盘/后台进程。Windows Task Scheduler 到点拉起 `runner.ps1`，跑完退出；
  Task Manager 平时看不到 keeper 进程是正常现象。
- **单主机执行**：多台电脑通过 Private GitHub 仓库的租约（`coordination/lease.json`）互斥，
  任意时刻最多一个 Leader。
- **可审计**：本地 JSONL + 可选 GitHub `history/` 保存净化后的额度/事件日志。
- **默认保守合规**：默认只读；触发模型调用的能力一律实验/关闭。

## 非目标

不监控 Tibo/X；不抓网页；不修改 Codex 安装文件；不上传账号凭证（`auth.json`/token/会话）；
不绕过服务端限流。

## 目录结构

```
codex-quota-keeper/
  status.cmd       双击查看状态（唯一日常入口）
  install.cmd      安装入口
  uninstall.cmd    卸载入口
  apply-config.cmd 修改配置后应用
  config.example.jsonc
  scripts/         实现脚本
  runtime/         gitignored（machine.json / state.json / lock / logs）
  history/         净化日志（可选 Git 同步）
  tests/           单元测试（mock app-server，无需真实凭证）
```

## 快速开始

1. 解压到固定目录（**不要放在源码 Git 仓库里**，避免与源码更新互相干扰），例如 `D:\Tools\codex-quota-keeper`。
2. 复制 `config.example.jsonc` 为 `config.json`——模板是 JSONC（支持 `//` 与 `/* */` 注释，
   每项带中文说明），取消注释即自定义，未配置字段用内置默认值；按需改
   `poll.intervalMinutes`、`leader.label`、`github.coordination.repoPath`（完整字段见下方「配置」）。
3. 确保 `mode=MonitorOnly`、`codex.autoAnchor=false`。
4. 运行 `install.cmd`（会做一次只读 quota probe，成功后注册 Windows 计划任务）。
5. 双击 `status.cmd` 验证 `Task installed=YES`、`Enabled=YES`、`Auth=READY`。
6. 第二台电脑重复安装，确认只有一台 `LEADER`、另一台 `PASSIVE`。

**更新升级**：仓库更新后，把新版本文件**合并覆盖**到部署目录（务必保留 `config.json`、
`runtime/`——含机器身份 `machine.json`，多机租约依赖它——与 `history/`），再运行一次
`install.cmd`；它用 `-Force` 同名替换任务定义，**不会产生多个计划任务**
（前提是 `task.name` 没改；改名会残留旧任务）。新版本新增的配置项以注释形式出现在
`config.example.jsonc` 里，不添加也能运行（走默认值），需要再取消注释 + `apply-config.cmd`。

## 配置（修改与生效）

配置文件是 `config.json`（改前先备份）。**改完任意字段后运行 `apply-config.cmd`**，
它会校验配置并更新 Windows 计划任务的轮询周期；可反复执行、幂等。

定时相关字段（计划任务由它们驱动）：

| 字段 | 默认 | 说明 |
|------|------|------|
| `poll.intervalMinutes` | 60 | 额度轮询周期（分钟），>= `minimumIntervalMinutes`（低于 5 拒绝） |
| `poll.minimumIntervalMinutes` | 5 | 最小间隔下限 |
| `task.name` | CodexQuotaKeeper.Check | 计划任务名 |
| `task.startWithWindows` | true | 开机自启 |
| `task.runIfNetworkAvailable` | true | 仅在有网络时运行 |
| `task.wakeToRun` | false | 是否允许唤醒执行 |

> **计划任务节奏**：注册时以「当前时刻 +1 分钟」为锚点创建 `-Once` 触发器，之后每
> `poll.intervalMinutes` 重复一次（不绑定整点，如 14:37 安装 → 14:38、15:38、16:38…）；
> 重复时长固定 10 年（等效无限）。`startWithWindows=true`（默认）会另加一个登录时触发；
> 关机错过的周期因 `StartWhenAvailable=true` 会在可运行时立即补跑。
> 改配置后 `apply-config.cmd` 会重注册任务，把锚点重置为「当时时刻 +1 分钟」。
> 另外安装本身会先做一次只读额度探测（不保存状态、不算轮询）；计划任务的首次正式运行
> 才是第一轮（空历史 = first observation，不会产生事件，所以窗口重置检测最早第二轮才可能发生）。

其它常用字段：

| 字段 | 默认 | 说明 |
|------|------|------|
| `mode` | MonitorOnly | 运行模式（MonitorOnly / AutoAnchor） |
| `leader.label` | Home PC | 本机标签 |
| `leader.leaseTtlMinutes` | 45 | 租约 TTL |
| `github.coordination.repoPath` | — | 专用日志仓库本地路径（多机必填） |
| `github.historySync.push` | true | history 分支推送开关 |
| `logging.includeMachineLabel` | false | 隐私开关：machineLabel 是否进 history |
| `codex.proxy` | （空） | codex 出入站代理 URL，如 `http://127.0.0.1:7890`、`socks5://127.0.0.1:7891`（空 = 直连） |
| `codex.autoAnchor.enabled` | false | 实验功能开关（默认关闭） |
| `codex.autoAnchor.keepaliveIntervalMinutes` | 300 | 空闲**兜底**间隔（分钟）：存在首次锚定后，距上次锚定超过该值仍未观测到窗口重置即再触发一次（默认 = 一个 5 小时窗口）；`0` = 关闭兜底（空闲判定与重置触发仍生效） |
| `codex.autoAnchor.anchorOnApply` | false | **立即触发 CLI**：设为 `true` 后，每次运行 `install.cmd` / `apply-config.cmd` 都立刻强制执行一次锚定（不等 300 分钟静默期、不受最小间隔限制；仍受每日上限与 fail-closed 约束，同一分钟内的重复请求只执行一次） |
| `codex.autoAnchor.schedule` | `[]` | **每日定时模式**：`"HH:mm"` 数组（本地时间、24 小时制、必须补零）。每个时间点后的第一次轮询触发一次 CLI——纯定时，不判断重置/空闲场景；同一时间点每天最多一次，不受静默期限制（仍受每日上限与 fail-closed 约束）；空数组 = 关闭 |

## 前置条件

- Windows 10/11；建议 PowerShell 7（入口层兼容 Windows PowerShell 5.1）。
- Codex Desktop 或 Codex CLI 至少一种能提供可运行的 app-server，且当前用户已完成登录。
- 若开启多机互斥/远程日志：准备专用 Private GitHub 仓库，并配置可访问的 Git 凭证。
- 无需 Codex Desktop 常驻。

## 多电脑互斥（Leader Lease）

每台机器生成一个随机 `machineId`（不用 MAC/序列号）。任务运行后 `git fetch` 远程协调分支读取
`coordination/lease.json`：

- 租约未过期且 owner 不是自己 → `PASSIVE`（不查 Codex、不 AutoAnchor）。
- 租约过期或 owner 是自己 → 续租后 `push`。
- 两台同时抢占时，Git `non-fast-forward` 冲突作为 CAS：先 push 成功者为 Leader。

多机互斥相关参数（见 `config.json` 的 `leader` / `github.coordination` 段）：

| 参数 | 默认 | 说明 |
|------|------|------|
| `leader.leaseTtlMinutes` | 45 | 租约 TTL（≈轮询周期 3 倍） |
| `leader.graceMinutes` | 5 | 时钟漂移/网络延迟容忍 |
| `leader.takeoverOnExpiry` | true | 过期后允许他人接管 |
| `github.coordination.enabled` | false | 租约协调（默认关闭 = 单机 LOCAL_ONLY；多机先 setup-log-repo 再开启，false 时多机不安全） |
| `github.coordination.repoPath` | — | 专用日志仓库本地路径 |

`leader.enabled`（机制层：是否启用单 Leader 租约）与 `github.coordination.enabled`（传输层：
是否经专用仓库做跨机器协调）是两个独立层级，**任一为 false 即 LOCAL_ONLY**（本机始终
Leader，不碰远端租约）。多机 = 两个都 `true`；单机默认 = `leader.enabled=true` + 协调关。

## 状态机

```
DISABLED  任务被禁用
PASSIVE   其他机器持有租约
LEADER    持有租约，正常轮询
DEGRADED  本地可查但 Git 租约/日志不可用
AUTH_ERR  Codex 认证不可用
BACKOFF   429 / 瞬时故障，等待后重试

AutoAnchor（实验）:
RESET_SEEN -> 幂等守卫(eventId) -> ANCHORING -> VERIFY -> ANCHORED
                    | error -> ABORTED
（空闲判定 / 空闲兜底 / 每日定时 schedule 与 anchorOnApply 强制触发走同一链路：触发原因 = 二次观测仍无人使用 / 空闲超时 / 定时到点 / 用户显式请求，不需要 RESET_SEEN）
```

## AutoAnchor 风险说明（实验，默认关闭）

触发方式（都执行真正的 `codex exec` 模型调用）：

1. **窗口重置触发**：检测到额度窗口重置后，自动发送一个无业务意义的最小 Prompt（如
   `Reply exactly OK.`）以提前锚定下一轮额度窗口（需要你先使用过 Codex）。
2. **空闲判定触发（从未使用过 Codex 的场景）**：keeper 从未锚定过（`anchors.count=0`）、
   第二次轮询记录仍是零用量（默认 60 分钟一轮，即约一小时后）时，判定"Codex 没人用"，
   自动执行一次 CLI 调用——这正是"你从来没启动过 Codex，它也会触发一次"。
   随后进入 5 小时静默期（`minimumGapMinutes` 默认 300），再次触发要等窗口真正滚动。
3. **空闲兜底触发（keepalive，默认 300 分钟）**：存在首次锚定后，若连续 5 小时仍未
   观测到任何窗口重置（也没人使用 Codex），keeper 再自触发一次；设为 `0` 关闭兜底。
4. **立即触发（anchorOnApply）**：`codex.autoAnchor.anchorOnApply=true` 时，每次运行
   `install.cmd` / `apply-config.cmd` 后会立刻强制执行一次锚定——"现在就来一次"，
   不等静默期也不需要重置或你本人使用 Codex。
5. **每日定时（schedule）**：`codex.autoAnchor.schedule=["09:30","21:00"]` 时，每个时间点后的
   第一次轮询触发一次 CLI——固定时刻、纯定时，不做任何重置/空闲判断，也不要求你使用过
   Codex；适合"每天固定几点保持账户活跃"的场景（与重置/空闲/兜底触发按需组合，
   槽位去重后同一时间点每天最多一次）。

这是**实验性**行为：

- OpenAI《使用条款》禁止规避任何 rate limits / restrictions；官方未明确批准“quota keepalive/AutoAnchor”这一用途。
- **单机同样可用**：未配置协调仓库（LOCAL_ONLY）时跳过远端 CAS Claim 与租约重验证，
  以本地 runner 锁 + state 去重承担 at-most-once；配置了多机协调后自动回到分布式 Claim。
- 本项目**不保证零风控**。首次开启会显示醒目警告；默认关闭，安装器不会自动开启。
- 开启前必须满足的清单见 `docs/design/04`（单 Leader、幂等锁、每日上限、最小间隔、fail-closed 等已内置）。
- 遇到 429、usage-limit、认证异常、未知 schema 时立即 fail closed，不调用模型。
- Anchor 提示词 `codex.autoAnchor.prompt` 支持中文等 Unicode，长度上限 200 字符；仍禁用换行与
  shell 元字符（`.cmd` 安装经 cmd.exe 展开，防注入）。
- **模型与思考等级**：本项目从不指定 `--model` / 推理等级参数——额度读取走 app-server
  协议方法不调用模型；AutoAnchor 的 `codex exec` 沿用你本机 Codex CLI 的默认配置
  （`~/.codex/config.toml` 的 `model` / `model_reasoning_effort`），此处无对应配置项。

## 重试与代理

- **不无限重试**：每次运行至多一次 quota 读取（计划任务每个周期运行一次，周期由
  `poll.intervalMinutes` 决定）。未配置代理时，失败后本周期内不再重试。
- **代理**：`codex.proxy` 配置后，codex 子进程以 `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` 走代理。
  支持 `http(s)://` 与 `socks5://`/`socks5h://`（socks scheme 是否被 codex 识别取决于其自身 HTTP 栈）。
  若代理路径读取失败（任意错误类型），**自动退回直连再试一次**；两次都失败则停止，下个周期再试。
  AutoAnchor 的模型调用同样走代理，但绝不重试（at-most-once）。
- 连续失败计数（所有失败类型）记录在 `runtime/state.json` 的 `consecutiveReadFailures`，成功后清零，
  出现在 `READ_FAILED` 日志中便于观察。

## 安全边界

- `auth.json` 只留在各电脑自己的 Codex 目录，本项目不读取、不复制、不写入日志。
- GitHub 仓库建议 Private，只写净化后的额度/事件/租约数据。
- 日志 machineId 用随机 ID + 用户 label，不上传 Windows 用户名/序列号。
- 所有自动 push 只针对配置指定的专用日志仓库，绝不对用户代码仓库 push。
- Git 认证复用系统 Git Credential Manager / SSH；PAT 不写入 `config.json`。

## 测试

`tests/` 下是纯 PowerShell 断言测试，使用 mock app-server，**不需要真实 OpenAI 凭证**：

```powershell
pwsh tests/run-all.ps1
```

## 参考

- Codex app-server README — https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md
- Using Codex with your ChatGPT plan — https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan
- How banked Codex resets work — https://help.openai.com/en/articles/20001498-how-banked-codex-resets-work
- Codex issue #39444 — https://github.com/openai/codex/issues/39444
- Codex issue #28246 — https://github.com/openai/codex/issues/28246