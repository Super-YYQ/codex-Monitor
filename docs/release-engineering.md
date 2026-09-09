# 发布工程（CQK-034 / CQK-035）

本文档是 v0.9.x beta 的发布 runbook：GitHub 仓库安全配置的现状记录（CQK-034 只读检查）、
Ruleset 建议（需用户在 GitHub 平台操作）、以及从 commit 到可校验 ZIP 的打包流程
（CQK-035）。设计依据：审查报告 v2.0 §5 P2-05/P2-06、§21「发布前 DoD」。

## 1. 仓库安全配置现状（CQK-034）

检查时间 2026-09-09，方法：`gh api` 只读 GET（未做任何平台配置变更）。
仓库 `Super-YYQ/codex-Monitor`：**Public**、默认分支 `main`、License **MIT**。

| 项目 | 状态 | 来源 |
|------|------|------|
| Secret scanning | **enabled** | `repos/.../security_and_analysis` |
| Secret scanning push protection | **enabled** | 同上 |
| Secret scanning validity checks / non-provider patterns | disabled | 同上 |
| Dependabot security updates | disabled | 同上 |
| Vulnerability alerts | disabled | `repos/.../vulnerability-alerts`（404） |
| Rulesets | **空**（`[]`） | `repos/.../rulesets` |
| main 分支保护 | **无**（404 Branch not protected） | `repos/.../branches/main/protection` |
| Releases / Tags | **均为 0** | `repos/.../releases`、`repos/.../tags` |
| Actions workflows | `security` + `test-windows` 均 active，最近运行全绿 | `repos/.../actions/workflows`、`gh run list` |
| security-products 端点 | Unknown（404，token/计划不可读） | `repos/.../security-products` |

结论：secret scanning 与 push protection 已开启（与 CQK-033 的仓库级扫描互补）；
**main 无任何保护**，force push / 删除 / 绕过 CI 均可行 —— 这正是设计文档 P2-05 指出的缺口。

## 2. Ruleset 建议（CQK-034，待用户决定）

创建 Ruleset 属于 GitHub 平台配置变更，本仓库开发侧不做任何自动修改；
是否开启、何时开启由用户决定。设计文档建议（P2-05）：**至少在正式 Release 前开启**。

建议配置（Settings → Rules → Rulesets → New branch ruleset）：

- Target branches：`main`（默认分支）。
- Require a pull request before merging **或** Require status checks：至少要求
  `test-windows`（建议同时要求 `security`）通过。
- Block force pushes：on。
- Block deletions：on。
- Bypass list：留空（单人仓库同样建议不留 bypass，防止自己误操作绕过）。

单人直接 push main 的现有工作流与上述配置兼容，只要在 push 前本地跑过
`tests/run-all.ps1`（与 CI 同一套），required check 即会自然通过。

## 3. 发布产物构建（CQK-035）

工具：`codex-quota-keeper/tools/build-release.ps1`（PS 5.1 / 7 均可运行）。

### 3.1 为什么从 `git archive` 打包而不是压缩工作目录

- 工作目录里是 `config.json`、`runtime/`、`history/` 的所在地（均 gitignored）——
  `git archive <commit> -- codex-quota-keeper` **只能看到已提交文件**，
  「不打包本机状态」是结构性保证，不依赖任何人维护过滤规则。
- blob 字节取自 commit（LF 规范化），入口时间戳来自 commit，因此**同一 commit
  在任何机器上打出的 ZIP SHA256 相同**（可复现构建，已由测试验证：重复构建
  哈希逐字节一致）。`Compress-Archive` 会嵌入打包时刻的 mtime，哈希不可复现。

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
6. 发布后按 §2 视需要启用 Ruleset（P2-05：至少正式 Release 前开启）。

## 5. v0.9.0-beta 现状（截至本文档提交）

产物已构建并自校验：`codex-quota-keeper-v0.9.0-beta.zip`（67 个文件），
来自 commit `3fb921d`，SHA256
`2c4a214528c51c4a06ec3d2a026a83cc082004fa884eeee29cd03a4298e4a4f0`，
`-VerifyOnly` 通过。**但 tag 故意未打、Release 未创建**：§21 发布前 DoD 中
「多机连续运行 + 故障注入（实机双机 soak）」一项尚未执行，自动测试覆盖了
同样的场景逻辑（租约续期/接管、429 退避、Git 断网、outbox 重试、claim 并发），
但设计文档要求的是实机验证。soak 完成前不应把不可复现的承诺固化成 release。

§21 清单对照：

| DoD 项 | 状态 |
|--------|------|
| P1-01~04 全部关闭 | ✅ CQK-021~024 |
| Status 中文诊断面板 + PS5.1/7 测试 | ✅ CQK-025~030 |
| 多机连续运行（实机 soak + 故障注入） | ❌ 未执行 |
| AutoAnchor 并发 / crash claim / revalidate 故障测试 | ⚠️ 自动测试已覆盖，实机未跑 |
| test-windows / security 全绿 | ✅ |
| README 与 config.example.jsonc 默认值同步 | ⚠️ 收尾项 |
| Release 附 ZIP + SHA256 + 升级说明 | 构建就绪，等 soak 后发布 |
