# 安全模型

## 硬性禁止

- 不读取、复制或上传 `auth.json`、OAuth token、refresh token。
- 不访问 ChatGPT 网页，不伪造客户端或设备身份。
- 不向用户业务仓库执行任何 Git 写操作。

## 本机执行边界

- 推荐部署到 `$env:LOCALAPPDATA\CodexQuotaKeeper`。安装器检查部署根目录 ACL；若除当前用户、
  Administrators 或 SYSTEM 外的主体具有写权限，会告警，因为计划任务会执行该目录中的脚本与 VBS 启动器。
- runner 使用 named mutex + lock file。普通周期任务遇锁立即退出；闹钟/强制启动器最多等待 60 秒，
  获得锁后重新读取当前额度，避免基于过期快照执行。
- 计划任务只以当前用户运行，不存储 Codex 凭证。

## 数据最小化

- history 字段白名单：ts/event/machineId/role/mode/runId/windows/anchor/error/version。
- 默认不写 machineLabel。错误文本在所有本地/远程审计面进入统一脱敏，并把当前用户主目录替换为
  `<user>`。AutoAnchor prompt 永不写入日志或 history。

## 专用协调仓库

- `setup-log-repo.ps1` 写入 marker，并绑定 repoId、origin 指纹和允许分支。
- 每次租约、退避、outbox 或 claim 推送前重新验证绑定；main/master/develop/release 等业务分支强制拒绝。
- 任一验证不确定即 fail-closed。

## AutoAnchor 副作用控制

- schedule 与 expiry 使用确定性 eventId；同轮事件先合并，再执行最多一次物理 `codex exec`。
- LOCAL_ONLY 使用本地持久 Claim；多机使用远程 CAS Claim，并在执行前重验证 Leader 租约。
- 已有 CLAIMED/COMPLETED/FAILED/EXPIRED 记录都不会自动重试。启动结果不确定时保守计费并终止。
- 每日上限、expiry 最小间隔、processedEventIds、执行画像与二次额度验证共同限制副作用。
- 429、认证错误、未知 schema、协调仓库不可达一律阻止执行；单机 DNS/TLS/TIMEOUT/EOF 不传播为
  集群退避，但本轮仍不会执行模型。
