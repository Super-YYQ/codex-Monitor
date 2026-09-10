# 发布工程（CQK-034 / CQK-035）

本文档是 v0.9.x beta 的发布 runbook：GitHub 仓库安全配置的现状记录（CQK-034 只读检查）、
Ruleset 的现状与配置记录（CQK-034，已应用）、以及从 commit 到可校验 ZIP 的打包流程
（CQK-035）。设计依据：审查报告 v2.0 §5 P2-05/P2-06、§21「发布前 DoD」。

## 1. 仓库安全配置现状（CQK-034）

首次只读检查 2026-09-09，方法：`gh api` 只读 GET。仓库 `Super-YYQ/codex-Monitor`：
**Public**、默认分支 `main`、License **MIT**。

同日经用户授权创建了一条 Ruleset（见 §2），下表为**该次变更后**的状态；
**push 前复核**一行是发布前再查一次的结果，与首次检查不一致的地方都如实标出。

| 项目 | 状态 | 来源 | push 前复核 |
|------|------|------|------------|
| Secret scanning | enabled | `repos/.../security_and_analysis` | **Unknown**（该端点稳定 404，见下方说明） |
| Secret scanning push protection | enabled | 同上 | **Unknown**（同上） |
| Secret scanning validity checks / non-provider patterns | disabled | 同上 | Unknown（同上） |
| Dependabot security updates | disabled | 同上 | Unknown（同上） |
| Vulnerability alerts | disabled | `repos/.../vulnerability-alerts`（404） | 网络超时，未复核 |
| Rulesets | 首次检查为**空**（`[]`） | `repos/.../rulesets` | **`main-protection`（id 22646165）active** → §2 |
| main 分支保护 | 首次检查为**无**（404） | `repos/.../branches/main/protection` | 仍是 404 —— **这是正常的**，Ruleset 不会写入旧版分支保护端点，不可据此判断「无保护」 |
| Secret scanning 告警 | 无告警 | `repos/.../secret-scanning/alerts` → `[]` | 可读、仍为 `[]`（但空列表不能证明扫描处于开启状态，故不作为 enabled 的依据） |
| Releases / Tags | **均为 0** | `repos/.../releases`、`repos/.../tags` | 均为 0（未发布，等 soak） |
| Actions workflows | `security` + `test-windows` 均 active，最近运行全绿 | `repos/.../actions/workflows`、`gh run list` | 均 active，`main` 最近一次（`c7260f7`）全绿 |

> **复核 404 的说明**：`security_and_analysis` 在首次检查时返回完整 JSON，同日复核时
> 15 次请求中 7 次 `404 Not Found`、其余为网络超时；带显式
> `Accept: application/vnd.github+json` + `X-GitHub-Api-Version: 2022-11-28` 仍 404。
> `security-products` 端点同样不可读（首次检查即为 404）。按「读不到就标 Unknown、
> 不自行开关」的处理原则，此处不下任何结论，也**未对任何配置做改动**。要看真实状态：
> 仓库 Settings → Code security and analysis（需管理员网页登录）。

结论：首次检查时 **main 无任何保护**（force push / 删除 / 绕过 CI 均可行，即设计文档
P2-05 指出的缺口）；该缺口已于 2026-09-09 由 §2 的 Ruleset 关闭。Secret scanning 侧
仍按首次检查的 enabled 记录、复核为 Unknown，仓库级自查由 CQK-033 的
`tests/secret-scan.ps1`（CI 的 `Secret scan` check）承担，不依赖平台开关。

## 2. Ruleset：`main-protection`（CQK-034，已于 2026-09-09 应用）

创建属 GitHub 平台配置变更。用户在本次任务中明确要求「开」，故由开发侧经
`gh api` 创建（**仅此一项平台变更**，未动其他任何设置），并用
`GET repos/.../rulesets/22646165` 读回逐项核对后记录如下。

已应用配置（网页侧对应 Settings → Rules → Rulesets → `main-protection`）：

| 项 | 值 |
|----|-----|
| Ruleset ID / 名称 | `22646165` / `main-protection` |
| Enforcement | `active` |
| 作用范围 | `refs/heads/main`（`conditions.ref_name.include`） |
| 禁止 force push | `non_fast_forward` |
| 禁止删除分支 | `deletion` |
| Required status checks | 5 项，见下表；`strict_required_status_checks_policy` = **false** |
| Bypass list | `bypass_actors: []`，`current_user_can_bypass` = **never**（不留任何绕过口） |

Required checks 用的是 **check-run context（即 job 的 `name`）而非 workflow 文件名**。
本文档早期草稿写的是 `test-windows` / `security`，那是 workflow 名，**平台上永远不会
有这两个 context**，照抄会把必需检查钉成永久红。真实 context（取自
`repos/.../commits/c7260f7/check-runs`，全部属于 GitHub Actions / `integration_id` 15368）：

| Context | 来源 |
|---------|------|
| `PowerShell 7 unit + integration tests` | `test-windows.yml` → job `pwsh-tests` |
| `Windows PowerShell 5.1 compatibility` | `test-windows.yml` → job `ps51-tests` |
| `Official quota schema contract tests` | `test-windows.yml` → job `contract-tests` |
| `PSScriptAnalyzer` | `security.yml` → job `lint` |
| `Secret scan` | `security.yml` → job `secret-scan` |

**实际行为（2026-09-10 实测，纠正本文档早先的错误说法）**：Ruleset 的
`required_status_checks` **同时拦合并和直接 `git push`**。首次按 §4 直接推 `main` 即被拒：

```
remote: error: GH013: Repository rule violations found for refs/heads/main.
remote: - 5 of 5 required status checks are expected.
 ! [remote rejected] main -> main (push declined due to repository rule violations)
```

原因是一个死结：check 只可能在 GitHub 拿到 commit 之后才上报，而任何新 commit 在拿到
绿色 check 之前都不许落到 `main`。所以**新提交无法再直接 push 进 `main`**，只能走
「推功能分支 → 开 PR（CI 在 PR head 上跑绿）→ 合并」。合并本身没问题：`main` 是 PR
base 的祖先，产生的 merge commit 不是 force update，`non_fast_forward` 不会拦。

> 早先本文档写过「required status checks 只拦合并不拦直接 push」，那是**旧版分支保护**
> （`branches/main/protection`）的语义，不适用于 Ruleset；当时依据的是搜索到的文档
> 措辞而非实测，现已按实测纠正。

由此产生的工作流变化（单人仓库也一样适用）：

1. 本仓库**未**加 `pull_request` 规则（Require a pull request before merging）——加不加
   效果几乎相同，因为 required checks 已经把直接 push 挡住了；少一条规则也少一层
   「本地跑绿了但忘了开 PR」的困惑。要彻底强制评审式流程可再补这条。
2. `strict_required_status_checks_policy` 保持 **false**：true 还额外要求分支在合并前
   必须等于 base 最新（behind 就拒），单人频繁合并时只会平添冲突，且对上面的死结无帮助。
3. 日常节奏从「commit → push」变成「commit → `git switch -c` → push 分支 → PR →
   等 CI 绿 → merge」。两个 workflow 同时监听 `push: [main]` 与 `pull_request`，
   所以 PR 阶段跑的就是合并后那 5 个 context。
4. 如果确实需要一次「直接 push 到 main」的逃生门（例如 CI runner 全挂、或首次给
   一个空仓库灌入历史），只有两条路：给 Ruleset 加一个 **bypass actor**，或临时把
   `enforcement` 调成 `evaluate`（只记日志不拦）推完再改回 `active`。两者都是平台配置
   变更，**必须用户明确要求**；本文档不预设任何一种。

追加或收紧规则时记着这几个坑（本文档作者踩过 4 轮 422）：`rules` 必须是
`[{"type": ..., "parameters": {...}}]` **数组**；两条封锁规则的真名是
`non_fast_forward` / `deletion`（不是 `block_force_pushes` / `block_deletions`）；
`required_status_checks` 的参数名是 `strict_required_status_checks_policy` +
`required_status_checks[{context, integration_id}]`（写成 `strict`/`checks` 或漏
`integration_id` 都只会得到一句无信息量的 `data matches no possible input`）。
改完**务必 GET 读回**核对，创建响应的措辞不足为信。

网页入口：<https://github.com/Super-YYQ/codex-Monitor/rules/22646165>。若被误删，
用下面这份**已验证可用**的 payload 原样重建（`POST repos/.../rulesets`）：

```json
{
  "name": "main-protection", "target": "branch", "source_type": "Repository",
  "enforcement": "active",
  "conditions": { "ref_name": { "exclude": [], "include": ["refs/heads/main"] } },
  "rules": [
    { "type": "non_fast_forward" },
    { "type": "deletion" },
    { "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [
          { "integration_id": 15368, "context": "PowerShell 7 unit + integration tests" },
          { "integration_id": 15368, "context": "Windows PowerShell 5.1 compatibility" },
          { "integration_id": 15368, "context": "Official quota schema contract tests" },
          { "integration_id": 15368, "context": "PSScriptAnalyzer" },
          { "integration_id": 15368, "context": "Secret scan" }
        ] } }
  ],
  "bypass_actors": []
}
```

（服务端会额外补一个 `do_not_enforce_on_create: false`，读回时看到不算差异。）

## 3. 发布产物构建（CQK-035）

工具：`codex-quota-keeper/tools/build-release.ps1`（PS 5.1 / 7 均可运行）。

### 3.1 为什么从 `git archive` 打包而不是压缩工作目录

- 工作目录里是 `config.json`、`runtime/`、`history/` 的所在地（均 gitignored）——
  `git archive <commit> -- codex-quota-keeper` **只能看到已提交文件**，
  「不打包本机状态」是结构性保证，不依赖任何人维护过滤规则。
- blob 字节取自 commit（LF 规范化），入口时间戳来自 commit，因此**同一 commit
  在任何机器上打出的 ZIP SHA256 相同**（可复现构建，已由测试验证：重复构建
  哈希逐字节一致）。`Compress-Archive` 会嵌入打包时刻的 mtime，哈希不可复现。

> 注意 `git archive` 取的是 **blob**，不受检出时的 `core.autocrlf` 影响；受影响的是
> **测试读工作树**那一路。根目录 `.gitattributes` 只把两类文件钉成 `text eol=lf`——
> `tests/golden/*.txt`（§17.2 面板逐行字节比对）与 `codex-quota-keeper/.gitignore`
> （被 `(?m)^tools/dist/?$` 锚定匹配）——因为 `windows-latest` 的检出等同
> `core.autocrlf=true`，多出的 CR 会让这两处断言在 CI 上必红（已踩过，见
> CHANGELOG「CI 上的行尾与时间戳宿主依赖」）。没有写 `* text=auto`，也不碰
> `.cmd` / `.ps1`：既有内容不做归一化，`.cmd` 换成 LF 是真实回归风险。

### 3.2 用法

```powershell
# 从当前 HEAD 构建（默认输出到 codex-quota-keeper/tools/dist/，已被 .gitignore 忽略）
pwsh -NoProfile -File codex-quota-keeper/tools/build-release.ps1

# 指定版本号 / 从 tag 或 commit 构建 / 允许脏树的临时演练
pwsh -NoProfile -File codex-quota-keeper/tools/build-release.ps1 -Version 0.9.1-beta -Ref v0.9.1-beta

# 只校验已有产物与 SHA256SUMS.txt 是否一致（不重新构建）
powershell -NoProfile -File codex-quota-keeper/tools/build-release.ps1 -VerifyOnly
```

版本号默认从**被构建 commit** 的 `scripts/common.ps1` `$CQK_VERSION` 读取（不读工作区，
避免「ZIP 叫 v1.2.3、status.cmd 报 0.9.0」）；显式 `-Version` 必须是 semver 形态
（如 `0.9.0-beta`）。工作树在 `codex-quota-keeper/` 前缀内有未提交改动时拒绝构建
（`-DirtyOk` 仅限丢弃式演练——脏树产物无法由它声称的 commit 复现）。

### 3.3 内置门禁

依次执行，任何一步失败即整体失败（ZIP 已存在时删除，不留下无校验和描述的产物）：

1. **前置**：目标路径必须是 git 仓库；`tests/secret-scan.ps1` 必须存在（拒绝没有
   secret 门禁的检出）。
2. **脏树门禁**：`codex-quota-keeper/` 前缀内不允许未提交改动（前缀外的无关改动不阻断）。
3. **Secret 扫描**：对整个检出运行仓库级 `tests/secret-scan.ps1`（CQK-033 的
   按字面量豁免版），有命中即拒绝。
4. **归档后入口检查**（从 ZIP 内实际读回条目，不信任假设的文件清单）：
   - 禁止条目：前缀下的 `runtime/`、`runtimes/`、`history/`、`config.json`，
     任意位置的 `.env` / `.pem` / `.key` / `.pfx`，任何 `.git/` 路径；
   - 必需条目：`scripts/runner.ps1`、`install.cmd`、`config.example.jsonc`、`README.md`
     缺一即拒（防前缀写错打出空 ZIP 还退出 0）。
5. **SHA256SUMS.txt**：GNU `sha256sum` 两空格文本格式、LF 结尾、UTF-8 无 BOM，
   写入后立即回读自检。

### 3.4 校验产物

```powershell
# 本脚本自带校验（PS 5.1 也能跑）
powershell -NoProfile -File codex-quota-keeper/tools/build-release.ps1 -VerifyOnly

# 或 GNU sha256sum（WSL / Linux 亦可，两空格文本格式互通）
sha256sum -c SHA256SUMS.txt
```

## 4. 发布 runbook

脚本**不做任何发布**——它只产出文件并打印建议命令；打 tag 与创建 Release 是
人工决定（同时受全局规则约束：`git push` / `gh release create` 必须用户明确要求）。

1. `tests/run-all.ps1` PS7 + PS5.1 全绿；CI（`test-windows` / `security`）绿色。
2. 确认 `codex-quota-keeper/` 工作树干净（未提交改动先 commit 或 stash）。
3. 运行 §3.2 构建命令；确认输出里的 commit、version、sha256 符合预期。
4. `-VerifyOnly` 复核（或换台机器复核，验证可复现性）。
5. **用户决定**是否打 tag 并发布：

   ```
   git tag v0.9.0-beta
   gh release create v0.9.0-beta <ZIP 路径> --verify-tag \
     --title "Codex Quota Keeper v0.9.0-beta" --notes-file <release notes>
   ```

   Release notes 附 ZIP、SHA256SUMS.txt、升级说明（根 `CHANGELOG.md`「升级说明」节）。
6. Ruleset 已启用（§2，2026-09-09），日常无需再操作。但注意它的 push 语义：
   **required checks 也拦直接 `git push main`**（§2 有实测记录），所以往 `main` 落东西
   必须走「功能分支 → PR → CI 绿 → 合并」。`git tag` 与 push tag 不受影响
   （Ruleset 只作用于 `refs/heads/main`），因此第 5 步仍可直接做。

## 5. v0.9.0-beta 现状（截至本文档提交）

最近一次构建演练（值仅对应该 commit，正式发布前须按 §4 从待发布 commit 重建）：
`codex-quota-keeper-v0.9.0-beta.zip`（70 个文件），来自 commit `267073e`，SHA256
`3f647bf2ff79ba656843123f4427c3f5a9d30ec57c13cfffa2348429bc2c0271`，
`-VerifyOnly` 通过。**但 tag 故意未打、Release 未创建**：§21 发布前 DoD 中
「多机连续运行 + 故障注入（实机双机 soak）」一项尚未执行，自动测试覆盖了
同样的场景逻辑（租约续期/接管、429 退避、Git 断网、outbox 重试、claim 并发），
但设计文档要求的是实机验证。soak 完成前不应把不可复现的承诺固化成 release。

§21 清单对照：

| DoD 项 | 状态 |
|--------|------|
| P1-01~04 全部关闭 | ✅ CQK-021~024 |
| Status 中文诊断面板 + PS5.1/7 测试 | ✅ CQK-025~030 |
| 多机连续运行（实机 soak + 故障注入） | ⏳ 操作单已交付（`docs/soak-runbook.md`），等用户排期实机跑 |
| AutoAnchor 并发 / crash claim / revalidate 故障测试 | ⚠️ 自动测试已覆盖；实机由操作单 F5/F6/F7 覆盖，未跑 |
| test-windows / security 全绿 | ✅ |
| main 分支保护（P2-05） | ✅ Ruleset `main-protection`（§2） |
| README 与 config.example.jsonc 默认值同步 | ✅ R19 |
| Release 附 ZIP + SHA256 + 升级说明 | 构建就绪，等 soak 后发布 |
| 全量测试双运行时 | ✅ 17 文件 PS7 + PS5.1（R19） |

