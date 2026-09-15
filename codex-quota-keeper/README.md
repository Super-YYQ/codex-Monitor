# Codex Quota Keeper

Windows 上按周期读取 Codex（ChatGPT 计划）额度状态、跨多台电脑做单 Leader 互斥、
双击即可查看状态、可选同步到 Private GitHub 用于审计的工具。

> ⚠️ **默认 MonitorOnly**：只读取官方 app-server 的额度状态、记录日志、做多机互斥，
> **不会**发起任何模型调用。`AutoAnchor` 是实验功能，默认关闭，见下文 AutoAnchor 说明。

## 设计原则

- **官方能力优先**：通过 Codex app-server 的 `account/rateLimits/read` 读额度，使用
  `config/read` 与 `model/list` 校验执行配置，不解析
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
  runtime/         gitignored（machine.json / state.json / lock / logs / backoff.json /
                   pending-global-backoff.json / anchor-claims/）
  history/         净化日志（可选 Git 同步）
  docs/scenarios.md 触发场景与数值时间线
  tests/           单元测试（mock app-server，无需真实凭证）
```

## 快速开始

### 安装

1. 获取工具，两种方式任选：
   - **GitHub Release（推荐）**：从 Releases 页下载 `codex-quota-keeper-v<版本>.zip` 与
     `SHA256SUMS.txt`，先校验再解压：

     ```powershell
     # GNU sha256sum（WSL / Git Bash）或本仓库 tools/build-release.ps1 -VerifyOnly 均可
     sha256sum -c SHA256SUMS.txt
     ```

   - **从源码仓库**：clone 后直接使用 `codex-quota-keeper/` 目录（打包流程见
     `docs/release-engineering.md`）。
2. 解压到当前用户私有的固定目录（**不要放在源码 Git 仓库里**），例如 `$env:LOCALAPPDATA\CodexQuotaKeeper`。
3. 复制 `config.example.jsonc` 为 `config.json`。模板支持注释，未配置字段使用默认值。
4. 确保 `mode=MonitorOnly`、`codex.autoAnchor.enabled=false`。
5. 运行 `install.cmd`（会做一次只读 quota probe，成功后注册 Windows 计划任务）。
6. 双击 `status.cmd` 验证 `Task installed=YES`、`Enabled=YES`、`Auth=READY`。
7. 第二台电脑重复安装，确认只有一台 `LEADER`、另一台 `PASSIVE`。

### 查看状态

日常双击 `status.cmd`，使用本地缓存，只读查看状态。
需要参数时直接调脚本 `pwsh scripts/status.ps1 <参数>`：

| 参数 | 作用 |
|------|------|
| `-Live` | 追加一次真实的只读额度查询（默认只读本地记录与计划任务，不查 Codex） |
| `-Detailed` | 末尾追加「调试详情」区：原始判定值、额度时间、仓库路径与全部 finding 明细 |
| `-Language en-US` | 输出 v2.0 之前的英文事实转储（默认中文面板；`status-json.ps1` 的英文 schema 不受影响） |
| `-NoColor` | 去掉颜色、内容不变（重定向到文件时用） |
| `-KeeperRoot` / `-ConfigFile` | 指向非默认安装目录 / 非默认配置文件 |

常用诊断命令：

```powershell
# 刷新额度并校验执行模型
status.cmd -Live --no-pause

# 查看详细状态
pwsh scripts/status.ps1 -Detailed
```

无效模型或思考等级在执行前被拒绝，不计入每日调用次数。
修改配置后先运行 `apply-config.cmd`，再用 `-Live` 核验。

### 更新升级

1. 将新版本文件**合并覆盖**到部署目录。
2. **保留** `config.json`、`runtime/` 和 `history/`。
   `runtime/machine.json` 保存机器身份，多机租约依赖它。
3. 再运行一次 `install.cmd`，更新计划任务定义。
4. 如需使用新增配置项，从 `config.example.jsonc` 复制到配置中，再运行 `apply-config.cmd`。

> `task.name` 不变时会替换同名任务。修改任务名称会留下旧任务，需要单独处理。
> 未添加的新配置项使用默认值。

## 按场景了解触发规则

[运行场景详解](docs/scenarios.md) 用具体日期、时间和额度数值说明程序行为。

| 常见问题 | 对应场景 |
|---|---|
| 不开 AutoAnchor，或开启但不设置触发器 | [模式与配置组合](docs/scenarios.md#s01) |
| 设置 09:00，提前用过／没用过 | [每日定时](docs/scenarios.md#s02) |
| secondary 正常到期／提前重置 | [正常到期](docs/scenarios.md#s04) · [提前重置](docs/scenarios.md#s05) |
| 上游统一重置后，程序多久会发现 | [统一重置时间线](docs/scenarios.md#s06) |
| 关机、迟到、退避、每日上限、多机并发 | [查看场景导航](docs/scenarios.md) |

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

### 后台任务的执行时间

- **周期轮询**：安装后约 1 分钟首次执行，之后按配置间隔重复，重复时长为 10 年。
  例如 14:37 安装、间隔 60 分钟，则在 14:38、15:38、16:38 等时间执行。
- **登录触发**：`startWithWindows=true` 时启用；错过的周期在可运行时补跑。
- **每日定时**：按 `schedule` 中的时间执行。
- **到期检查**：另建一次性计划任务，在选定窗口到期后 1 分钟启动检查。

> **到期检查任务在后台静默执行，不弹窗、不播放铃声。**
> 配置键 `task.alarmName` 和默认后缀 `.AnchorAlarm` 保持兼容。

`apply-config.cmd` 会将周期起点重置为当时 +1 分钟。
安装探测不保存状态；首次正式轮询建立基线，不产生窗口重置事件。

### 其他常用配置

| 字段 | 默认 | 说明 |
|------|------|------|
| `mode` | MonitorOnly | 运行模式（MonitorOnly / AutoAnchor） |
| `leader.label` | Home PC | 本机标签 |
| `codex.queryTimeoutSeconds` | 20 | 每次协议等待的超时秒数，上限 **180**；计划任务最长执行时间由配置推导 |
| `leader.leaseTtlMinutes` | 180 | 租约 TTL（默认 ≈轮询周期 3 倍；有关系校验，见下表） |
| `github.coordination.repoPath` | — | 专用日志仓库本地路径（多机必填） |
| `github.historySync.push` | true | history 分支推送开关 |
| `logging.includeMachineLabel` | false | 隐私开关：machineLabel 是否进 history |
| `codex.proxy` | （空） | codex 出入站代理 URL，如 `http://127.0.0.1:7890`、`socks5://127.0.0.1:7891`（空 = 直连） |
| `codex.autoAnchor.enabled` | false | 实验功能开关（默认关闭） |
| `codex.autoAnchor.anchorOnApply` | false | 安装或应用配置时请求立即锚定；每个本地自然日最多实际尝试一次，仍受每日总上限和运行期校验约束 |
| `codex.autoAnchor.schedule` | `[]` | 独立的每日 `"HH:mm"` 触发器；primary 已在运行时消费槽位但不调用模型。可与 `anchorOnExpiry` 同开 |
| `codex.autoAnchor.anchorOnExpiry` | `[]` | 到期补空档窗口，可选 `"primary"` / `"secondary"`；使用一次性到期检查任务 |

## 前置条件

- Windows 10/11；建议 PowerShell 7（入口层兼容 Windows PowerShell 5.1）。
- Codex Desktop 或 Codex CLI 至少一种能提供可运行的 app-server，且当前用户已完成登录。
- 若开启多机互斥/远程日志：准备专用 Private GitHub 仓库，并配置可访问的 Git 凭证。
- 无需 Codex Desktop 常驻。

## 多电脑互斥（Leader Lease）

> 两台电脑接管、退避与并发的时间线见 **[多机与故障场景](docs/scenarios.md#s11)**。

每台机器生成一个随机 `machineId`（不用 MAC/序列号）。任务运行后 `git fetch` 远程协调分支读取
`coordination/lease.json`：

- 租约未过期且 owner 不是自己 → `PASSIVE`（不查 Codex、不 AutoAnchor）。
- 租约过期或 owner 是自己 → 续租后 `push`。
- 两台同时抢占时，Git `non-fast-forward` 冲突作为 CAS：先 push 成功者为 Leader。

多机互斥相关参数（见 `config.json` 的 `leader` / `github.coordination` 段）：

| 参数 | 默认 | 说明 |
|------|------|------|
| `leader.leaseTtlMinutes` | 180 | 租约 TTL。必须满足 `>= max(2×轮询周期, 轮询周期 + graceMinutes + 5)`，否则租约会在一轮轮询之间过期，Leader 会在两台机器间反复抖动（flapping）；配置校验会直接拒绝该组合 |
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
BACKOFF   429 / 认证故障的集群级退避

AutoAnchor（实验）:
schedule + anchorOnExpiry -> 合并事件 -> 幂等守卫/Claim -> ANCHORING -> VERIFY -> ANCHORED
                                              | error -> ABORTED
anchorOnApply 为显式强制触发；reset 只审计，不进入锚定决策。
```

## AutoAnchor 风险说明（实验，默认关闭）

> 配置组合、具体时间、额度数值与触发结果见 **[运行场景详解](docs/scenarios.md)**。

两个自动触发器独立、可同开，都会在真正执行前重新读取额度并走同一套 fail-closed 门禁：

1. **每日定时（schedule）**：例如 `["08:55","13:55"]`，用于把 primary 5h 窗口对齐
   工作时间。到点时 primary 已在运行则消费槽位但不调用模型；否则同一槽位每天最多一次。

2. **到期补空档（anchorOnExpiry）**：例如 `["secondary"]`，选定窗口不在运行才触发。
   独立的一次性到期检查任务在最近已知到期时间 +1 分钟启动 runner，runner 再校验当前快照；
   同一到期事件不会重复执行。

### 空闲窗口如何判断

- 已用比例为 `0%`，且到期时间接近「当前时间 + 完整窗口长度」时，先作为待确认状态。
- 连续读取确认到期时间随查询后移，才判定为空闲，避免把刚开始使用但显示 `0%` 的窗口误判。
- 待确认时保留定时槽位，在一个轮询周期的补跑期限内重新判断。
- 空闲预测时间不会覆盖上一真实到期点，同一空闲期跨重启也不会重复执行到期事件。
- 已确认空闲时不设置到期检查任务，由周期轮询继续检查；真实窗口开始后重新设置。

重置事件只保留为审计信息；旧 `keepaliveIntervalMinutes` 被忽略并在应用配置时提示迁移。
如需连续衔接 primary，使用 `anchorOnExpiry:["primary"]`。两个触发器均为空时不自动调用模型。

### 立即触发

在 AutoAnchor 已启用且 `codex.autoAnchor.anchorOnApply=true` 时，
运行 `install.cmd` / `apply-config.cmd` 会请求立即锚定。
每个本地自然日最多实际尝试一次，不受最小间隔限制，仍执行其他校验。

### 手动重置后的记录

旧窗口尚未到期时，如果已用比例下降或真实到期时间改变，记录
**到期前额度恢复／窗口重置**（`QUOTA_RECOVERED_EARLY`）。

| 记录内容 | 字段（位于 `quotaChange` 中） |
|---|---|
| 额度桶、窗口类型 | `bucketId`、`windowType` |
| 前后已用比例 | `previousUsedPercent`、`usedPercent` |
| 前后到期时间 | `previousResetsAt`、`resetsAt` |
| 恢复原因 | `reason=unknown` |

- 事件写入运行日志、历史记录和待同步记录，并计入每日汇总。
- 采用新的额度状态，更新到期检查时间；恢复事件本身不触发模型调用。
- 额度快照不能证明使用了重置卡，因此不会自动标注“手动充值”。
- 周期采样可能错过“用完、重置、再次使用”的中间瞬间，只记录实际观测到的前后变化。

### 执行约束

这是**实验性**行为：

- OpenAI《使用条款》禁止规避任何 rate limits / restrictions；官方未明确批准 AutoAnchor 这一用途。
- **单机同样可用**：未配置协调仓库（LOCAL_ONLY）时跳过远端 CAS Claim 与租约重验证，
  以本地 runner 锁、持久 Claim 和 state 去重承担 at-most-once；配置了多机协调后使用分布式 Claim。
- 本项目**不保证零风控**。首次开启会显示醒目警告；默认关闭，安装器不会自动开启。
- 开启前必须满足的清单见 `docs/design/04`（单 Leader、幂等锁、每日上限、最小间隔、fail-closed 等已内置）。
- 遇到 429、usage-limit、认证异常、未知 schema 时立即 fail closed，不调用模型。
- Anchor 提示词 `codex.autoAnchor.prompt` 支持中文等 Unicode，长度上限 200 字符；仍禁用换行与
  shell 元字符（`.cmd` 安装经 cmd.exe 展开，防注入）。

### 模型与思考等级

额度读取使用协议方法，不调用模型。AutoAnchor 默认沿用本机 Codex CLI 配置。

| 配置 | 作用 |
|---|---|
| `codex.autoAnchor.model` | 覆盖锚定模型，传给 CLI 的 `-m` |
| `codex.autoAnchor.reasoningEffort` | 覆盖锚定思考等级，传给 CLI 的 `model_reasoning_effort` |

执行前校验配置，history 审计记录保留实际生效值。

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

- **[运行场景详解](docs/scenarios.md)** — 12 类场景：配置组合、具体数值、处理时间与跳过原因
- Codex app-server README — https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md
- Using Codex with your ChatGPT plan — https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan
- How banked Codex resets work — https://help.openai.com/en/articles/20001498-how-banked-codex-resets-work
- Codex issue #39444 — https://github.com/openai/codex/issues/39444
- Codex issue #28246 — https://github.com/openai/codex/issues/28246
