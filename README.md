# Codex Monitor

Windows 上的 Codex（ChatGPT 计划）额度监控与多机互斥工具：
按周期通过官方 `codex app-server` 读取额度状态，用 Private Git 仓库实现
跨机器单 Leader 协调，本地 JSONL + 可选远程不可变 history 审计。

> **默认 MonitorOnly**：只读额度、写日志、做互斥，**不调用模型**、不抓网页、
> 不读取 `auth.json`、不需要常驻 UI。
> `AutoAnchor` 是默认关闭的实验功能，见 [AutoAnchor 章节](#autoanchor实验默认关闭)。

## 仓库结构

```
codex-quota-keeper/   工具本体（scripts/tests/安装入口）
doc/                  设计文档与开发计划
docs/                 架构 / 运维 / 安全模型说明
```

## 快速开始

1. 需要 Windows 10/11、PowerShell 7（入口兼容 5.1）、可运行的 Codex CLI/Desktop 并完成登录。
2. `cd codex-quota-keeper`，复制 `config.example.json` 为 `config.json`，
   按需修改 `poll.intervalMinutes`、`leader.label`、`github.coordination.repoPath`。
3. 运行 `install.cmd`（安装前会做一次只读 quota probe，成功后注册当前用户计划任务）。
4. 双击 `status.cmd` 确认 `Task installed=YES`、`Enabled=YES`、`Codex CLI=READY`。
5. 修改配置后运行 `apply-config.cmd`；卸载运行 `uninstall.cmd`（本地历史默认保留）。
6. 多机模式：准备一个专用 Private Git 仓库，在每台机器执行
   `pwsh scripts/setup-log-repo.ps1 -RepoPath <日志仓库路径>` 完成绑定。

## 多机协调（单 Leader）

- 每台机器一个随机 machineId（不用 MAC/序列号）。
- 租约在 Private 仓库 `cqk/coordination` 分支，Git push 冲突作 CAS，
  任意时刻最多一个 Leader 查询额度。
- 集群级 Global Backoff：任何机器遇到 429/认证错误后，其它机器接管也不会绕过退避。
- 日志仓库必须专用：`setup-log-repo.ps1` 写入 marker（repoId）+ origin 指纹绑定，
  推送前校验，main/master 等业务分支名强制拒绝。

## AutoAnchor（实验，默认关闭）

检测到额度窗口重置后，自动发送一个无业务意义的最小 Prompt 以锚定下一轮窗口。

- **官方未明确背书该用途**；OpenAI《使用条款》对"规避限制"存在解释风险，本项目不承诺零风控。
- 默认 `codex.autoAnchor.enabled=false`，安装器不会自动开启。
- 开启后仍有完整约束：分布式 CAS Claim（同一事件全局最多一次副作用）、
  执行前租约重验证、每日上限、最小间隔、429/认证/未知 schema/远程不可达一律 fail-closed。
- 每次执行的 before/after 额度快照写入 history 以便审计。

## 支持矩阵

| 平台 | 版本 |
|------|------|
| Windows | 10 / 11 |
| PowerShell | 7.x（推荐），5.1（入口与测试兼容） |
| Codex | CLI 或 Desktop 提供的 app-server（npm 安装的 codex.cmd 支持） |
| Git | 任意现代版本（Credential Manager / SSH） |

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

## 文档

- [docs/architecture.md](docs/architecture.md) — 模块与数据流
- [docs/operations.md](docs/operations.md) — 部署、多机与日常运维
- [docs/security-model.md](docs/security-model.md) — 安全边界与隐私设计
- [CHANGELOG.md](CHANGELOG.md) — 版本历史与升级说明
