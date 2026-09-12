# 2026-09-12 产品就绪审查与遗留任务收尾

## Goal
保留 Windows 零常驻、默认 MonitorOnly、可选 Git 多机互斥及实验 AutoAnchor 定位，完成 CQK-040~047 和审查发现的必要修复，建立可复核发布门禁。

## Current Phase
实现与验证（基线 cdca944；接续分支提交 6b626e1）。

## Phases
- [x] 拉取远端、核对分支和历史（旧 main 019ef80 与重写后 85ee79b 文件树相同）。
- [x] 保留 main，在 codex/production-readiness 接续 origin/feat/p0-hardening-cqk-036。
- [x] 独立规范/需求审查；复现 CQK-040 WIP 缺陷。
- [x] 完成 CQK-040~042 运行期门禁、审计身份与计数迁移。
- [x] 完成 CQK-043~045 错误分类、有界安装重试及中文诊断。
- [x] 完成 CQK-046 状态缓存/Live 展示；修复真实 cmd 入口和日志读取边界。
- [ ] CQK-047 完整矩阵：含 Git push 的 7 套集成回归仍待明确授权。
- [ ] 双 PowerShell 全量回归、静态检查、凭据扫描、可复现打包。
  - [x] 不含 push 的 16 套双运行时通过证据、0 分析器错误、凭据扫描、重复构建及解压入口检查。
  - [ ] 7 套含临时 bare 仓库 push 的集成测试与真机 soak，须继续取得授权/环境证据。
- [x] 更新需求进度、发布说明、soak 门禁与审查报告；最终证据继续补记。

## Constraints
不向项目远端执行 git push；本地测试 fixture push 授权另行确认。不得触发真实模型调用或改用户实际部署任务。CQK-048 真实双机长时间 soak 需要部署环境证据，未通过不打 tag/Release，不声称已完成规模化运行验收。

## Next Step
本地候选 d95887d 与 ZIP 验证完成；下一步取得仅临时本地 Git push 的明确授权并执行 7 套集成测试，再安排 CQK-048 真机证据。原 main 未修改，未发布。

## Errors Encountered
- 默认 exec 沙箱无法 apply deny-read ACLs，进程启动失败；只读和必要仓库操作使用获准的沙箱外命令。
- planning-with-files 技能路径已变，已定位实际安装路径。
- PowerShell 不支持 Bash 花括号路径展开；改用脚本目录 rg 搜索。
- Spec 审查代理临时容量不足，已重试。
