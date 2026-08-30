# 运维

## 部署

1. 解压到固定目录（如 `D:\Tools\codex-quota-keeper`）。
2. `config.example.json` -> `config.json`：确认 `mode=MonitorOnly`、
   `codex.autoAnchor.enabled=false`，设置 `poll.intervalMinutes`（>=5）与 `leader.label`。
3. `install.cmd` —— 只读 quota probe 通过后注册当前用户计划任务（无需管理员）。
4. `status.cmd` 验证。
5. 多机：准备专用 Private Git 仓库；每台机器运行
   `pwsh scripts/setup-log-repo.ps1 -RepoPath <路径>`；第二台机器安装后应显示 PASSIVE。

## 日常

- 只看状态：双击 `status.cmd`（只读，不争抢 Leader、不 push）。
- 改轮询周期：改 `config.json` 后 `apply-config.cmd`（允许 5/10/15/30/60 分钟，低于 5 拒绝）。
- 卸载：`uninstall.cmd`（默认保留历史；`-DeleteHistory` 连本地历史一起删）。

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
