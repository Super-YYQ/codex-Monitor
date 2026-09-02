# 安全模型

## 硬性禁止

- 读取 / 复制 / 上传 `auth.json`、OAuth token、refresh token。
- 访问 ChatGPT 网页、伪造客户端或设备身份。
- 向用户业务仓库执行任何 git 写操作。

## 数据最小化

- history 字段白名单：ts/event/machineId/role/mode/runId/windows/anchor/error/version。
- `logging.includeMachineLabel=false`（默认）时 machineLabel 不写入本地与远程 history。
- 错误文本入库前脱敏：sk-、ghp_/gho_/ghu_/ghs_/ghr_/github_pat_、URL userinfo、
  token/refresh_token/authorization/cookie 等键值。
- AutoAnchor 的 prompt 永不写入日志或 history。

## 专用日志仓库绑定

- `setup-log-repo.ps1` 写入 marker（repoId/createdFor/allowedBranches）并把
  repoId + origin 指纹绑定到本机 runtime。
- 每次推送（租约/退避/outbox/claim）验证：绑定存在、repoPath 一致、marker 一致、
  origin 指纹一致、分支在 allowedBranches 内；main/master/develop/release 等业务分支强制拒绝。
- 任何不匹配 fail-closed，绝不适配。

## AutoAnchor 副作用控制（实验）

- 分布式 CAS Claim：同一 reset/idle/keepalive/schedule 事件全局最多一次副作用。
- Claim 后重验证租约归属与剩余时间；不确定结果（EXPIRED/FAILED/COMPLETED push 失败）永不重试。
- 每日上限 + 最小间隔 + 本地 processedEventIds + 远程 claim 多层限制。
- LOCAL_ONLY 单机（未配置协调仓库）：无远端 Claim，改为本地 runner 锁 + state 去重承担
  at-most-once；执行中不重试、失败计入当日上限后由静默期/兜底间隔再触发。
- 429 / AUTH_ERROR / SCHEMA_UNKNOWN / 远程不可达一律 fail-closed。
