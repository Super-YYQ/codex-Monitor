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
  config.example.json
  scripts/         实现脚本
  runtime/         gitignored（machine.json / state.json / lock / logs）
  history/         净化日志（可选 Git 同步）
  tests/           单元测试（mock app-server，无需真实凭证）
```

## 快速开始

1. 解压到固定目录，例如 `D:\Tools\codex-quota-keeper`。
2. 复制 `config.example.json` 为 `config.json`，按需改 `poll.intervalMinutes`、`leader.label`、
   `github.coordination.repoPath`（完整字段见下方「配置」）。
3. 确保 `mode=MonitorOnly`、`codex.autoAnchor=false`。
4. 运行 `install.cmd`（会做一次只读 quota probe，成功后注册 Windows 计划任务）。
5. 双击 `status.cmd` 验证 `Task installed=YES`、`Enabled=YES`、`Auth=READY`。
6. 第二台电脑重复安装，确认只有一台 `LEADER`、另一台 `PASSIVE`。

## 配置（修改与生效）

配置文件是 `config.json`（改前先备份）。**改完任意字段后运行 `apply-config.cmd`**，
它会校验配置并更新 Windows 计划任务的轮询周期；可反复执行、幂等。

定时相关字段（计划任务由它们驱动）：

| 字段 | 默认 | 说明 |
|------|------|------|
| `poll.intervalMinutes` | 15 | 额度轮询周期（分钟），允许 5/10/15/30/60，低于 5 拒绝 |
| `poll.minimumIntervalMinutes` | 5 | 最小间隔下限 |
| `task.name` | CodexQuotaKeeper.Check | 计划任务名 |
| `task.startWithWindows` | true | 开机自启 |
| `task.runIfNetworkAvailable` | true | 仅在有网络时运行 |
| `task.wakeToRun` | false | 是否允许唤醒执行 |

其它常用字段：

| 字段 | 默认 | 说明 |
|------|------|------|
| `mode` | MonitorOnly | 运行模式（MonitorOnly / AutoAnchor） |
| `leader.label` | Home PC | 本机标签 |
| `leader.leaseTtlMinutes` | 45 | 租约 TTL |
| `github.coordination.repoPath` | — | 专用日志仓库本地路径（多机必填） |
| `github.historySync.push` | true | history 分支推送开关 |
| `logging.includeMachineLabel` | false | 隐私开关：machineLabel 是否进 history |
| `codex.autoAnchor.enabled` | false | 实验功能开关（默认关闭） |

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
| `github.coordination.enabled` | true | 租约协调（false = LOCAL_ONLY，多机不安全） |
| `github.coordination.repoPath` | — | 专用日志仓库本地路径 |

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
```

## AutoAnchor 风险说明（实验，默认关闭）

AutoAnchor 指：检测到额度窗口重置后，自动发送一个无业务意义的最小 Prompt（如 `Reply exactly OK.`）
以提前锚定下一轮额度窗口。这是**实验性**行为：

- OpenAI《使用条款》禁止规避任何 rate limits / restrictions；官方未明确批准“quota keepalive/AutoAnchor”这一用途。
- 本项目**不保证零风控**。首次开启会显示醒目警告；默认关闭，安装器不会自动开启。
- 开启前必须满足的清单见 `doc/04`（单 Leader、幂等锁、每日上限、最小间隔、fail-closed 等已内置）。
- 遇到 429、usage-limit、认证异常、未知 schema 时立即 fail closed，不调用模型。

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