# Security Policy / 安全策略

## 支持版本

| 版本 | 支持状态 |
|------|----------|
| 0.9.0-beta | 支持（安全修复） |
| < 0.9.0 | 不支持 |

## 报告漏洞

请勿在公开 Issue 中披露安全细节。通过 GitHub Security Advisories
（Security 标签页 → Report a vulnerability）私下报告，我们会尽快响应。

## 安全设计边界（必须始终保持）

- **不读取、不复制、不上传 `auth.json`**：Codex 凭证只留在各机器自己的 Codex 目录。
- **不抓取 ChatGPT 网页、不伪造客户端身份**：额度只通过官方 `codex app-server`
  的 `account/rateLimits/read` 读取。
- **不上传 token / Prompt / 会话正文**：history 仓库只保存净化后的额度与事件元数据；
  日志与 history 走字段白名单。
- **AutoAnchor prompt 白名单**：长度与字符集受限、参数数组传递、绝不接受远程下发命令。
- **专用日志仓库绑定**：推送前校验 marker（repoId）+ origin 指纹 + 分支白名单；
  main/master/develop/release 等业务分支强制拒绝。
- **AutoAnchor 默认关闭**：属于实验功能，开启即表示接受 doc/01 评估的合规解释风险。

## 凭证处理建议

- Git 认证使用系统 Git Credential Manager 或 SSH key；不要把 PAT 写入 config.json。
- 日志仓库必须是 Private 仓库。
