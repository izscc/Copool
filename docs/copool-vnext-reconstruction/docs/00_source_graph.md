# 00. 公开证据源图

## 研究范围

本包以 2026-08-05 可访问的三个公开 GitHub 仓库为证据截面：

| 代号 | 仓库 | 角色 | 研究重点 |
|---|---|---|---|
| P1 | `izscc/Copool` | 目标产品与原 UI/架构基线 | SwiftUI 菜单栏产品、账号池、配额切换、本地/远程代理、Providers、Agents、Settings |
| P2 | `AITabby/opencodex` | 能力参考 | 多协议网关、模型目录、会话中心、语音/Realtime、Computer Use、Agent/工具兼容、订阅登录导入 |
| P3 | `duolahypercho/codex-router` | 路由与安全参考 | 多目标隔离、凭据隔离、模型注册表、目录策展、登录无关模式、Doctor/回滚、跨平台服务 |

## 一手证据

### P1 — Copool

- `README.md`：产品定位、账号池、配额、代理、远程部署、菜单栏体验。
- `Package.swift`：Swift 6、macOS 14、SwiftUI 可执行程序、zstd、proxyd 资源和测试目标。
- `Sources/Copool/App/RootScene.swift`：固定宽度菜单栏窗口、5 个主导航、胶囊式切换器、统一通知层。
- `Sources/Copool/Layout/LayoutRules.swift`：16pt 页面间距、14pt 卡片圆角、固定面板宽度、卡片网格等布局规则。
- `Sources/Copool/Domain/ProviderModels.swift`：Provider、模型、协议、认证方式、使用量等当前领域结构。
- `Sources/Copool/Features/Providers/ProviderPageModel.swift`：供应商预设、模型发现、能力探测、用量/限流、订阅导入。
- `Sources/Copool/Infrastructure/*`：当前已存在的模型缓存、协议转换、SSE、Reasoning、Compaction、第三方适配、Keychain、远程部署等实现面。
- `Sources/Copool/CopoolApp.swift`：启动时秘密迁移、第三方模型目录注入、缓存监听、代理引导。

### P2 — OpenCodex

- `README.md`：能力表、供应商、模型目录、Agent、会话、语音、Realtime、Computer Use、图像桥接。
- `package.json`：Node/TypeScript 网关，MCP、PTY、SQLite、WebSocket、HTTP 依赖。
- `src_v2/adapters/*`：OpenAI、Anthropic、Google、DeepSeek、MiniMax 的协议适配分层。
- `src_v2/core/*`：流式引擎、转换器、解压和 Responses 安全处理。
- `src_v2/services/*`：目录同步、凭据、会话、Computer Use、原生图像、子代理、订阅认证、Cursor 协议等服务。
- `src_v2/server/*`：网关、路由和 WebRTC 代理。
- `macos-app/*`：Swift 原生控制壳与打包结构。

### P3 — Codex Router

- `README.md`：目标应用隔离、供应商/模型、模型策展、登录无关模式、安装与 Doctor。
- `config/providers.json`：供应商注册表、认证来源、环境变量、Keychain 服务、端点、协议。
- `SECURITY.md`：目标级信任根、调用密钥、内部密钥、回环绑定、凭据转发白名单、文件权限、原子配置和回滚。
- `package.json`：Node 22.19+ 的轻量本地路由核心。
- `apps/*`：macOS 控制面和 Tauri 桌面实验面。
- `LICENSE`：MIT；P1/P2 根目录未发现许可证文件，不能据此复制其代码或视觉资产。

## 证据边界

1. 仅使用公开仓库的行为、文档、文件结构和协议层事实。
2. 不复制 P2/P3 的实现代码、文案、图标、截图、布局或命名体系。
3. P1 是目标仓库，可在其原有代码和 UI 规范内重构；P2/P3 仅用于推导需求、风险和架构约束。
4. 所有未从代码或文档直接证实的内容均标注为“设计决策”或“待验证”。
5. 模型名称、供应商端点和认证政策变化快，产品实现必须采用可更新注册表，不把研究时点的模型清单硬编码为长期事实。
