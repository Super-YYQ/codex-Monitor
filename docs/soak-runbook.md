# 双机 soak + 故障注入操作单（v0.9.0-beta 发布前 DoD）

设计文档 v2.0 §21 要求：创建 v0.9.0-beta Release **之前**，先做双机 soak test + 故障注入，
多机连续运行至少覆盖「Leader 正常续租、A/B 异步任务锚点、429、Git 临时断网、恢复、History
重试」，并通过「AutoAnchor 双机并发、LOCAL_ONLY crash claim、Lease revalidate 故障」测试。

自动测试（`tests/` 17 个文件）已经覆盖同样的场景逻辑，但那是 mock 环境。本文档是**实机**操作单：
照着做、勾完框、签名，才可以打 tag。

预计投入：约 **25 分钟动手操作** + **连续挂机 4 小时**（期间机器不锁屏不睡眠）。

---

## 0. 安全前提：默认不花真实额度

AutoAnchor 会真正调用模型。**默认 soak 用仓库自带的 mock app-server 跑**
（`codex-quota-keeper/tests/fixtures/mock-appserver.ps1`）：它是真实进程的 `.ps1`，
被 `codex.command` 指向后，keeper 会走完整的 app-server 协议与全部执行路径，
但返回的是固定数据、`codex exec` 也只 exit 0，**不发出任何网络请求**。

| 范围 | 是否花真实额度 | 是否碰真实 Git 仓库 |
|------|--------------|-------------------|
| 本操作单 §1–§9（全部步骤，含 F1~F7） | **否**（`codex.command` 指向 mock app-server） | **否**（本地裸仓库充当日志仓库） |
| 你自己追加的真实冒烟（按下方改回 `auto` + 真实 `repoPath`） | **是**（每机各约 1–2 次 `codex exec`） | **是**（真实 Private 仓库） |

真实冒烟**不是本操作单的一部分、也不是 §21 的 DoD 项**：DoD 要覆盖的七类场景
（续租、锚点、429、断网、恢复、History 重试、并发/crash/revalidate）全部在 mock
夹具下可判定，且判据比真实环境更硬（`anchor-args.txt` 是模型调用次数的唯一地面真值，
真实环境无法这样计数）。改成真实 Codex 只是额外验证「协议/凭证在真机上也没变」，
可在挂机结束后顺手做一轮，代价是每机 1–2 次真实调用。

中途想换真实 Codex 或真实仓库：编辑同一份 soak 配置，把 `"command"` 改回 `"auto"`、
`repoPath` 换成真实路径即可——**但 `CQK_MOCK_MODE` 等环境变量必须先删掉**（见 §2 的成因说明），
否则真 Codex 会被注入的故障信号干扰。

### 0.1 一次性准备（任一机器做一次，其余机器照抄）

```powershell
# 1) mock 可执行入口（模拟 npm 安装的 codex.cmd，会转发到仓库自带 mock）
New-Item -ItemType Directory 'D:\soak\bin' -Force | Out-Null
Set-Content 'D:\soak\bin\codex.cmd' -Encoding ASCII -Value @'
@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\keeper-B\tests\fixtures\mock-appserver.ps1" %*
'@

# 2) 本地裸仓库 = 「Private GitHub 日志仓库」的离线替身
git init --bare D:\soak\logrepo.git
#    之后 §4 会把它 clone 到两台机器的 D:\soak\logrepo
```

> `codex.cmd` 里的相对路径 `%~dp0..\keeper-B\...` 是按 B 机写法举的例子——
> **部署目录名两台机器不一样**（A 机是 `keeper-A`），所以每台机器各自把自己那台的
> `tests/fixtures/mock-appserver.ps1` 绝对路径写进去更省事。两台机 `bin\codex.cmd`
> 内容可以不同，这不影响 soak。
> 裸仓库没有 `main` 分支也不影响：keeper 只往 `cqk/coordination`、`cqk/history` 两个分支 push。
>
> ⚠️ **未验证路径**：对一个**全新空裸仓库**（一次提交都没有）跑 `git clone` 会得到
> `warning: You appear to have cloned an empty repository.`，随后 `setup-log-repo.ps1`
> 在没有 HEAD 的 clone 上工作——这条组合没有被测试覆盖过。若绑定或首次 push 报错，
> 先给裸仓库灌一个初始提交再重来：
>
> ```powershell
> git clone D:\soak\logrepo.git D:\soak\seed; cd D:\soak\seed
> Set-Content README.md 'soak log repo' -Encoding utf8
> git add README.md; git commit -m 'init'; git push origin HEAD:refs/heads/main
> ```

---

## 1. 两台机器的部署

| | A 机 | B 机 |
|---|---|---|
| 部署目录 | `D:\soak\keeper-A` | `D:\soak\keeper-B` |
| 计划任务名 | `CQKSoak-A` | `CQKSoak-B` |
| `leader.label` | `SOAK-A` | `SOAK-B` |

1. 把 `codex-quota-keeper/` **整份复制**到上表目录（两份必须来自同一个 commit）。
2. 每台机器准备 §4 的那份 soak 配置，存为 `<部署目录>\config.json`。
3. 日志仓库 clone 到两台机器的同一路径 `D:\soak\logrepo`：
   ```powershell
   git clone D:\soak\logrepo.git D:\soak\logrepo
   ```
4. **每台机器各自绑定一次**（CQK-011：写 marker + `runtime/log-repo.json` 指纹）：
   ```powershell
   cd D:\soak\keeper-A    # B 机同理
   pwsh scripts\setup-log-repo.ps1 -RepoPath D:\soak\logrepo
   ```
   期望输出 `Bound log repo` / `repoId` / `Marker written` /
   `Allowed branches : cqk/coordination, cqk/history`。**这一步不做，后面每次同步都会
   `SYNC_FAILED repo-binding-failed`。**
5. 安装计划任务：
   ```powershell
   .\install.cmd
   ```
   安装会先做一次只读额度探测（不保存状态、不算轮询），探测到的就是 mock 的 `idle` 数据
   （primary 0 %，见 §3）。
6. 双击 `status.cmd`，两台都应显示 `Task installed=YES`、`Enabled=YES`。

> **别改 `github.coordination.branch` / `historySync.branch`**：`setup-log-repo.ps1` 的合法
> 分支白名单是写死的 `cqk/coordination`、`cqk/history`，改名会被绑定检查拒绝。

## 2. soak 配置文件（两台机器只差 3 处）

存为 `<部署目录>\config.json`。**A 机 = 第 1 台，B 机改 `task.name` 与 `leader.label`。**

```jsonc
{
  "schemaVersion": 2,
  "mode": "AutoAnchor",
  "poll":         { "intervalMinutes": 15, "minimumIntervalMinutes": 5 },
  "leader":       { "enabled": true, "label": "SOAK-A", "leaseTtlMinutes": 45, "graceMinutes": 5, "takeoverOnExpiry": true },
  "github": {
    "coordination": { "enabled": true, "repoPath": "D:/soak/logrepo", "branch": "cqk/coordination" },
    "historySync":  { "enabled": true, "push": true, "branch": "cqk/history", "eventsOnly": true }
  },
  "logging":      { "retentionDays": 30, "includeMachineLabel": false },
  "codex": {
    "command": "D:\\soak\\bin\\codex.cmd",
    "queryTimeoutSeconds": 20,
    "autoAnchor": {
      "enabled": true, "prompt": "Reply exactly OK.",
      "maxPerDay": 12, "minimumGapMinutes": 20, "keepaliveIntervalMinutes": 30,
      "anchorOnApply": false, "schedule": []
    }
  }
}
```

B 机只改这两行：`"label": "SOAK-B"`、`"task": { "name": "CQKSoak-B" }`（最后一行自己加，
放顶层）。其余完全一致，包括 `repoPath`——两台机器各自本地都有 `D:\soak\logrepo` 这个 clone，
它们通过裸仓库 `D:\soak\logrepo.git` 同步。

> **`repoPath` 用正斜杠**：值是 JSON 字符串，`"D:\soak\logrepo"` 里的 `\s` 不合法会解析失败。
> **`command` 用双反斜杠**，同理。

### 2.1 为什么这些数字

| 项 | 值 | 理由 |
|---|---|---|
| `poll.intervalMinutes` | 15 | 4 小时挂机 = 16 轮，够覆盖续租/接管/重试各 2 次以上；下限是 5 |
| `leader.leaseTtlMinutes` | 45 | **必须** ≥ `max(2×15, 15+5+5) = 30`。45 = 3 个轮询周期，既能测到「正常续租」，又能在拔网线时测到「租约过期 → 接管」。不满足关系会被配置校验直接拒绝（CQK-021） |
| `minimumGapMinutes` | 20 | 默认 300 分钟在 4 小时挂机里只会触发 0–1 次锚定，测不出东西。20 分钟 = 比 1 个轮询周期多一点，锚定后下一轮就能再看一次 |
| `keepaliveIntervalMinutes` | 30 | 兜底间隔。**校验要求 `keepalive ≥ minimumGap`**（30 ≥ 20 合法）。注意两者基准不同：keepalive 判定用的是**对齐到 30 分钟的时间槽**（eventId = `keepalive|<slotSeconds>`，epoch 取整），最小间隔用的是**距上次锚定的墙钟时间**，所以实际锚定节奏不是严格的「每 30 分钟一次」，见 §6 的判据 |
| `maxPerDay` | 12 | 原默认 6 不够：§6 正常路径 + F5/F6/F7 的锚定都算在同一个「日」额度里，达到上限后所有锚定判据都会被 `daily anchor cap reached` 挡掉。12 仍在 `>= 1` 的合法区间，且足以让一轮完整 soak 不撞顶 |
| `queryTimeoutSeconds` | 20（默认） | **别改**：锚定窗口由它推导——`execWindowMinutes = max(2, ceil(20×3/60)+1) = 2` 分钟，本地 claim TTL = `2×2 = 4` 分钟，`codex exec` 硬超时 = `max(60, 20×3) = 60` 秒。F6/F7 的判据都按这组数字写 |
| `retentionDays` | 30 | 别让 4 小时的日志被清理逻辑（`RETENTION_FAILED` 路径）在 soak 中途删掉 |

**别动 `task.name` 以外的安装相关项。** 改完任何字段都要跑一次 `apply-config.cmd`。

## 3. 让计划任务拿到 mock 的环境变量（关键步骤）

计划任务跑在用户会话里，**读不到你交互终端设的 `$env:`**。所以把三个变量写进注册表
（`Set-ItemProperty` 同时改 `HKCU:\Environment`，`Register-ScheduledTask` 用的正是这个位置）：

```powershell
$vars = @{
  CQK_MOCK_MODE = 'idle'              # 起始值必须是 idle，原因见下方说明；注入故障时再改
  CQK_MOCK_EXEC = 'ok'                # ok | fail | timeout
  CQK_MOCK_EXEC_ARGS_FILE = 'D:\soak\anchor-args.txt'   # 审计锚定到底调了几次、传了什么参数
}
foreach ($k in $vars.Keys) { Set-ItemProperty -Path 'HKCU:\Environment' -Name $k -Value $vars[$k] -Type String }
```

> **为什么起始值是 `idle` 而不是 `normal`**：`normal` 返回 primary `usedPercent=25`，
> 而周期判断模式下三个触发器全打不着——空闲判定要求**零用量**
> （否则守卫拒绝 `quota in use; idle detection only fires on an unused window`）、
> 重置触发要求 `resetsAt` 跨过当前时刻（`normal` 是固定值，永不跨）、keepalive 又要求
> **已存在一次锚定**。也就是说挂 4 小时会一次锚定都没有，§6 的锚定判据全部空转。
> `idle` 返回 primary `usedPercent=0` 且窗口不滚动，正好让**空闲判定**在第二轮命中
> （eventId = `idle|<yyyy-MM-dd>`，当天一次），之后由 keepalive 接续。
> `install.cmd` 的那次只读探测与 §6 第 1 步的安装顺序不受影响。

改完变量后**必须**重跑一次 `install.cmd`（只有重新注册才会把新值带进任务进程；
`Start-Process -UseNewEnvironment` 不行——它是从当前会话构造环境，拿不到刚写进注册表的值）。

> **soak 结束后务必删掉这三个变量**（`Remove-ItemProperty -Path 'HKCU:\Environment' -Name CQK_MOCK_*`），
> 否则以后真实 Codex 会被 `codex.command` 指回 mock、或被注入故障信号。

`anchor-args.txt` 是本单的**锚定次数真值来源**：mock 每被调用一次 `exec`，就把完整命令行
追加一行。`Get-Content D:\soak\anchor-args.txt | Measure-Object -Line` 就是真实执行次数。

## 4. 控制机（第三台/你自己的开发机都行）

两台被测机不需要任何额外工具；观察都从控制机做：

```powershell
$env:CQK_SOAK_GIT = 'D:\Program Files\Git\bin\git.exe'   # 换成你机器上 git.exe 的实际路径
cd D:\soak
git clone D:\soak\logrepo.git observer
Set-Content D:\soak\soak-watch.ps1 -Encoding UTF8 -Value @'
param([string]$Branch = 'cqk/history', [int]$IntervalSec = 15)
$git = if ($env:CQK_SOAK_GIT) { $env:CQK_SOAK_GIT } else { 'git' }
Set-Location (Join-Path $PSScriptRoot 'observer')
Write-Host "watching $Branch every ${IntervalSec}s"
while ($true) {
    $null = & $git fetch origin $Branch 2>&1
    if (Test-Path '.git\FETCH_HEAD') {
        $rev = (& $git rev-parse 'FETCH_HEAD^{commit}' 2>$null)
        if ($rev) {
            foreach ($l in (& $git ls-tree -r --name-only $rev)) {
                if (Test-Path $l) { continue }
                New-Item -ItemType Directory -Force (Split-Path $l) | Out-Null
                & $git "show${rev}:$l" | Out-File -Append -Encoding utf8 "captured.log"
                "[$(Get-Date -Format HH:mm:ss)] NEW $l"
            }
        }
    }
    Start-Sleep -Seconds $IntervalSec
}
'@
pwsh -NoProfile -File D:\soak\soak-watch.ps1 -Branch cqk/history
```

脚本每 15 秒 fetch 一次，把**没见过的新 blob** 打印出来（`Test-Path $l` 按 blob 路径去重）。
它不是日志，只是「远端有没有在动」的实时信号；真正的数据都从远端 blob 里读（§5）。

> 这台机器不跑 keeper、不设 `CQK_MOCK_*`、不注册任务。

## 5. 去哪看结果（路径与判据）

**本地**（`<部署目录>\` 下，全部 gitignored）：

| 文件 | 看什么 |
|------|--------|
| `runtime\state.json` | `role`、`heartbeat.ts`（每轮刷新）、`leader.ownerId` / `expiresAt`、`consecutiveReadFailures`、`processedEventIds`、`anchors.{day,count,lastAnchorAt}` |
| `runtime\logs\keeper-YYYY-MM-DD.jsonl` | **主证据**。一行一个事件，看 `event` / `level` / `error` / `role` / `runId` |
| `runtime\backoff.json` | `{ until, reason, setAt }`；到期后 `Get-BackoffState` 视为无退避（文件不删，靠 `until` 判断） |
| `runtime\pending-global-backoff.json` | 集群退避 marker 远程写失败时的持久化队列（CQK-024），成功投递后自动清掉 |
| `runtime\outbox\*.json` | **未推送成功的重要事件**。push 成功即被删除；断网期间它必须一直堆着 |
| `runtime\sync-state.json` | `lastSyncAt`、`sentCount`、`sent[]`（最近 100 条已发送） |
| `runtime\anchor-claims\<eventId>.json` | 本地 durable claim（CQK-023），`state` = `CLAIMED`/`COMPLETED`/`FAILED`/`EXPIRED` |
| `history\events-YYYY-MM-DD.jsonl` | **净化后的本地审计副本 —— 锚定细节只有这里（和远端 blob）有** |

> ⚠️ **锚定细节不在 `keeper-*.jsonl` 里，别在那儿找。** runner 落本地运行日志时只带
> `-ErrorText $ev.message`（`scripts/runner.ps1` 的事件循环），而锚定事件携带的是
> `reason` / `anchor` 两个键、**没有** `message`——所以 `ANCHOR_EXECUTED` /
> `ANCHOR_ABORTED` 在 `runtime\logs\keeper-*.jsonl` 里就是**光秃秃一行事件名 +
> `error: null`**，没有 `anchor` 对象。`anchor.{phase,trigger,durationSecs,execExitCode,
> verified,...}` 与 `reason` 只写进**重要事件记录**，落盘在
> `history\events-YYYY-MM-DD.jsonl` 与远端 `cqk/history` 的 blob 里。
>
> **本地那份 `history\events-*.jsonl` 与 `github.historySync.enabled` 无关**：
> `Write-HistoryEvent`（`scripts/logger.ps1:57-73`）在重要事件循环里**无条件**追加，
> `historySync.enabled` / `push` 只决定这些记录**是否再同步到远端 blob**（以及 outbox
> 是否清空）。所以关掉同步的 F6、F7 一样有**完整锚定细节**可查，缺的只是远端那一份。
> 「同步关了 ⇒ 本地没细节」是错的直觉，本单判据不依赖它。
>
> 定位方式：`Sanitize-Record`（`scripts/common.ps1:256-272`）只保留白名单键
> （`ts,event,machineId,machineLabel,role,mode,windows,anchor,error,summary,version`），
> **顶层 `eventId` 会被丢掉**，所以要按 `event` + `anchor.eventIds` 匹配。注意
> `ANCHOR_ABORTED` 的 **CLAIM 被拒**那一支用的是**单数** `anchor.eventId`
> （`auto-anchor.ps1:153-154`，只有 `phase/eventId/reason` 三个键），`REVALIDATE`
> 那一支连 `eventId` 都没有（只有 `phase/reason`）；只有真正执行过的记录才带复数
> `eventIds`（`auto-anchor.ps1:226`）。
>
> 更极端的是 `ANCHOR_SKIPPED`：它不在重要事件白名单里（见本节末），守卫原因
> **任何地方都不落盘**——只能按「事件名行出现/没出现」+「claim 文件数」+
> 「`anchor-args.txt` 行数」三者间接判定。本单下面所有涉及锚定 `reason` / `anchor.*`
> 的判据，都按这条约定去 `history\events-*.jsonl` 或远端 blob 查，不要在运行日志里查。

**远端**（在控制机 `D:\soak\observer` 里跑 git，分支名固定）：

```powershell
$env:CQK_SOAK_GIT = 'D:\Program Files\Git\bin\git.exe'   # 每台做 git 观察的机器都要设
$git = if ($env:CQK_SOAK_GIT) { $env:CQK_SOAK_GIT } else { 'git' }
cd D:\soak\observer
& $git fetch origin 'cqk/coordination'   # 租约 / 集群退避 / 锚定 claim 都在这条分支
& $git fetch origin 'cqk/history'        # 重要事件 + 每日 summary 在这条
& $git show ('{0}:coordination/lease.json' -f 'FETCH_HEAD')
& $git ls-tree -r --name-only ('{0}:cqk/history' -f 'FETCH_HEAD')
```

| 远端路径 | 分支 | 含义 |
|---|---|---|
| `coordination/lease.json` | `cqk/coordination` | 当前租约：`ownerId`/`ownerLabel`/`acquiredAt`/`renewedAt`/`expiresAt`/`version` |
| `coordination/backoff.json` | `cqk/coordination` | 集群级退避（含 `sourceOwnerId`） |
| `coordination/events/<eventId>.json` | `cqk/coordination` | 分布式锚定 CAS claim（Git 拒绝即锁） |
| `history/<date>/<machineId>/<stamp>_<EVENT>_<id>.json` | `cqk/history` | 不可变事件，每机一个目录，**不可能互相覆盖** |
| `summary/<date>/<machineId>.json` | `cqk/history` | 每日汇总，按机器隔离 |

**本地日志里该出现的事件名**（全大写，出现在 `event` 字段）：

`RUNNER_OK` `PASSIVE` `BACKOFF_SKIP` `GLOBAL_BACKOFF_SKIP` `GLOBAL_BACKOFF_PUBLISHED`
`GLOBAL_BACKOFF_RETRY_FAILED` `READ_FAILED` `SYNC_FAILED` `PREFLIGHT_FAILED`
`LEADER_CHANGED` `WINDOW_RESET_OBSERVED` `LIMIT_REACHED`
`ANCHOR_EXECUTED` `ANCHOR_ABORTED` `ANCHOR_SKIPPED` `ANCHOR_LOCAL` `ANCHOR_UNAVAILABLE`
`RUNNER_SKIPPED` `RETENTION_FAILED` `RUNNER_ERROR`

## 6. 挂机 4 小时（正常路径）

1. **先 B 机、后 A 机**各跑一次 `install.cmd`（安装本身就是第一次只读探测）。
   ⚠️ 顺序有意义：谁先注册、谁先抢到租约，本单与 §7 的全部判据都按
   **「B = LEADER、A = PASSIVE」**写（F1 只污染 B 机就是靠这条：PASSIVE 机在读额度
   **之前**就 `exit 0`，污染 A 机什么都测不出来）。万一装反了，把两台的
   `install.cmd` 按上表顺序重来一遍，或者把 §6/§7 里的 A/B 对调着看。
2. 控制机开 `soak-watch.ps1`，挂着别关。
3. **两台机器都不要锁屏/睡眠**：`powercfg /change standby-timeout-ac 0` 和
   `powercfg /change monitor-timeout-ac 0`（AC 电源下取消自动睡眠）。
4. 让 16 轮跑完。**中途什么都不用做。**

跑完立刻看这三项：

- [ ] **Leader 续租**：B 机 `state.json` 的 `role` **16 轮全程**为 `LEADER`，
      `leader.expiresAt` **每轮往后推**（每轮都续租，不是"45 分钟内不动"——TTL 45
      只是"别人多久能抢走"的上限，`graceMinutes: 5` 把活动期放宽到 50 分钟）。
      远端 `coordination/lease.json` 的 `ownerId` **始终是同一台机器**，
      `acquiredAt` 不变、`renewedAt` 每轮变。
      ⚠️ 如果 `ownerId` 在两机之间来回跳 → **失败**（租约 flapping，说明 TTL 或
      `graceMinutes` 没配够，回去核 §2.1 的关系式）。
- [ ] **PASSIVE 生效**：A 机 `role=PASSIVE`，日志每轮一条 `PASSIVE`，`error` 形如
      `lease held by SOAK-B until ...`；A 机的 `keeper-*.jsonl` 里**不应出现任何**
      `READ_FAILED` / `ANCHOR_EXECUTED`，`anchor-args.txt` 里也不应有 A 机产生的行。
- [ ] **锚定真的发生了**：`Get-Content D:\soak\anchor-args.txt` 有行。**数量按不等式判**，
      不要判「等量 / 每 30 分钟一次」：4 小时里理论上限是「空闲判定 1 次（第 2 轮）+
      keepalive 若干」，而 keepalive 走对齐时间槽、最小间隔走距上次锚定的墙钟差，两者
      基准不同，实测通常 **3–5 次**。判据是 `anchor-args.txt` 行数 ≥ 2（至少证明
      空闲判定 + 一次兜底都通了），且**每一行**都能在 B 机 `history\events-*.jsonl` 里
      找到对应的一条 `ANCHOR_EXECUTED`（反过来不必一一对齐，见 §5 说明）。
      `keeper-*.jsonl` 里那些 `ANCHOR_EXECUTED` 行本身 `error: null`、没有 `anchor`
      字段——**别拿它们的行数当锚定次数**，真值是 `anchor-args.txt`。
      逐条去 `history\events-*.jsonl` 对细节：`anchor.phase=ANCHORED`、
      `anchor.trigger`（第一条应为 `idle`，其后为 `keepalive`）、`anchor.execExitCode=0`、
      `anchor.verified=true`、`startedAt`/`endedAt`/`durationSecs` 齐备。
      同时远端 `coordination/events/` 下每个用过的 eventId 都有一个 `state=COMPLETED` 的 blob。
- [ ] **History 有东西**：`cqk/history` 分支上 `history/<date>/<machineId>/` 有
      `..._ANCHOR_EXECUTED_....json`（`summary/<date>/<machineId>.json` 至少 B 机一份）。
      ⚠️ 正常路径**不该**期待 `..._LEADER_CHANGED_....json`：`Get-LeaderChangedEvent` 只在
      「上一轮 owner 与本轮 owner 不同且都非空」时产生事件，而 B 机首轮 `PreviousOwnerId`
      为空 → 不产生。它是 F7（真实接管）的判据，不是这里的。
- [ ] **outbox 清空**：两台机器 `runtime\outbox\` 都是**空目录**（有货说明 push 一直失败，
      去看 `SYNC_FAILED`）。
- [ ] **零异常**：日志里搜 `RUNNER_ERROR`（未捕获异常，带 `文件:行号`）= 0 命中；
      `RETENTION_FAILED` = 0；`PREFLIGHT_FAILED` = 0；`consecutiveReadFailures` 一直为 0。

## 7. 故障注入（挂机期间或之后做，逐个做、做完恢复）

> 每次注入前记下当前时间，做完在日志里按时间段查。改 `CQK_MOCK_MODE` 之后**必须重跑
> `install.cmd`**（§3），否则任务进程还是老值。

### F1 · 429 退避 + 集群退避（§21「429」）

```powershell
Set-ItemProperty 'HKCU:\Environment' CQK_MOCK_MODE -Value 'rate-limit'
cd D:\soak\keeper-B; .\install.cmd          # 只污染 B 机，A 机留作对照
```

期望（全部要在日志/文件里看到实物）：

- [ ] B 机 `READ_FAILED`，`errorKind` 非 `AUTH_ERROR`，`error` 含 `429`/`usage limit`。
- [ ] `runtime\backoff.json` = `reason:"429"`，`until ≈ setAt + 60 分钟`。
- [ ] 之后每轮一条 `BACKOFF_SKIP`，`error` = `until <时间> (429)`。
- [ ] **退避期间仍在维护协调**（CQK-024）：`state.json` 的 `role=BACKOFF`、`heartbeat.ts`
      每轮刷新，远端 `lease.json` 的 `renewedAt` **继续往前走**，A 机**不会**趁隙抢成 Leader。
- [ ] 远端 `coordination/backoff.json` 出现 `until`、`reason:"429"`、`sourceOwnerId` = B 机 id。
- [ ] **A 机也被集群退避挡住**：A 机日志出现
      `GLOBAL_BACKOFF_SKIP`，`error` = `until <时间> (429, set by <B 机 machineId>)`。
      ⚠️ 这是「租约接管绕不过退避」的硬判据，A 机若照常轮询 = **失败**。
- [ ] 恢复（`CQK_MOCK_MODE='idle'` + 重跑 install）后，等 `until` 过期，下一轮变回 `RUNNER_OK`。
      **不要手动删 `backoff.json`**——要测的就是它自己到期（`until <= now` 即视为无退避）。
      60 分钟等不了，可以只做一次 `network`（F2，10 分钟）确认恢复路径，429 只确认设置正确。
- [ ] **退避期间 history 不再推送**（结构性判据，不是异常）：三条退避分支
      （`BACKOFF_SKIP` / `PASSIVE` / `GLOBAL_BACKOFF_SKIP`）都在**读取之前**就 `exit 0`，
      而 outbox / history 同步在脚本**最后**——所以退避的 60 分钟里远端 `cqk/history`
      完全不动。协调仍照 F1 上面那条判据继续（这是 CQK-024 有意为之的不对称）。

### F2 · 读取失败分类：网络故障 ≠ 429（§21「恢复」的前半）

```powershell
Set-ItemProperty 'HKCU:\Environment' CQK_MOCK_MODE -Value 'network-error'   # 报错文本里就带 "rate limit" 字样
cd D:\soak\keeper-B; .\install.cmd
```

- [ ] `backoff.json` 的 `reason` 是 **`network`**、时长 **10 分钟**，不是 429/60 分钟。
      （曾经因为 app-server 包装文本含 "rate limits"，断网被判成 429 → 白等一小时；
      这条是回归判据。）
- [ ] 远端 `coordination/backoff.json` 的 `reason` = `network_error`。

### F3 · Git 临时断网（§21「Git 临时断网」）—— 只掐协调，不动 Codex

```powershell
# B 机，保持 600 秒：远端读不到，但 mock 是本地的、额度读取照常成功。
# 路径必须用**这台机器**解析到的 git.exe —— keeper 是用 Get-Command git 找 git 的
# （scripts/github-sync.ps1 的 Get-GitExe），规则打在别的 git.exe 上等于没掐断。
$gitExe = (Get-Command git).Source
$gitExe                                   # 先打印出来确认，再往下贴
New-NetFirewallRule -DisplayName 'CQK SOAK block git' -Direction Outbound -Program $gitExe -Action Block
# 恢复： Remove-NetFirewallRule -DisplayName 'CQK SOAK block git'
```

> 为什么不用「拔网线」：`task.runIfNetworkAvailable=true`（默认）会让计划任务在离线时
> **根本不启动**，你什么日志都看不到。按进程掐 git 才能精确造出「Codex 可达、协调不可达」。
> mock 是本机进程、不联网，所以额度读取不受影响 —— 这正是 DEGRADED 的定义。

- [ ] B 机 `role=DEGRADED`。
      > `keeper-*.jsonl` 每一行的 `role` 字段就是证据：`Select-String '"role":"DEGRADED"'`
      > （日志行是 `ConvertTo-Json -Compress`，键值之间没有空格，别写 `"role": "DEGRADED"`）。
      > 但 ⚠️ **`remote coordination unavailable: unreachable` 这句话在实机上无处可看**——
      > `election.reason` 全仓库只被消费一次（`runner.ps1:134` 的 `PASSIVE` 分支日志），
      > DEGRADED 分支既不打日志、`state.json` 里也没有存 reason 的字段
      > （`New-KeeperState`，`state-machine.ps1:27-45`）。这一条只看**角色**：
      > `Get-Content D:\soak\keeper-B\runtime\state.json` 的 `"role": "DEGRADED"`
      > （state.json 是 `Write-JsonFileAtomic` 写的**非压缩** JSON，键值之间**有**空格），
      > 或 `status.cmd` 的「降级运行」。想间接印证断网，看
      > `SYNC_FAILED (…)` 行（`runner.ps1:311`）——`git fetch` 失败会把它写进
      > `keeper-*.jsonl`。**DEGRADED 仍会做只读额度轮询**（设计如此，`runner.ps1:157`），
      > 但绝不会锚定。
- [ ] 断网期间 B 机 `runtime\outbox\` 堆文件；**没有任何**远端提交（`observer` 里
      `git log FETCH_HEAD` 的 HEAD 不动）。
- [ ] 恢复防火墙后，下一轮 outbox 里的文件全部落到远端 `history/<date>/<B机machineId>/`，
      路径与断网期间写的一一对应（不可变路径，无覆盖），随后 `outbox\` 清空。
- [ ] `state.json` 回到 `role=LEADER`。
- [ ] 锚定在 DEGRADED 下被**守卫层**拦掉（B 机若在断网期间撞上锚定窗口）：
      `keeper-*.jsonl` 里出现 `ANCHOR_SKIPPED` 行——**只有事件名，没有原因**（见 §5 约定：
      `ANCHOR_SKIPPED` 不在重要事件白名单里，守卫 reason 任何地方都不落盘）。所以这条只能
      三项间接判：**有 `ANCHOR_SKIPPED` 行** + **`runtime\anchor-claims\` 不新增文件**
      （守卫在创建 claim 之前就拒了）+ **`anchor-args.txt` 一行都不许多**。
      原因应是 `machine does not hold the leader lease`（DEGRADED 角色不持有租约）。
      > 顺带记一句实现事实，免得找错东西：守卫另有
      > `remote coordination unreachable (<r>); fail closed` 这条 fail-closed 原因，
      > 但 runner 调用 `Invoke-AutoAnchorIfNeeded` 时**没有**传 `-RemoteUnreachable`
      > （`scripts/runner.ps1` 的锚定钩子），`Test-ShouldAnchor` 也拿不到它，
      > 所以**实机 soak 里这条永远不会命中**，DEGRADED 一律由「不持有租约」拦下。
      > 想在真实断网下看到 unreachable 措辞，只能自己复算一次选举：
      > `pwsh -NoProfile -Command ". D:\soak\keeper-B\scripts\common.ps1; …"` 走
      > `Get-RemoteLease`，或在断网状态下手工跑一次 `git fetch` 看失败输出——
      > **keeper 自己的日志里不会出现这句话**（见上面第一条判据的 ⚠️）。
- [ ] `phase=REVALIDATE` 那条分支（claim 已拿到、租约在两步之间被抢走）在实机上**不可稳定复现**：
      守卫与重验证都调 `Invoke-LeaderElection`，中间只隔几秒，没有外部手段能让远端「前一秒可达、
      后一秒不可达」。所以本单用 F7 的双机接管来覆盖同一语义（接管必须完整，不能半截 Leader），
      精确分支由 `tests/auto-anchor.test.ps1` 的 revalidate 用例覆盖。打不到**不算 soak 失败**，
      在 §10 记一句「实机未观测到 REVALIDATE」即可。

### F4 · History 重试（§21「History 重试」）—— 只让 history push 失败

```powershell
Set-ItemProperty 'HKCU:\Environment' CQK_MOCK_MODE -Value 'limit-reached'   # 每轮都产生重要事件
cd D:\soak\keeper-B; .\install.cmd
# B 机：只锁死 history 分支，coordination 与 A 机都不受影响
New-Item -ItemType File 'D:\soak\logrepo.git\refs\heads\cqk\history.lock' | Out-Null
# 恢复： Remove-Item 'D:\soak\logrepo.git\refs\heads\cqk\history.lock' -Force
```

- [ ] B 机 `SYNC_FAILED`，`error` 含 `push-rejected`（后面跟的是**脱敏后**的 git stderr）。
- [ ] `runtime\outbox\` **不清空**：事件文件一直留着（这就是 durable outbox 的意义）。
- [ ] 协调不受影响：远端 `lease.json` 的 `renewedAt` 照常刷新，A 机仍 `PASSIVE`。
- [ ] 解除后（删掉 `.lock`）积压的 outbox **一次性补齐**，`sync-state.json` 的
      `sentCount` 增加对应数量，`outbox\` 清空。⚠️ 补齐只会发生在 **Leader** 上——
      同步块在 PASSIVE / 退避分支里根本走不到（F1 最后一条判据）。若这期间 B 机被
      F7 抢走了租约，得等它变回 LEADER 才会补。
- [ ] 恢复 `CQK_MOCK_MODE='idle'`。

> **为什么用 `limit-reached` 而不是 `reset`**：`reset` 的 `resetsAt` 是**写死的**
> `1900000000`，重置检测要求 `prev.resetsAt < nowEpoch < cur.resetsAt`，所以整个 soak
> 期间它**最多只触发一次**（第一次读到就进 `processedEventIds`），随后每轮都是普通快照
> —— 拿它「每轮产生重要事件」是错的。`limit-reached` 返回 primary 100 % +
> `rateLimitReachedType='primary'`，`LIMIT_REACHED` 在**每一次**成功读取上都会产生，
> 而且它**不设退避**（那是读取失败分支的事），所以 outbox 真的会一轮一堆积。
> 顺带两个连带效果，别当成 bug：LIMIT_REACHED 会让锚定被
> `open error present: LIMIT_REACHED` / `previous state shows rate limit reached` 挡住
> （F4 期间本来就不该有锚定），且 `LIMIT_REACHED` 在白名单里、会进 history。
>
> **为什么用 `.lock` 文件而不是删分支 + `receive.denyDeletes`**：`update-ref -d` 之后
> keeper 的 `Get-RemoteBranchBlob` 会把「fetch 失败但 ls-remote 成功」判成
> `branch-missing` 并**当作正常**（`$parent = $null`），下一次 push 就变成**创建根提交**——
> 而创建分支不是删除，`denyDeletes` 拦不住，同步会直接成功，故障注入等于没做。
> `refs/heads/cqk/history.lock` 会让 git 拒绝任何对该 ref 的更新，push 真失败；
> 它只影响这一条 ref，coordination 分支不受牵连。

### F5 · 锚定执行失败（fail-closed，不重试）

**判据全部在 `history\events-*.jsonl`（或远端 blob），不在 `keeper-*.jsonl`——见 §5 那条约定。**

```powershell
# B 机。先记下当前行数（注入前基线）
$base = (Get-Content 'D:\soak\anchor-args.txt' -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
Set-ItemProperty 'HKCU:\Environment' CQK_MOCK_EXEC -Value 'fail'
# 让 B 机变回「能锚定」：清掉 LIMIT_REACHED 遗留标记（F4 之后必须有这一步，否则下一轮
# 仍被 previous state shows rate limit reached 挡住）。state.json 里没有「只删某个键」的
# 安全做法（它是 keeper 自己写的，手改 JSON 容易写出 keeper 不认的形态），这里直接删整个
# 文件 = 回到 first observation，keeper 下一轮会重建。**只删 state.json，`runtime\machine.json` 必须留着。**
Remove-Item 'D:\soak\keeper-B\runtime\state.json' -Force   # 备份可先 Copy-Item 一份
# 立刻强制一次锚定：exec 失败也计入每日上限，所以用 anchorOnApply 驱动、**跑完立刻改回 false**
# （留着 true 会让每次 apply/install 都吃掉一个名额，maxPerDay=12 经不起这么造）。
# 这一步同时把 CQK_MOCK_EXEC='fail' 带进子进程：强制锚定是从**当前交互终端**里
# Start-Process 起来的（install.ps1 的 Invoke-ForcedAnchorIfRequested），所以继承本终端
# 的 $env:，**不需要** §3 那套 HKCU + install.cmd 绕路；定时轮询那条路才需要（见下）。
Set-ItemProperty 'HKCU:\Environment' CQK_MOCK_MODE -Value 'idle'   # 顺带把 F4 的 LIMIT_REACHED 关掉
# ↓ 本终端立即生效
$env:CQK_MOCK_MODE='idle'; $env:CQK_MOCK_EXEC='fail'
# ↓ 改配置并触发强制锚定（控制台会打印 `Forced anchor    : STARTED`）
(Get-Content 'D:\soak\keeper-B\config.json' -Raw) -replace '"anchorOnApply":\s*false','"anchorOnApply": true' | Set-Content 'D:\soak\keeper-B\config.json' -NoNewline
cd D:\soak\keeper-B; .\apply-config.cmd
# ↓ 一分钟内再来一次，验证「同一分钟内不重复」
cd D:\soak\keeper-B; .\apply-config.cmd
# ↓ 必须等下一分钟再做第三次：force 的 eventId = SHA256("force|<按分钟取整的 epoch>")，
#   新的一分钟 = 新的一轮尝试（这是预期行为，不是重试）。不要整点等，最长要等 59 分钟。
Start-Sleep -Seconds 60
$env:CQK_MOCK_EXEC='ok'      # 恢复，第三次不再需要它失败
cd D:\soak\keeper-B; .\apply-config.cmd
# ↓ 收尾：改回 false 并应用（这一次不会再强制锚定）
(Get-Content 'D:\soak\keeper-B\config.json' -Raw) -replace '"anchorOnApply":\s*true','"anchorOnApply": false' | Set-Content 'D:\soak\keeper-B\config.json' -NoNewline
cd D:\soak\keeper-B; .\apply-config.cmd
```

> ⚠️ 为什么用 `apply-config.cmd`：`install.cmd` 也会打印 `Forced anchor    : STARTED`
> （两个 `.cmd` 都用 `pwsh -File` 起对应的 `.ps1`，都命中「非 dot-source」分支），但
> `install.ps1` 在注册任务前还要跑 `Invoke-Preflight` + 一次只读额度探测，多花十几秒且没有
> 新增信息。**F5/F6 的锚定一律用 `apply-config.cmd` 驱动。**
>
> 计时坑：两个 `.cmd` 结尾都有 `pause >nul`——ps1 跑完回到 cmd 就**卡在按键上**，
> 你按下任意键之前同终端跑不了下一条命令。强制锚定本身是 ps1 里 `Start-Process` 即发即忘
> 起来的（在 `pause` **之前**），所以「第 3 次要在不同分钟」的预算是从**打印那一行**开始算，
> 但每一轮 `pause` 都会吃掉这段墙钟时间：**打完字就按键**，别停在屏幕上读输出。
>
> 第三轮（`CQK_MOCK_EXEC` 已恢复 `ok`）顺手把 **§6 的锚定判据补回来**：删 state.json 之后
> 空闲判定只有「第二次轮询」才触发，而 F5 这一段只在第 1 轮跑过，若不补这一轮，§6 的
> 「锚定真的发生了」会一直不成立（keepalive 分支要求「已有首次锚定」，而它没有）。

- [ ] **失败的那一轮**（按 `anchor.eventIds` 匹配，`history\events-*.jsonl` 里**恰好一条**）：

```powershell
$ev = Get-ChildItem 'D:\soak\keeper-B\history\events-*.jsonl' | Sort-Object Name
Get-Content ($ev[-1].FullName) | ForEach-Object { $o = $_ | ConvertFrom-Json
  if ($o.event -in 'ANCHOR_EXECUTED','ANCHOR_ABORTED') {
    [pscustomobject]@{ ts=$o.ts; event=$o.event; phase=$o.anchor.phase; trigger=$o.anchor.trigger
      exit=$o.anchor.execExitCode; verified=$o.anchor.verified; ids=($o.anchor.eventIds -join ',')
      err=$o.error } } } | Format-Table -AutoSize
```

  失败那行：`event=ANCHOR_ABORTED`、`anchor.phase=ABORTED`、`anchor.execExitCode=1`（mock
  `CQK_MOCK_EXEC=fail` 就是 `exit 1`）、`error` = `exec failed (1)`、`anchor.trigger=force`、
  `anchor.startedAt`/`endedAt`/`durationSecs` 齐备。
  > `verified` 这一项**两种结果都可能出现**（VERIFY 是执行之后的**第二次独立额度读取**，
  > `auto-anchor.ps1` 里 `Invoke-CodexRateLimitsRead` 在 exec 之后再来一次；exec 退出码与它
  > 无关，所以它通常仍为 `true`）。`phase` 由 `verified -and exec.ok` **联合**决定，本用例的
  > `ABORTED` 是 exec 那一项带来的。**不要因为 `verified=true` 却 `ABORTED` 就判失败。**
- [ ] **claim 终态 = `FAILED`**：`cqk/coordination` 的 `coordination/events/<eventId>.json`
  （或本地 `runtime\anchor-claims\<eventId>.json`，取决于是否单机）里
  `state=FAILED`、`result=exec failed (1)`、`completedAt` 非空。
- [ ] **at-most-once（按 eventId 判，别按「不增行」判）**：上面 `ANCHOR_ABORTED` 那一条的
  `anchor.eventIds` 里每个 id，在**整份** `history\events-*.jsonl`（含 F5 之前的所有文件）里
  最多只出现一次锚定执行记录 → 失败的 eventId 绝不第二次执行。
  同一分钟内的第二次 `apply-config.cmd` 必须**没有**产生锚定记录（守卫以
  `forced anchor already executed this minute` 拒掉，这条原因**不落盘**，所以判据是
  「那一分钟没有新的锚定记录」而不是「有这条原因」）。
  `anchor-args.txt` 的期望行数是 **`$base + 2`**（两个不同分钟的 force 槽各 **1 行**，
  同一分钟内那次重复被 `forced anchor already executed this minute` 挡住）。
  > ⚠️ **`+2` 不是 `+1`**：mock `exec` 的 `fail` 分支是**先把整行参数追加进
  > `CQK_MOCK_EXEC_ARGS_FILE`、再 `exit 1`**，所以失败的那次同样占一行——它标记的
  > 是「模型调用确实发生过、确实花了额度」，这正是 fail-closed 不重试的意义。多出来的
  > 行 = 同一 eventId 被执行了两次 = **失败**；行数比 `+2` 还多 = 重复执行 = **失败**。
- [ ] 定时轮询那条链路的注入才需要 `install.cmd` 重注册（计划任务看不到交互 `$env:`，见 §3）。
      本轮只注入 `CQK_MOCK_EXEC='fail'`、不改 `CQK_MOCK_MODE`（`idle` 的快照是
      `rate_limit_reached_type=null`，下一轮轮询不会被 `previous state shows rate limit reached` 挡住）。
- [ ] **别删错东西**：这里删 B 机 `state.json` 是**故意的**，`runtime\machine.json` 必须留着
      （删了它 = 新机器身份，远端已有 claim 的 `ownerId` 会对不上，还会被 `install.ps1` 的
      机器身份变更检查警告）。此时 B 机的 `anchor-claims\` 应已无 `CLAIMED` 残留（有就先按 F6
      的办法处理，否则那个 id 永远执行不了；不同分钟的 force 槽是不同 id，不受影响）。

### F6 · LOCAL_ONLY crash claim（§21 明确要求，A 机做）

把 **A 机**改成单机：`github.coordination.enabled=false`、`github.historySync.enabled=false`
→ `apply-config.cmd`。单机下 `role` **仍是 `LEADER`**（选举里没有 `LOCAL_ONLY` 这个角色值，
它是 `role='LEADER'` + `localOnly=true`，`leader-lease.ps1`），锚定改走本地
`runtime\anchor-claims\`（CQK-023）。

**注入方式 = 手工预埋一个 `CLAIMED` 残留文件**，等价于「exec 已经跑完、但状态落盘之前进程
被杀」留下的痕迹。为什么用预埋而不是真造崩溃：脚本里**没有**任何崩溃注入口
（`tests/fixtures/mock-appserver.ps1` 的模式列表里没有 `crash-on-read` 之类），而计划任务的
宿主是 `svchost`，`Stop-Process` 打不到那一轮 runner；预埋是唯一**确定性**的做法，且它复现的
状态与真崩溃逐字节相同（claim 文件本来就只在那两次写盘之间变化）。

claim 文件必须是 8 个键的完整记录（`anchor-claim.ps1` 里 `New-AnchorClaimRecord` 的形状），
`eventId` 用 A 机**马上就要请求**的那个：把 `anchorOnApply` 打开 → `apply-config.cmd` 会强制
一次锚定，其 eventId = `SHA256("force|<按分钟取整的 epoch>")`。

**顺序很要紧：预埋必须在同一个终端、`apply-config.cmd` 之前、且落在同一个 60 秒槽内**
（预埋用的槽和锚定实际用的槽必须是同一个，否则拦不住；60 秒是从「算出 `foreach` 那一行」
到「`apply-config.cmd` 打印 `Forced anchor` 那一行」的总耗时预算，别在两条命令之间停下来读表）。
先确认 `apply-config.cmd` 的输出里有 `Forced anchor    : STARTED`——打印 `no (...)` 说明
`mode` / `autoAnchor.enabled` 不对（两种 skip 原因分别是 `codex.autoAnchor not enabled` 与
`anchorOnApply not enabled`），锚定根本没跑，判据全是假通过：

```powershell
# A 机，同一个终端窗口里连着跑
. D:\soak\keeper-A\scripts\common.ps1                       # Get-Sha256Hex / ConvertTo-EpochSeconds 都在这里
. D:\soak\keeper-A\scripts\anchor-claim.ps1                 # Read-LocalAnchorClaim = 产品自己的判定函数（它会自动带上 common/github-sync）
$env:CQK_MOCK_MODE='idle'; $env:CQK_MOCK_EXEC='ok'          # 强制锚定继承本终端 $env:（见 F5 说明）
$claimDir = 'D:\soak\keeper-A\runtime\anchor-claims'
# eventId 必须与 keeper 自己算的**逐字节相同**：它是 `SHA256("force|<minuteSeconds>")`，
# 而 minuteSeconds = floor(ConvertTo-EpochSeconds(now)/60)*60（`state-machine.ps1:163-169`）。
# ⚠️ 不要用 [DateTimeOffset]::UtcNow：`ConvertTo-EpochSeconds`（`common.ps1:194-197`）是
# `[DateTimeOffset]::new($Value.ToLocalTime())`，把**本地时钟当 UTC** 折成 epoch——在 UTC+8
# 机器上与真 epoch 差 8 小时。自己换算法就会算出另一个 id，预埋文件拦不住任何东西，
# 判据全假通过。所以这里直接调 keeper 自己的两个函数，别自己拼。
$minute = [long]([Math]::Floor((ConvertTo-EpochSeconds (Get-Date)) / 60) * 60)
$id    = Get-Sha256Hex "force|$minute"
$claim = Join-Path $claimDir "$id.json"
# 与 New-AnchorClaimRecord（`anchor-claim.ps1:44-65`）同形状：schema 是**整数 1**，不是字符串；
# 时间戳格式 = Get-IsoTimestamp 的 `yyyy-MM-ddTHH:mm:sszzz`（带本地时区偏移，不是 Z 结尾）。
$now   = Get-IsoTimestamp
$machineId = (Read-JsonFile 'D:\soak\keeper-A\runtime\machine.json').machineId
@{ schema=1; eventId=$id; state='CLAIMED'; ownerId=$machineId
   claimedAt=$now; claimExpiresAt=$now; completedAt=$null; result=$null } |
  ConvertTo-Json -Depth 3 -Compress | Set-Content $claim -Encoding UTF8
# 回读自检：必须走 keeper **自己的判定函数**，不要只信泛用的 Read-JsonFile。
# Read-JsonFile → ConvertFrom-JsonSafe 对解析失败/全空白一律静默返回 $null；
# 读不回 CLAIMED 就说明预埋形态不对，先别往下跑。
$back = Read-JsonFile $claim
if ($back -isnot [hashtable] -or $back.state -ne 'CLAIMED') { throw "Read-JsonFile 读不回来（state=$($back.state)）" }
$j = Read-LocalAnchorClaim -KeeperRoot 'D:\soak\keeper-A' -EventId $id
if (-not $j.reachable) { throw "产品判定为 store unreadable —— 预埋文件 keeper 解析不了，F6 会是假通过" }
if (-not $j.exists -or [string]$j.record.state -ne 'CLAIMED') {
    throw "预埋文件没被认成 CLAIMED（reachable=$($j.reachable) exists=$($j.exists) state=$($j.record.state)），锚定不会走 CLAIMED 拦截分支"
}
"预埋槽位：$id"     # 记下这一行，下面判据要用
(Get-Content 'D:\soak\keeper-A\config.json' -Raw) -replace '"anchorOnApply":\s*false','"anchorOnApply": true' | Set-Content 'D:\soak\keeper-A\config.json' -NoNewline
cd D:\soak\keeper-A; .\apply-config.cmd          # 期望 `Forced anchor : STARTED`
# ↓ 紧接着看结果（见下）；然后收尾
(Get-Content 'D:\soak\keeper-A\config.json' -Raw) -replace '"anchorOnApply":\s*true','"anchorOnApply": false' | Set-Content 'D:\soak\keeper-A\config.json' -NoNewline
cd D:\soak\keeper-A; .\apply-config.cmd
```

> **为什么这三条细节决定 F6 的真假**：
>
> - **`schema` 与时间戳格式**：keeper 自己写的是整数 `schema = 1`（`anchor-claim.ps1:56`）和
>   `zzz` 偏移时间戳。预埋成 `'cqk-anchor-claim/1'` 或 `...Z` 不影响本判据（拦截只看
>   `state` 与 `ownerId`），但会让 F6 结束时的截图/记录与真实残留对不上，事后复盘会误判。
> - **编码**：keeper 的本地读路径（`Read-AnchorClaimRecord`，`anchor-claim.ps1:95`：
>   `File.Open(..., Read, FileShare.ReadWrite)` + `StreamReader(..., detectEncodingFromByteOrderMarks: $true)`
>   → `ConvertFrom-JsonSafe`）**按 BOM 自动识别编码**：UTF-8 无 BOM、UTF-8 带 BOM（5.1 的
>   `-Encoding UTF8` 就是这种）、以及 `Out-File -Encoding unicode`（UTF-16 LE **带** BOM）
>   都读得回来，PS 5.1 与 PS 7 实测一致——所以照抄上面的 `-Encoding UTF8` 不会翻车。
>   真正会翻车的是**内容不是 keeper 认的那个对象**：文件有字节、但 `state` 读不成
>   `CLAIMED` 时，两个运行时的表现还**不一样**（手写无 BOM 的 UTF-16 是这类里最阴的：
>   5.1 报 `claim store unreadable; fail closed`（`:202`，`reachable=$false`，`:135`），
>   PS 7 却会把 NUL 串解析成键名全是空字符的垃圾 hashtable，文案变成
>   `event already  (by ); no retry`——两条都不是 CLAIMED 拦重跑，但都表现为
>   「锚定没执行」，肉眼极像判据通过）。这就是上面回读自检要**直接调产品函数**、
>   并且判到 `record.state -eq 'CLAIMED'` 与 `record.ownerId` 非空的原因：只测
>   「读没读回来」抓不到 PS 7 那条。
> - **尾换行与「别把内容写空」**：加不加尾换行都能读回来（`ConvertFrom-JsonSafe` 会容忍空白），
>   保留只是为了与 `Write-AnchorClaimRecordJson`（`:88-93`，UTF8 无 BOM + `[Environment]::NewLine`）
>   字节形态一致。但**别把内容本身写空**：0 字节 / 全空白文件是 keeper 认可的**有效 claim**
>   ——`CreateNew` 才是互斥步骤，文件存在即已占坑，所以它报
>   `event already CLAIMED (by ); no retry`（`:203-205`，owner 为**空**）。
>   这**不会**触发 `claim store unreadable`，因而下面「含 `claim store unreadable` 即不通过」
>   那条反例判据抓不到它：兜住它的是「`by` 后面必须是 A 机真实 machineId」。空 owner =
>   你预埋了个空文件，等于没测到 CLAIMED 拦重跑，判据照样**不通过**。

- [ ] **被拦下**：那一轮的锚定没有执行——`anchor-args.txt` **不多一行**（与预埋前的行数相同）。
      这是主判据，但单独看它**不够**（上面两条坑里 `'claim store unreadable; fail closed'` 与
      空 owner 的 `already CLAIMED (by )` 同样表现为不多一行），必须和下面三条一起成立。
- [ ] `Get-ChildItem 'D:\soak\keeper-A\runtime\anchor-claims' | Measure-Object | % Count`
      **文件数不变**（预埋的那个还在，既没被覆盖也没被删）。
- [ ] 该 id 的 claim 文件仍是 `state=CLAIMED`、`result` 仍为 `null`
      （`Finalize-LocalAnchorEvent` 只接受 `CLAIMED → 终态`，而拒绝路径根本不会走到它：
      `Claim-LocalAnchorEvent` 在 `exists` 就直接 return，不创建也不改写：`anchor-claim.ps1:203-205`）。
- [ ] 本地运行日志 `runtime\logs\keeper-*.jsonl` 里那一轮有 **`ANCHOR_ABORTED` 事件名行**
      （`error: null` 是正常的，见 §5：锚定事件只带 `reason` 不带 `message`）。
      **完整原因文本一律去 A 机自己的 `history\events-<日期>.jsonl` 查**——与 historySync 无关，
      `Write-HistoryEvent`（`logger.ps1:57-73`）无条件落盘（见 §5）。期望**恰好一条**：
      `event=ANCHOR_ABORTED`、`anchor.phase=CLAIM`、**单数** `anchor.eventId` = 上面记下的 `$id`
      （这一支只有 `phase/eventId/reason` 三个键，没有复数 `eventIds`，`auto-anchor.ps1:153-154`）、
      `error` = `event <id> not claimed: event already CLAIMED (by <A 机 machineId>); no retry`。
      **`by` 后面必须是 A 机真实 machineId**：空串（`(by );`）说明你预埋的文件是 0 字节/全空白，
      keeper 走的是「文件存在即占坑、owner 未知」的合成记录分支（见上），同样不算通过。
      按 `anchor.eventId -eq $id` 过滤而不是全文搜 `CLAIMED`，否则会命中上一步你自己写的
      `Read-JsonFile` 打印/别的记录。查询写法：
      ```powershell
      Get-Content 'D:\soak\keeper-A\history\events-<日期>.jsonl' | ForEach-Object {
          $r = $_ | ConvertFrom-Json
          if ($r.event -eq 'ANCHOR_ABORTED' -and $r.anchor.eventId -eq $id) { $r | Select-Object ts, event, error }
      }
      ```
      同一次锚定尝试**不应**出现 `ANCHOR_EXECUTED`（`$claimed.Count -eq 0` 直接 return，
      `auto-anchor.ps1:157`）。也**没有** `ANCHOR_SKIPPED`：`ANCHOR_SKIPPED` 事件名确实存在
      （§5 事件名表里就有，守卫拒绝与 pre-exec skip 都用它），但 **claim 被拒**这一支走的是
      `ANCHOR_ABORTED`（`auto-anchor.ps1` 里 `ANCHOR_SKIPPED` 只出现在 prompt 白名单与
      找不到 codex 两处），所以此处找 `ANCHOR_ABORTED`。
- [ ] **如果 history 里那条的 `error` 含 `claim store unreadable`**：判据**不通过**（不是
      「换个原因也行」）。说明预埋文件keeper 读不回来，本次没测到 CLAIMED 拦重跑；按上面的
      编码/形状清单重做一遍。
- [ ] **残留 = 预期，不是脏数据**：`CLAIMED` 是「结果不确定」的阻塞标记，**不看
      `claimExpiresAt`、保留期扫描也永不清理它**（`anchor-claim.ps1` 头部注释：retention
      只清 `COMPLETED/FAILED/EXPIRED`）。所以它会一直挡住这个 eventId。
- [ ] **恢复（不做这条 §6 永远过不了）**：手工删掉预埋的那**一个**文件
      `Remove-Item $claim -Force`，然后按下面的收尾步骤重入。
- [ ] **A 机收尾：保持单机、什么都不改。** 这一段刻意**不**把 A 改回多机：
      - F6 期间 A 机 `github.historySync.enabled=false`，outbox 会攒着不丢、也不会污染裸仓库；
        把它改回 `true` 会**补推**这一整段攒下的记录（含 F6 那些 `ANCHOR_ABORTED`），
        与 §5 的「远端 blob 只应有正常轮询」判据对不上，也容易和 B 机的 history 提交混在一起。
      - 若想看远端 blob 里也有一份完整细节：另开一次——A 机改 `historySync.enabled=true`
        （协调仍单机），重新预埋 + `apply-config.cmd` 一遍即可（`claimExpiresAt` 早过不影响，
        见上条「残留 = 预期」）。
      - 想继续跑 F7（租约接管）**才**需要 A 机回到多机，这一步在 F7 内部完成（见 F7 第 1 段），
        不在这里做。
      - ⚠️ 无论走哪条：一旦 A 机改回多机，`D:\soak\anchor-args.txt` 里的行就是**两机混在
        一起**的（mock `exec` 不分机器写同一文件），只能按总数判、不能按机器判；且 A 机在
        F3/F4 之后可能仍持有租约、不会主动让位，收尾必须按 §6 重跑 B 机 `install.cmd`
        才能把 LEADER 还给 B。

### F7 · Lease revalidate 故障（§21 明确要求，A/B 一起）

> **A 机以「单机」状态进入本节**（F6 收尾刻意没把 A 改回多机，原因见 F6 最后一条），
> 中途才改回多机去抢租约。为什么不能像 F1–F5 那样把 A 一直当「干净的 PASSIVE 对照机」：
> `runner.ps1` 在 PASSIVE 分支是 `exit 0`（**读额度之前**就退出），所以一台「协调开、但角色
> 是 PASSIVE」的机器**永远不会**去读远端租约，也就永远不会变成 DEGRADED；要让 A 抢租约，
> 它必须先停止 PASSIVE，而 A 在 §6 之后一直停在 PASSIVE。所以顺序是：
> **A 先保持单机（不动远端）→ 把 B 打成远端不可达 → 等冻结的租约过期 → 这时才把 A 改回多机**，
> 让它在一轮 `Start-ScheduledTask` 里接管。中途 A 怎么动都不影响 B（单机不碰远端）。
>
> **代价 = A 机在本节不再是「干净的 PASSIVE 对照机」。** 这不影响 §6 与 F1/F3/F4
> 的既有判据（那些判据全部只看 B 机的 PASSIVE / 锚定；F3 的「A 机不受牵连」判的是裸仓库
> 共享的 coordination / history 分支，与 A 机自己的 `coordination.enabled` 无关，见 F3 末条）。
> 但 **A 机自己会锚定、并在改回多机时把 F6 攒下的本地 outbox 一并补推**到远端 `cqk/history`
> （含 F6 那几条 `ANCHOR_ABORTED`）——§5 的远端 blob 判据此时已经判完，不再依赖「干净」。
> 同样地，`anchor-args.txt` 从这一刻起是**两机混在一起**的（mock `exec` 不分机器写同一文件），
> 只能按总数判、不能按机器判；本节判据「多一行」是按**总行数增加**算的。
>
> ⚠️ **本节不是 §21 那条「Lease revalidate 故障」的主证据。** 见本节最后的「关于 REVALIDATE
> 分支，两句实话」。它的实际价值是**正向验证租约接管**（旧 Leader 必须退位、新 Leader 必须能续租并锚定）。

**让 B 机自己进入远端不可达**（B 机配置仍是完整多机，只是 git 出站点不通；一删防火墙规则就回到正常多机）：

```powershell
# 前置：A 机此时仍是单机（F6 收尾的状态），本步骤不动 A。
# B 机：协调开 + historySync 开 + leaseTtlMinutes 16（poll 改 5 → max(10, 15)=15 ≤ 16 才合法）
(Get-Content 'D:\soak\keeper-B\config.json' -Raw) `
  -replace '"leaseTtlMinutes":\s*45','"leaseTtlMinutes": 16' `
  -replace '"intervalMinutes":\s*15','"intervalMinutes": 5' `
  -replace '"push":\s*true','"push": false' |
  Set-Content 'D:\soak\keeper-B\config.json' -NoNewline
cd D:\soak\keeper-B; .\apply-config.cmd
# B 机：只拦 git.exe 的出站（额度读取走本地 mock，不受影响；A 机不受牵连）
New-NetFirewallRule -DisplayName 'CQK SOAK block git B' -Direction Outbound -Program (Get-Command git).Source -Action Block
# 等 B 机跑一轮（poll 已是 5 分钟），确认它变 DEGRADED
Get-Content 'D:\soak\keeper-B\runtime\logs\keeper-*.jsonl' | Select-String 'DEGRADED|READ_FAILED' | Select-Object -Last 3
```

现在远端 `cqk/coordination` 上的租约**冻结**在 B 机最后一次成功续租的时刻（TTL 16 分钟）：

- 冻结后的前 16 分钟内，A 机抢租约会**撞上未过期的 B 租约 → PASSIVE**（什么也测不到）；
- **16 分钟（+ `graceMinutes: 5`）之后**租约过期，A 机一轮 `Start-ScheduledTask` 就能接管。
  → 这里要**主动等** 16–21 分钟（`Start-Sleep -Seconds 1200`，或去干别的再回来），别以为
  「A 机跑一轮 = 接管」。

```powershell
# 等过 TTL 之后，才把 A 机改回多机并让它跑一轮。
# ⚠️ 这是一次**全局**替换：F6 之后 `"enabled": false` 恰好只有 coordination 与 historySync
# 两处（`leader.enabled`、`autoAnchor.enabled` 都是 true），所以它同时把两个都改回 true，
# 正好是完整多机形态。跑之前先确认一下命中数，别少改一个：
((Get-Content 'D:\soak\keeper-A\config.json' -Raw) | Select-String '"enabled":\s*false' -AllMatches).Matches.Count   # 期望 2
(Get-Content 'D:\soak\keeper-A\config.json' -Raw) -replace '"enabled":\s*false','"enabled": true' | Set-Content 'D:\soak\keeper-A\config.json' -NoNewline
cd D:\soak\keeper-A; .\apply-config.cmd      # 会打印任务信息 + `Forced anchor : ...`（本单 anchorOnApply=false，
                                             # 打印的是 skipped/no 那一行），结尾 pause >nul —— 按键后再往下跑
# apply-config 会把计划任务锚点重置为「此刻 +1 分钟」，A 机很快跑第一轮；等它跑完再判
Start-Sleep -Seconds 120
Start-ScheduledTask -TaskName 'CQKSoak-A'    # 手动补一轮，免得干等 15 分钟
```

- [ ] **A 机抢成 Leader**：`state.json` 的 `role=LEADER`、`leader.ownerId` = A 机 machineId，
      远端 `cqk/coordination` 的 `coordination/lease.json` 的 `ownerId` 也变成 A 机
      （`acquiredAt` 是新值—— takeover 不是续租）。
- [ ] `..._LEADER_CHANGED_....json` 落在 **A 机**的 `cqk/history` 目录下
      （`history/<date>/<A 机 machineId>/`）：`Get-LeaderChangedEvent` 只在「上一轮 owner 与
      本轮 owner 不同且都非空」时产生，所以它是**真接管**的证据（§6 正常路径里不该有它）。
      这条要求 A 机 `historySync.enabled=true`（上面的全局替换已经把它改回来了）。
- [ ] **A 机能锚定**：**A 机自己的** `history\events-*.jsonl` 里有
      `ANCHOR_EXECUTED` + `anchor.phase=ANCHORED`，且 `anchor-args.txt` **多一行**。
      用 A 机的文件判只是因为事件发生在 A 机上（各机写各机的本地 history，路径互不相通），
      与 historySync 无关——本地细节**始终**落盘，见 §5。→ 说明接管是完整的，不是半截 Leader。
      > 锚定可能比接管**晚 1–2 轮**：A 机此前一直是零用量，idle 触发要求「从未锚定 +
      > 上一轮记录也是零用量」，接管那一轮如果是它多机形态下的第一次读取，就得再等下一轮。
      > **第一轮没有不算失败**，等到第二轮再看。
- [ ] **解除拦截、让 B 机再跑一轮**：
      `Remove-NetFirewallRule -DisplayName 'CQK SOAK block git B'`，然后
      `Start-ScheduledTask -TaskName 'CQKSoak-B'`。
      - [ ] B 机 `state.json` 的 `role` = **`PASSIVE`**（不再是 `DEGRADED`）。
            更硬的一条证据在本地日志：`Get-Content 'D:\soak\keeper-B\runtime\logs\keeper-*.jsonl' |
            Select-String '"event":"PASSIVE"' | Select-Object -Last 1`，它的 `error` 应是
            `lease held by SOAK-A until <ISO 时刻>`（`runner.ps1:134` 把 `$election.reason`
            写进 PASSIVE 行，`leader-lease.ps1:109` 生成这句话；注意日志行是
            `-Compress` 输出的，模式要写 `"event":"PASSIVE"` 而不是 `"event": "PASSIVE"`）。
            这是「旧 Leader 退位」的**唯一实机可见证据**：B 机重新读到远端租约，并认出
            owner 已经换成了 A（走 `leader-lease.ps1:107-110` 的「他人活跃租约」分支）。
            > `DEGRADED` 是**拦截期间**的状态，不是解除后的状态——规则一删，
            > `Get-RemoteLease` 就读通、`remoteReachable` 变 `true`
            > （`leader-lease.ps1:96`），下一轮直接 `PASSIVE`，不会「先 DEGRADED 再 PASSIVE」。
            > 如果解除后仍是 `DEGRADED`，说明 git 出站**还没通**（`Remove-NetFirewallRule`
            > 没删干净，或当初那条规则的路径就不是 `Get-Command git` 解析到的 git.exe）。
      - [ ] B 机本地 `keeper-*.jsonl` 里**没有** `ANCHOR_EXECUTED` / `ANCHOR_LOCAL`
            （没有第二个执行者）。
            > ⚠️ **不要**在这里找 `ANCHOR_ABORTED` + `anchor.phase=REVALIDATE`，两种落空的
            > 原因见下面第 2 条（DEGRADED 下守卫先拒、`reason` 不写本地日志）。
- [ ] 恢复：B 机 `leaseTtlMinutes: 45`、`poll.intervalMinutes: 15`、`"push": true` 全改回 §2；
      A 机保持 `enabled=true`（多机）；两台各 `apply-config.cmd`。**先停 A 机任务
      （`Suspend-ScheduledTask -TaskName 'CQKSoak-A'`，F3 之后它可能还醒着）再重跑 B 机
      `install.cmd`**，否则 A 机可能又抢回租约、§6 的收尾判据全落空。

**关于 REVALIDATE 分支，两句实话（本节不做判据）：**

1. **正向验证：接管是完整的。** B 机的租约冻结在「最后一次成功续租 + 16 分钟」上，冻结期间
   B 机自己是 DEGRADED（守卫层先拒，见 F3），不可能锚定；A 机接管并成功锚定 → 说明接管方
   真的拿到了新租约（`acquiredAt` 是新值）而不是半截 Leader。`phase=REVALIDATE` 想拦的正是
   「租约已经不属于我了但我还往下执行模型调用」这种半截状态，而接管后的 A 机被证明不是半截的。
2. **诚实说明：负向分支在实机上打不到。**「A 锚定期间 B 同时锚定」其实**不可能发生**：
   `Enter-RunnerLock`（`common.ps1:876-940`）是「锁文件 + 以安装根目录哈希命名的 `Global\`
   具名互斥体」的**每机每部署目录**互斥，同一台机上同一部署目录的两个 runner 不会并发；
   跨机那一侧则由远端租约 + CAS Claim 拦住。**注意别把因果写反**：拦住在冻结期锚定的原因是
   DEGRADED 角色（`machine does not hold the leader lease`），跟 B 机任务有没有被
   `Suspend` 无关——`Suspend`/`Resume` 只决定 runner 跑不跑，跑起来的 DEGRADED 同样会读额度、
   同样会被守卫拦。所以「`Suspend` 本身就排除了 B 锚定」这种写法不成立，别拿它当判据。
   `Test-LeaseRevalidation` 的三个 reason 串 `lease lost during claim (role=...)` /
   `lease owner changed during claim` / `lease remaining N.N min < required M min`（重验证
   失败时以 `lease revalidation failed: <r>; no model call` 包裹）在实机上**不可稳定复现**：
   守卫与重验证都调 `Invoke-LeaderElection`，中间只隔几秒（重验证要求剩余 ≥ 2×执行窗口 =
   4 分钟，租约不会在这几秒里掉下这条线），实机没有任何外部手段能让远端「前一秒可达、
   后一秒不可达」。实机能给的**唯一负向证据**是远端 claim 的 `ownerId` 唯一性（见下条判据）；
   精确分支由 `tests/auto-anchor.test.ps1` + `tests/anchor-claim.test.ps1` 的
   revalidate / EXPIRED 用例覆盖。打不到 REVALIDATE **不算 soak 失败**，
   在 §10 记一句「实机未观测到 REVALIDATE」即可。
- [ ] `& $git ls-tree -r --name-only FETCH_HEAD coordination/events/` + 逐个 `git show`
      （§5 的 fetch 之后），A 机本轮用过的**每个** eventId 都只有一个 blob、
      `ownerId` 全是 A 机 machineId、`state=COMPLETED`——没有第二个机器的 owner、
      没有同一 id 的两条 claim。

## 8. 判定表（打勾才能发布）

| §21 DoD 项 | 覆盖 | 结果 |
|---|---|---|
| Leader 正常续租 | §6 | ☐ |
| A/B 异步任务锚点 | §6 + F7 | ☐ |
| 429 | F1 | ☐ |
| 传输层故障不误判 429 | F2 | ☐ |
| Git 临时断网 | F3（B 机 `role=DEGRADED`，读取继续、不锚定） | ☐ |
| 恢复 | F1/F2/F3/F4 恢复步 | ☐ |
| History 重试 | F4 | ☐ |
| 锚定执行失败 fail-closed | F5（ABORTED、不重试、当日不再动） | ☐ |
| AutoAnchor 并发互斥 | F6（`CLAIMED` 残留 → `not claimed` 拦下）+ F7（远端 claim 只有 A 机一个 owner）<br>同时刻真并发抢占实机不可复现 → 见 F7「两句实话」 | ☐ |
| LOCAL_ONLY crash claim | F6（预埋 `CLAIMED` = 崩溃窗口，逐字节同形状） | ☐ |
| Lease revalidate 故障 | F7 **正向**（接管完整：LEADER_CHANGED + A 机锚定 + B 机退位 PASSIVE）；<br>**负向实机打不到**，由 `tests/auto-anchor.test.ps1` 覆盖，§10 记一句即可 | ☐ |
| 零 `RUNNER_ERROR` | §6 | ☐ |
| `outbox` 最终清空 | §6 + F4 | ☐ |

**任一 ☐ 不成立：不创建 tag / Release**，把现象（时间、`runId`、事件名、完整 `error` 字段）
记到 §10，作为下一个 issue 修复，然后**整轮重跑**（不要只补测那一项）。

例外：`Lease revalidate 故障` 一行的**负向**半截在实机上无法复现（见 F7「两句实话」），
按 F7 的要求在 §10 写明「实机未观测到 REVALIDATE，精确分支由自动测试覆盖」即视为该格完成；
**正向**半截（接管完整 + B 机退位 + 远端 claim 单 owner）必须真打到，打不到就是失败。

## 9. 收尾

```powershell
# 两台被测机，各自部署目录下
.\uninstall.cmd
# 清掉 soak 用的环境变量（务必！留着会把以后真实的 Codex 指回 mock）
foreach ($n in 'CQK_MOCK_MODE','CQK_MOCK_EXEC','CQK_MOCK_EXEC_ARGS_FILE') { Remove-ItemProperty 'HKCU:\Environment' $n -ErrorAction SilentlyContinue }
# 若 F3 用过防火墙规则
Remove-NetFirewallRule -DisplayName 'CQK SOAK block git' -ErrorAction SilentlyContinue
# 恢复电源策略（把 0 换回你原来的分钟数）
powercfg /change standby-timeout-ac 15
```

`D:\soak\` 整个目录（含两份 keeper、裸仓库、`anchor-args.txt`、日志）先**留着别删**，
Release 建好、tag 打上之后再清理。

## 10. 记录区（跑的时候往这里填）

| 项 | 值 |
|---|---|
| 被测 commit | `git rev-parse --short HEAD` = |
| A / B 机 machineId | `runtime\machine.json` 的 `machineId` = |
| 挂机起止时间 | |
| 16 轮实际轮数 | `RUNNER_OK` + `PASSIVE` 行数 = |
| 锚定真实执行次数 | `anchor-args.txt` 行数 = |
| 异常与截图/日志摘录 | |

签署：______（跑完的人 + 日期）
