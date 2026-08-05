# 25. 技术指纹

| 项目 | 观察到的技术 | 启示 |
|---|---|---|
| P1 | Swift 6、SwiftUI、MenuBarExtra、Combine、Keychain、zstd、原生 HTTP/代理、远程 shell/Cloudflare | 目标控制面与现有运行时基础；优先 Swift 包化 |
| P2 | TypeScript/Node、MCP SDK、PTY、sql.js、WebSocket、Undici、Swift macOS 壳 | 高级能力跨会话/实时/终端；应插件化，不整包嵌入 |
| P3 | Node 22 路由、JSON registry、shell/PowerShell installer、macOS/Tauri 控制面、严格状态与配置治理 | 安全、目标隔离和安装回滚模式可转化为 Copool 原创实现 |

## 建议技术栈

- UI：继续 SwiftUI/Combine（逐步采用 Observation 可另行 ADR）。
- Domain/Application：纯 Swift package，无 AppKit/SwiftUI 依赖。
- Router Core：Swift Concurrency + URLSession/Network.framework；Canonical IR。
- Local IPC：Unix Domain Socket 优先，必要时 loopback HTTP + capability。
- Persistence：JSON 用于可移植配置；SQLite 用于会话、usage、decision trace。
- Secure Store：macOS Keychain；Linux/Windows daemon 使用平台安全存储或权限保护文件，并在 UI 明示等级。
- Remote：TLS/mTLS 或基于节点身份的加密通道，版本化协议。
- CI：macOS Swift 测试；隔离 HOME 的配置/安装测试；未来 Linux/Windows daemon jobs。
