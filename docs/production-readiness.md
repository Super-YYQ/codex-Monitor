# 产品就绪审查（2026-09-12）

当前结果是待发布验收的候选版本，不能据此宣称已完成大规模使用验收。默认仍为 Windows Task Scheduler 零常驻 MonitorOnly；AutoAnchor 保持实验性、显式开启。未改变产品定位，也未引入服务端或常驻进程。

## 分支与范围

- 审查基线：`origin/main` 的 `cdca944`；遗留修复分支：`origin/feat/p0-hardening-cqk-036` 的 `6b626e1`。
- 本地原 main `019ef80` 与历史重写后的 `85ee79b` 文件树完全一致；保留原 main，在 `codex/production-readiness` 接续遗留工作，避免按分支距离误判为内容冲突。
- CQK-036~039 已有实现，CQK-040 原为未回归的 WIP；本次补齐 CQK-040~046 及审查发现，CQK-047 全量验收和 CQK-048 真机验收仍有门禁。
- 未执行任何 `git push`，未修改实际部署的产品计划任务，未发起真实模型调用。

## 双轴审查与修复

| 轴 | 发现 | 结果 |
|---|---|---|
| Standards | 重置事件在 Profile 拒绝后消失 | 保存有限待处理队列；校验恢复后同一事件仍能触发 |
| Standards | 已知已有 Claim 的待处理事件反复阻挡保活 | 明确区分已存在和存储不可达；仅前者终止重试 |
| Standards | 运行日志、历史、outbox 净化规则不一致 | 统一 anchor 白名单投影；旧待发记录发送前重新净化 |
| Standards | 成功同步删除未入批的损坏文件 | 只确认、删除真正入批的记录，坏文件保留诊断 |
| Standards | 计数跨午夜记入前一天 | 实际启动前重新确定本地自然日 |
| Spec | 旧 count 被误当成功；启动失败也产生调用身份 | count 保守迁移为 attempts；确认未启动退还预留，不创建 invocation id |
| Spec | runner 用错误文本推测 429 | 底层产出 errorKind/retryable，上层只使用类型 |
| Spec | 安装重试与错误展示缺少边界 | 两轮额度探测，每轮最多 proxy/direct；仅网络、超时、EOF 重试 |
| Spec | 无效/不可用 Profile 未影响整体健康 | 增加结构化 finding；RUNNER_OK 不清除新近 Profile 失败 |
| Spec | `status.cmd -Live` 静默忽略参数 | 支持 Live/Detailed/NoColor/--no-pause，未知参数返回 2，保留子进程退出码 |
| 追加复现 | 日志列表嵌套、单条日志退化 | 统一列表枚举，覆盖真实日志文件的健康判断 |
| 追加复现 | `.cmd` 启动器多余引号与 ZIP 中 LF 字节 | 修复命令构造；批处理提交 CRLF 原始字节，实际入口回归通过 |

实现沿用共享 JSON-RPC 会话层、Execution Profile Resolver 和 Runner 单一审计写入者；没有充分证据需要替换整个架构。

## 行为与迁移

1. 每次 AutoAnchor 在 Claim 前，使用与 exec 相同的工作目录读取 CLI 的 `config/read` 和分页 `model/list`。无效或不可用时不 Claim、不 exec、不计调用；模型目录不使用仓库静态白名单。
2. 一次物理 exec 对应一个 `anchorInvocationId`，多个触发事件合并到 `triggerEventIds`；configured/effective/provider/source/validation 随同记录。三个审计面共享净化规则。
3. `attemptCount` 控制每日上限，`successCount`/`failedCount` 仅记录已知结果。启动前持久化次数预留，确认没有启动才退还；进程启动后异常、超时或崩溃仍保守占用额度。失败或不确定的 Claim 不自动重试。
4. 旧 `count`、`lastAnchorAt` 保留兼容别名；历史 count 只迁移为 attempts，不伪造成功次数和成功时间。因此旧状态的 attempts 可以大于 success + failed。换日清零每日计数，保留最近尝试/成功时间。
5. `anchorOnApply` 每个本地自然日最多实际尝试一次，仍受总次数上限和其他门禁限制；不是每次点 Apply 都额外调用。
6. 默认 Status 仅读缓存且不创建 machine identity。`status.cmd -Live` 可刷新额度及执行配置；缓存只保留白名单字段，UNAVAILABLE 不覆盖旧有效缓存，但会显示当前校验失败。缓存过期不能证明当下有效。
7. 升级前停止产品计划任务，保留 `config.json`、`runtime/`、`history/`，覆盖程序文件后运行 Apply。不要复制另一台机器的 runtime，也不要清空 Claim 来重试失败事件。回退需保留当前 Claim 与状态备份，不能用旧快照重新放行已有调用。

官方协议参考：[Codex app-server](https://learn.chatgpt.com/docs/app-server)。本机仅核对 CLI 0.146.0 的版本与帮助；上述协议链路的自动验证使用仓库 mock，未认证真实账号兼容性。

## 验证入口与证据

```powershell
pwsh -NoProfile -File codex-quota-keeper/tests/run-all.ps1 -ExcludeGitPush
powershell -NoProfile -ExecutionPolicy Bypass -File codex-quota-keeper/tests/run-all.ps1 -ExcludeGitPush
```

`-ExcludeGitPush` 显式跳过 7 套使用本地 bare 仓库 push 的集成测试：anchor-claim、auto-anchor、concurrency、github-sync、global-backoff、leader-lease、runner。默认 run-all 和 CI 仍运行全部；此选项不是安全沙箱，也不代表整套发布门禁通过。

新增 readiness 39 项、outbox-readiness 12 项、status-entry 5 项检查已通过定向验证；install-retry 11 项检查已通过。覆盖模型修正后的 reset 重试、无启动退款、失败计数、强制调用限制、旧状态迁移、三处审计脱敏、损坏 outbox 保留、真实 cmd 参数和退出码。

双运行时最终套件、分析器与候选 ZIP 的结果见下表。测试只涉及临时工作区、模拟 CLI，install-status 使用独立临时任务名。

| 验证 | 实际结果 |
|---|---|
| PowerShell 7，16 套选定测试 | 首轮 15 通过；common 只因旧引号快照失败，修正后定向重跑通过 |
| Windows PowerShell 5.1，同样 16 套 | 首轮 15 通过；同一 common 快照修正后定向重跑通过 |
| 最终测试范围 | 16 套均有通过证据；7 套含 push 的集成测试未执行；未声称默认 run-all 全绿 |
| 静态分析 PSScriptAnalyzer 1.25.0 | 0 Error，66 条非 Error findings；未把此结果称为零告警 |
| 仓库凭据扫描 | 93 文件、无路径排除，未发现凭据模式；构建门禁再次通过 |
| Git 差异检查 | 暂存 diff --check 通过；CRLF 按批处理属性处理 |
| 候选源提交 | `d95887dbc89e8d28c197fe24ebd1a9022f960f05` |
| 重复构建 | 两次 ZIP 均为 78 文件，同一 SHA-256（如下） |
| 解压验证 | 5 个 cmd 均为 CRLF；解压后状态入口回归在 PS7/PS5.1 各 5 项通过 |

候选 ZIP：`codex-quota-keeper/tools/dist/readiness-a/codex-quota-keeper-v0.9.0-beta.zip`，
SHA-256：`f7fb11f5cb67a83201d83d986383fbdddba3dc84afeeb0e83de7c5fc39d24d48`。
产物为本地候选、已被 Git 忽略，没有上传。完整首次运行及 common 最终重跑日志保存在本机
`$env:TEMP/cqk-readiness-20260912/`；首次 run-all 返回失败已如实保留，不能只读取其中的 RESULT 当作最终回归结论。

## 尚未关闭的发布门禁

- 本次禁止 push 的约束涵盖临时本地 bare 仓库。需要明确授权后执行未运行的 7 套集成测试，再在 PS7/PS5.1 跑默认全量；不能以旧分支全绿替代本次改动的验证。
- 在两台实际 Windows 主机、相同候选 commit 上，执行共享远端的 soak 与故障注入；同时记录 CLI/OS/PowerShell 版本、触发时间、调用唯一性和资源残留。单机两目录及 mock 故障注入只能提供部分证据。
- 真实 CLI 的 config/read、目录分页及一次受控 exec 冒烟需要部署账号环境和明确调用范围。未运行的部分保持未勾选，不能以“没有报错”替代。
- 对大范围使用，先以 MonitorOnly 分批部署，观察读取成功率、调度延迟、残留进程、日志增长和恢复，再扩大；AutoAnchor 单独按显式开启人群验收。仓库没有中央服务容量问题，但不能外推账号限流或大量终端同时轮询的可靠性。
- 未完成上述证据，不创建版本 tag、不发布 Release、不声称生产验收完成。详见 [soak 操作单](soak-runbook.md)。
