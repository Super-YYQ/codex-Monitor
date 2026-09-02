# 运维

## 部署

1. 解压到固定目录（如 `D:\Tools\codex-quota-keeper`）。
2. `config.example.jsonc` -> `config.json`：模板为 JSONC（带中文注释，取消注释即自定义）；
   确认 `mode=MonitorOnly`、`codex.autoAnchor.enabled=false`，设置 `poll.intervalMinutes`（>=5）
   与 `leader.label`。
3. `install.cmd` —— 只读 quota probe 通过后注册当前用户计划任务（无需管理员）。
   **想让 CLI 在安装/改配置后立即被调用一次**：`codex.autoAnchor.anchorOnApply=true`
   （需已启用 AutoAnchor）——`install.cmd` 与 `apply-config.cmd` 都会立刻触发一次锚定。
   另一个可选模式：`codex.autoAnchor.schedule=["09:30","21:00"]` 每天固定时刻触发一次
   CLI（纯定时，不判断重置/空闲场景；详见 README「AutoAnchor」）。
4. `status.cmd` 验证。
5. 多机：准备专用 Private Git 仓库；每台机器运行
   `pwsh scripts/setup-log-repo.ps1 -RepoPath <路径>` 完成绑定，然后把
   `config.json` 的 `github.coordination.enabled` 与 `github.historySync.enabled` 置为
   `true`（示例默认均为 false，单机无需开启）；第二台机器安装后应显示 PASSIVE。

### 计划任务节奏

- **锚点**：注册任务时以「当前时刻 +1 分钟」为 `-Once` 触发器起点，之后每
  `poll.intervalMinutes` 重复一次（不绑定整点；重复时长固定 3650 天 ≈ 等效无限）。
- **触发器**：除周期触发外，`task.startWithWindows=true`（默认）另加 AtLogOn（每次登录执行）；
  关机错过的周期由 `StartWhenAvailable=true` 在可运行时立即补跑。
- **重锚点**：`apply-config.cmd` 用 `-Force` 重注册任务，锚点重置为执行当时 +1 分钟
  （改间隔后新一轮周期从那一刻起算）。
- **首轮**：安装时的只读 quota probe 只验证连通性、不保存状态；计划任务首次正式运行是
  first observation（空历史）——窗口重置检测最早第二轮才可能出现，AutoAnchor 的
  空闲判定也要求第二次观测（从未锚定 + 零用量）才触发一次 CLI；之后静默 5 小时
  （`minimumGapMinutes` 默认 300），等待窗口真正滚动。

## 日常

- 只看状态：双击 `status.cmd`（只读，不争抢 Leader、不 push）。
- 改轮询周期：改 `config.json` 后 `apply-config.cmd`（允许 5/10/15/30/60 分钟，低于 5 拒绝）。
- 卸载：`uninstall.cmd`（默认保留历史；`-DeleteHistory` 连本地历史一起删）。

## 更新升级

- 把新版 `codex-quota-keeper/` 文件**合并覆盖**到部署目录（复制粘贴合并，勿先删目录再粘贴）：
  务必保留 `config.json`（自定义配置）、`runtime/`（含 `machine.json` 机器身份——多机租约以
  machineId 识别机器，id 变了会被当成新机器）、`history/`（净化日志历史）。
- 覆盖后再运行一次 `install.cmd`：注册用 `Register-ScheduledTask -Force` 同名替换，
  **不会产生多个计划任务**（前提是 `task.name` 未改；改名则旧任务残留，需手动删除）。
  任务 Action 绑定部署目录绝对路径，覆盖后路径不变，无需卸载重装。
- 新版本新增的配置项以注释形式出现在 `config.example.jsonc`；你的 `config.json` 不添加也能
  运行（未配置字段走内置默认值），需要再取消注释并执行 `apply-config.cmd`。
- 若曾在多个目录分别安装过（例如源码仓库里也点过一次），任务只指向**最后一次安装**的目录；
  固定只用部署目录安装。
- 升级前看根目录 `CHANGELOG.md` 的「升级说明」。

## 仓库运维

- history 仓库必须 Private；只包含净化后的额度/事件/租约数据与 marker。
- 重要事件实时 push（不可变文件），普通轮询零写入；每日 summary 按机器隔离。
- 协调分支若积累大量租约提交，可定期 compact（不影响 history 分支）。
- 保留期：`logging.retentionDays` 由 runner 每轮自动清理本地 runtime/logs 与 history。

## 故障排查

| 状态 | 处理 |
|------|------|
| Task NOT FOUND | 重跑 install.ps1 |
| LastResult != 0 | 看 runtime/logs；手动跑 runner.ps1 |
| AUTH ERROR | Codex 重新登录；status --live 复测 |
| PASSIVE unexpectedly | 查远程 lease；等 TTL 接管 |
| DEGRADED | 检查日志仓库 fetch/push；确认 setup-log-repo 绑定 |
| GLOBAL_BACKOFF_SKIP | 集群退避生效（429/认证错误），等 until 过期 |
