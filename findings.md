# 开发发现与决策记录

## 环境
- Windows 11、Git Bash、Python 3.12（用于提取 docx）。
- 目标语言：PowerShell（文档明确技术栈为 PowerShell 7，兼容 5.1 入口层）。
- 无 node/npm 假设，纯脚本 + 测试用 Pester。

## 关键决策
- 项目放根目录 `codex-quota-keeper/`（文档示意的部署名）。
- 测试：用简洁的 PHPUnit 风格断言函数，避免强依赖 Pester 版本；仍可 `-Passthru` 手工跑。
- 所有配置默认保守：mode=MonitorOnly、autoAnchor=false、poll 15 分钟。
- 租约 CAS 用 `git push` non-fast-forward 冲突实现（文档 10 节伪代码）。

## 待确认
- 无（设计文档足够具体，直接照做）。

## 进度
- [x] 提取并阅读 4 份 .docx（已转 UTF-8 到设计要点）。
- [ ] 实现（见 task_plan.md 分步）。