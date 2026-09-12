# 本轮审查发现

历史与遗留需求详见 docs/findings.md、docs/task_plan.md。最新远端尚有 CQK-040 WIP 及 CQK-041~048 未完成。独立工作分支已创建，原 main 保留。

本轮已修复与验证边界详见 docs/production-readiness.md。关键追加发现：Profile 拒绝吞重置事件；既有 Claim 不退出待处理队列；启动前失败误计调用；Profile 失败不影响 overall；Status 日志返回嵌套数组；status.cmd 不透传 Live；通用 cmd 启动器多余引号；git archive 发布 LF 批处理会在 Windows 中文环境错误解析；旧 outbox 脱敏和损坏记录保留不足。

设计选择：保留共享 app-server 会话、Execution Profile Resolver、Runner 单一审计写入者及零常驻调度架构。缺乏推翻产品架构的证据；优先修复有复现的可靠性问题。
