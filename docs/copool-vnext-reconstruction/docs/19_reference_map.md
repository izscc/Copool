# 19. 参考能力映射

| 能力 | P1 保留/重构 | 从 P2 吸收的公开行为 | 从 P3 吸收的公开行为 | vNext 归属 |
|---|---|---|---|---|
| ChatGPT 账号池/配额 | 保留 | — | 原生登录保护 | Accounts + Credential Pool |
| 第三方供应商 | 已有，重做 schema | 多协议/订阅导入 | 数据驱动 registry/账单通道 | Provider Registry |
| 模型目录 | 已有缓存注入 | 动态 catalog/能力元数据 | 凭据感知/策展/别名 | Model Catalog |
| 本地代理 | 已有 Swift runtime | stream/transform/tool/image | caller/internal capability | Router Core/Host |
| 远程代理/Cloudflare | 保留升级 | — | 目标/状态隔离理念 | Runtime/Remote Node |
| Cursor/opencode | 部分 opencode auth | Cursor 协议/服务 | target adapters | TargetKit Beta |
| Agent/MCP | 已有 Agents | profiles/orchestrator/tool compat | generated subagent/target config | Agent Feature |
| Computer Use | —/需桥接 | native executor/image bridge | 保留原生路径 | ToolBridge |
| 会话中心 | — | session history/import | — | Session Feature |
| Voice/Realtime | — | Voice/GPT-Live/WebRTC | — | Live Plugin |
| Doctor/回滚 | ProxyDoctor 基础 | logs/diagnostics | 系统化 doctor/atomic config | Diagnostics |
| 登录无关模式 | 模型缓存注入基础 | — | managed alias/mode restore | Codex TargetAdapter |
