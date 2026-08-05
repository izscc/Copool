# 15. 风险登记册

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| 一次性重写造成现有账号/代理回归 | 高 | 高 | 绞杀者迁移、golden fixtures、feature flag、并行验证 |
| Provider schema 同时保留 apiKey 与 Keychain 形成双源 | 高 | 高 | v2 只存 CredentialRef，迁移 journal 后删除旧字段 |
| Codex 配置格式或模型 allowlist 变化 | 中 | 高 | TargetAdapter、detect/plan/verify、版本探测、保守失败 |
| 模型/端点硬编码迅速过时 | 高 | 中 | 内置注册表 + 签名更新 + live catalog + 用户策展 |
| 自动 failover 重放有副作用的工具调用 | 中 | 高 | 幂等性分类、会话亲和、工具状态冲突禁止自动重放 |
| 多目标共享状态泄漏凭据 | 中 | 高 | target-specific capability/state/key/service/port |
| 回环端口被浏览器或其他本地进程调用 | 中 | 高 | caller capability、Origin 拒绝、无 CORS、UDS 优先 |
| Public/Cloudflare 暴露扩大攻击面 | 中 | 高 | 默认关闭、单独认证、最小端点、风险预览、审计 |
| Voice/Realtime 权限与隐私 | 中 | 高 | 插件化、显式权限、默认不持久化、清晰录音状态 |
| P2/P1 许可证不清晰 | 高 | 中 | clean-room，不复制代码/资产；复用前法律确认 |
| 固定宽度 UI 信息过载 | 高 | 中 | 5 主 Tab、二级导航、摘要卡片、detail sheet、专家模式 |
| 巨型服务重新出现 | 中 | 高 | 模块体积预算、protocol contract、单文件软上限、架构测试 |
| 远程节点版本漂移 | 中 | 中 | 协议版本握手、兼容矩阵、分批升级、rollback slot |
