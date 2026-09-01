# Changelog

## Unreleased

### Changed
- `github.coordination.enabled` 与 `github.historySync.enabled` 示例默认改为 `false`：
  单机复制配置即可零配置运行；多机需先 `setup-log-repo.ps1` 再开启。
- `codex.proxy` 校验放行 `socks5://` / `socks5h://`（是否被 codex 识别取决于其自身 HTTP 栈，
  失败仍回退直连一次；CQK-020）。
- 文档明确：keeper 不指定模型/思考等级（额度读取为 app-server 协议方法；AutoAnchor 沿用
  本机 Codex CLI 默认配置）。

## 0.9.0-beta (2026-08-30)

MonitorOnly 首个公开 Beta。按《codex-Monitor_仓库审查与开发计划_v1.0》完成
协议兼容、配置语义、Windows 启动器、多机数据一致性与 AutoAnchor 分布式重构。

### Added
- Quota v2 快照模型：buckets（bucketId/windowType）+ 元数据 + rawMetadata，
  官方 schema 契约 fixtures 与契约测试（CQK-001/002）。
- 集群级 Global Backoff（coordination/backoff.json），租约接管无法绕过退避（CQK-008）。
- 不可变 history（history/<date>/<machineId>/...）+ durable outbox + sync-state（CQK-009/010）。
- 专用日志仓库绑定 marker、origin 指纹与业务分支名拒绝（CQK-011）。
- AutoAnchor 分布式 CAS Claim（coordination/events/<eventId>.json）与执行前租约重验证（CQK-013/014）。
- 统一外部命令启动器 Resolve-ExecutableLaunchSpec（exe/ps1/cmd/bat，npm codex.cmd 可用）（CQK-004）。
- GitHub Actions：PS7/PS5.1 测试、契约测试、PSScriptAnalyzer、secret scan（CQK-017/018）。

### Changed
- 配置 schema v2：poll / github.coordination / github.historySync / codex.autoAnchor 嵌套结构；
  v1 平铺键自动迁移（CQK-005）。
- logging.includeMachineLabel 默认 false，false 时本地与远程 history 均不含 machineLabel（CQK-006）。
- Runner 完成阶段自动执行日志保留期清理（CQK-007）。
- EventRecord 统一增加 runId / version / errorKind 字段。
- 协调/历史分支默认名改为 cqk/coordination、cqk/history。

### Security
- 脱敏覆盖 ghp_/gho_/ghu_/ghs_/ghr_/github_pat_ 与 URL userinfo（CQK-012）。

### 升级说明
- 从 0.1.x 升级：config.json 建议按 config.example.json 重写（旧键会自动迁移）；
  runtime/state.json 会自动迁移到 schema 2（旧窗口快照迁入 default bucket）；
  日志仓库需运行一次 scripts/setup-log-repo.ps1 完成绑定。
