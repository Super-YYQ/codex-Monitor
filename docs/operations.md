# 运维

## 部署

1. 把发布目录解压到当前用户私有的固定位置，例如 `$env:LOCALAPPDATA\CodexQuotaKeeper`。
2. 复制 `config.example.jsonc` 为 `config.json`。首次保持 `mode=MonitorOnly`、
   `codex.autoAnchor.enabled=false`，设置轮询周期和机器标签。
3. 运行 `install.cmd`。安装器先做只读额度探测，再注册当前用户的 Windows 计划任务；无需管理员。
4. 运行 `status.cmd`，确认主任务、Codex CLI 和额度读取正常。
5. 修改配置后运行 `apply-config.cmd`；它会重建主任务触发器并同步/清除到期闹钟。

安装器会检查部署目录 ACL。若同机其他普通用户可写脚本或 `runtime\hidden-launch*.vbs`，会告警；应迁移到
当前用户私有目录后重新安装。

## 计划任务

- 主任务包含周期触发器、可选 AtLogOn，以及 `codex.autoAnchor.schedule` 中每个 `HH:mm` 对应的
  原生每日触发器。`StartWhenAvailable=true` 只能在 Windows 允许任务运行后补跑，不保证机器从睡眠中
  自动醒来；是否唤醒取决于 `task.wakeToRun`、硬件和系统电源策略。
- 配置 `anchorOnExpiry` 时，另有一个稳定名称的 `.AnchorAlarm` 一次性任务，指向最近已知窗口
  `resetsAt + 1 分钟`。runner 每次成功读取后重算；没有未来到期点或功能关闭时删除该任务。
- 闹钟、手动运行和周期轮询并发时共用本地锁。闹钟/强制启动器最多等 60 秒，获得锁后重新查询额度。

## AutoAnchor 配置

```jsonc
"autoAnchor": {
  "enabled": true,
  "schedule": ["08:55", "13:55"],
  "anchorOnExpiry": ["secondary"],
  "anchorOnApply": false
}
```

- `schedule` 用于对齐 primary 工作窗口；到点时 primary 已运行则不调用模型。
- `anchorOnExpiry` 用于补选定窗口的空档，可填 `primary`、`secondary`，也可同时填两个。
- 两者独立且同轮合并；都为空时只读额度。reset 只写审计事件。
- `minimumGapMinutes` 只限制 expiry 自动触发；schedule 与显式 `anchorOnApply` 不受它限制，但仍受每日上限、
  配置画像、租约、退避和 schema 等 fail-closed 门禁。
- 旧 `keepaliveIntervalMinutes` 被忽略。连续衔接 primary 的迁移写法是
  `"anchorOnExpiry":["primary"]`。

## 多机

多机模式仍需专用 Private Git 仓库。每台机器执行
`pwsh scripts/setup-log-repo.ps1 -RepoPath <路径>`，再同时开启 `github.coordination.enabled` 与
`github.historySync.enabled`。第二台机器应显示 PASSIVE。不得把用户业务仓库作为协调仓库。

## 日常与升级

- `status.cmd` 是只读检查；`status.cmd -Live` 才发起实时探测。
- 卸载运行 `uninstall.cmd`：主任务与 `.AnchorAlarm` 都会删除，本地历史默认保留。
- 升级采用合并覆盖，保留 `config.json`、`runtime/` 和 `history/`，再运行一次 `install.cmd`。
- 若旧配置包含 `keepaliveIntervalMinutes`，应用配置时会显示 deprecation 提示；删除该键并按需配置
  `anchorOnExpiry`。

## 退避与排障

| 现象 | 处理 |
|---|---|
| 主任务或到期闹钟不存在 | 运行 `apply-config.cmd` 或 `install.cmd` 重新协调任务 |
| `GLOBAL_BACKOFF_SKIP` | 429/认证集群退避尚未到期，等待或修复登录 |
| `READ_FAILED` 且 kind 为 NETWORK/TIMEOUT/EOF | 仅本机退避；检查代理、DNS/TLS 和 Codex 进程，下轮再试 |
| PASSIVE 异常 | 检查远程 lease 与 TTL；不要删除仍有效的 claim |
| 到期未自动唤醒 | 检查 `.AnchorAlarm`、`wakeToRun`、电源策略和任务历史；先用清醒状态验证 |
| 旧任务名残留 | 若改过 `task.name`，手动删除旧名称；卸载器只能可靠删除当前配置派生的名称 |
