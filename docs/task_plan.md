# Codex Quota Keeper — 开发任务计划

依据 `docs/design/` 下四份设计文档（01 合规、02 架构、03 详细设计、04 部署运维），
在当前仓库根目录实现 `codex-quota-keeper/` 项目。

## 设计要点（从文档提取）
- **双模式**：默认 MonitorOnly（只读额度、记录）；AutoAnchor 实验默认 false。
- **零常驻**：Windows Task Scheduler 定时触发 `runner.ps1`，跑完即退出。
- **单 Leader**：复用 Private GitHub 仓库做分布式租约（`coordination/lease.json`），Git push 冲突作 CAS。
- **只读官方协议**：Codex app-server `account/rateLimits/read`，不碰 auth.json/网页。
- **安全**：不写 token、纯净日志、repoPath 白名单、参数数组化、mock 测试。

## 目标文件树
```
codex-quota-keeper/
  README.md
  .gitignore
  status.cmd
  install.cmd
  uninstall.cmd
  apply-config.cmd
  config.example.jsonc
  scripts/
    common.ps1
    install.ps1
    uninstall.ps1
    apply-config.ps1
    runner.ps1
    status.ps1
    status-json.ps1
    preflight.ps1
    quota-client.ps1
    state-machine.ps1
    leader-lease.ps1
    logger.ps1
    github-sync.ps1
    auto-anchor.ps1
  tests/
    common.test.ps1
    state-machine.test.ps1
    logger.test.ps1
    runner.test.ps1
    quota-client.test.ps1
```

## 分步 commit 顺序
1. 骨架：README/.gitignore/config.example.json + cmd 入口。
2. scripts/common.ps1（配置加载、路径、退避窗口、脱敏等共享设施）＋ 单元测试。
3. quota-client.ps1（app-server 协议）＋ mock 测试。
4. state-machine.ps1（事件识别/幂等 eventId）＋ 测试。
5. logger.ps1（JSONL/净化/保留期）＋ 测试。
6. preflight.ps1 + leader-lease.ps1 + github-sync.ps1。
7. runner.ps1 + 测试。
8. auto-anchor.ps1（实验，默认关）。
9. install/uninstall/apply-config + status/status-json。
10. 全量断言、文档对齐核对、收尾。

## 状态（2026-08-30 全部完成）
- [x] 骨架
- [x] common
- [x] quota-client
- [x] state-machine
- [x] logger
- [x] preflight/lease/sync
- [x] runner
- [x] auto-anchor
- [x] install/status
- [x] 收尾核对