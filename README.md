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
doc/                  设计文档与开发计划
docs/                 架构 / 运维 / 安全模型说明
```

---

## 快速开始

1. 需要 Windows 10/11、PowerShell 7（入口兼容 Windows PowerShell 5.1）、
   可运行的 Codex CLI 或 Desktop 且当前用户已登录。
2. 打开 `codex-quota-keeper` 目录，复制 `config.example.json` 为 `config.json`，
   按需修改（连接口周期见下方「配置」章节）。
3. 双击 `install.cmd`（安装前先做一次只读 quota probe，通过后注册当前用户计划任务，**无需管理员**）。
4. 双击 `status.cmd`，确认 `Task installed=YES`、`Enabled=YES`、`Codex CLI=READY`。
5. 改完配置后双击 `apply-config.cmd` 生效；卸载双击 `uninstall.cmd`（本地历史默认保留）。
6. 多机模式：准备一个专用 Private Git 仓库，在每台机器执行
   `pwsh scripts/setup-log-repo.ps1 -RepoPath <日志仓库路径>` 完成绑定。

---

## 配置（`config.json` 在哪改、怎么改）

配置文件是 `codex-quota-keeper/config.json`（从 `config.example.json` 复制而来）。
**改完任意字段后双击 `apply-config.cmd`**，它会校验配置并更新 Windows 计划任务
（轮询周期与启动条件）。幂等，可反复执行。

### 定时 / 轮询

| 字段 | 默认 | 说明 |
|------|------|------|
| `poll.intervalMinutes` | `15` | **额度轮询周期（分钟）**，即计划任务的重复间隔；允许 `5 / 10 / 15 / 30 / 60`，低于 5 会被拒绝 |
| `poll.minimumIntervalMinutes` | `5` | 允许的最小间隔下限（验证用） |
| `task.name` | `CodexQuotaKeeper.Check` | Windows 计划任务名 |
| `task.startWithWindows` | `true` | 开机自启 |
| `task.runIfNetworkAvailable` | `true` | 仅在有网络时运行 |
| `task.wakeToRun` | `false` | 是否允许唤醒计算机执行 |

### 多机协调（Leader 租约）

| 字段 | 默认 | 说明 |
|------|------|------|
| `leader.enabled` | `true` | 是否启用租约协调 |
| `leader.label` | `Home PC` | 本机标签（便于在 status/审计里区分机器） |
| `leader.leaseTtlMinutes` | `45` | 租约 TTL（≈轮询周期 3 倍） |
| `leader.graceMinutes` | `5` | 时钟漂移 / 网络延迟容忍 |
| `leader.takeoverOnExpiry` | `true` | 租约过期后允许他人接管 |

### 协调与历史仓库（GitHub）

| 字段 | 默认 | 说明 |
|------|------|------|
| `github.coordination.enabled` | `true` | 租约协调开关（false = LOCAL_ONLY，多机不安全） |
| `github.coordination.repoPath` | — | 专用 Private 日志仓库本地路径（多机必填） |
| `github.coordination.branch` | `cqk/coordination` | 协调分支 |
| `github.historySync.enabled` | `true` | 是否同步净化后的 history |
| `github.historySync.push` | `true` | 是否 push history 分支 |
| `github.historySync.branch` | `cqk/history` | history 分支 |
| `github.historySync.eventsOnly` | `true` | 只同步重要事件（普通轮询零写入） |

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
| `codex.autoAnchor.enabled` | `false` | **实验功能开关，默认关闭，安装器不会自动开启** |
| `codex.autoAnchor.prompt` | `Reply exactly OK.` | 锚定用的最小 Prompt（受长度/字符集白名单约束） |
| `codex.autoAnchor.maxPerDay` | `6` | 每日最大执行次数 |
| `codex.autoAnchor.minimumGapMinutes` | `60` | 两次锚定的最小间隔 |

> 配置 schema 标注为 v2；旧版平铺键（如 `pollIntervalMinutes`、`github.repoPath`）会
> 在加载时自动迁移，无需手工改写。

---

## 多机协调（单 Leader）

- 每台机器一个随机 `machineId`（不用 MAC / 序列号）。
- 租约在 Private 仓库的 `cqk/coordination` 分支；Git push 冲突作为 CAS，
  任意时刻最多一个 Leader 查询额度。
- 集群级 Global Backoff：任何机器遇到 429/认证错误后，其余机器接管也不会绕过退避。
- 日志仓库必须专用：`setup-log-repo.ps1` 写入 marker（repoId）+ origin 指纹绑定，
  推送前校验，main/master 等业务分支名被强制拒绝。

## AutoAnchor（实验，默认关闭）

检测到额度窗口重置后，自动发送一个无业务意义的最小 Prompt 以锚定下一轮窗口。

- **官方未明确背书该用途**；OpenAI《使用条款》对“规避限制”存在解释风险，本项目不承诺零风控。
- 默认 `codex.autoAnchor.enabled=false`，安装器不会自动开启。
- 开启后仍有完整约束：分布式 CAS Claim（同一事件全局最多一次副作用）、
  执行前租约重验证、每日上限、最小间隔、429/认证/未知 schema/远程不可达一律 fail-closed。
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

- [docs/architecture.md](docs/architecture.md) — 模块与数据流
- [docs/operations.md](docs/operations.md) — 部署、多机与日常运维
- [docs/security-model.md](docs/security-model.md) — 安全边界与隐私设计
- [SECURITY.md](SECURITY.md) — 漏洞报告与安全策略
- [CHANGELOG.md](CHANGELOG.md) — 版本历史与升级说明

## License

[MIT](LICENSE) © 2026 Super-YYQ