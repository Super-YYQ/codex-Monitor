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
- [x] 实现（见 task_plan.md 分步，10 步全部完成，见 progress.md 完成记录）。

## 实现期新增发现（踩坑记录）
- `pwsh -File` 对未声明的命名参数静默塞入 `$args` 而不报错。
- 子进程 stdin 编码必须 `UTF8Encoding($false)`；`[Encoding]::UTF8` 首写会带 BOM 破坏 JSON-RPC。
- PS7 `ConvertFrom-Json` 会把 ISO 时间字符串自动转 `[DateTime]`，重新 `[string]` 化会变本地化格式。
- PowerShell 函数返回单元素数组会被 unroll（`return ,$list` 防御）。
- `@($null).Count` 为 1（判断空集合需先过滤 null）。
- dot-source 带 `param` 的脚本会在调用方作用域用默认值覆盖同名变量。
- Win11 拒绝 `RepetitionDuration=[TimeSpan]::MaxValue`（越界 XML），用 3650 天代替。
- git plumbing 提交必须 `read-tree <parent>` 保留原树，否则每次推送会抹掉分支上其它文件。