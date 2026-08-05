# 01. 证据日志

| ID | 来源 | 已观察事实 | 对重构的影响 | 置信度 |
|---|---|---|---|---|
| E-P1-001 | P1 README | Copool 是菜单栏优先的 SwiftUI 账号池与代理管理器，支持本地/远程运行时 | 继续以原生轻量控制面为核心，不改造成大型 Web Dashboard | 高 |
| E-P1-002 | P1 Package.swift | 单一 Swift 可执行目标承载 UI、领域与运行时，含 proxyd 资源 | 必须拆包，但先保行为等价，避免一次性替换全部运行时 | 高 |
| E-P1-003 | P1 RootScene | 5 个主导航、固定宽度、胶囊式切换、统一 NoticeBanner | 新能力必须通过二级导航和渐进披露承载，不能无限增加顶层 Tab | 高 |
| E-P1-004 | P1 LayoutRules | 16pt page/section spacing、14pt card radius、固定面板宽度 | UI 继续使用原 token；复杂页采用 drill-down，而不是扩大面板为控制台 | 高 |
| E-P1-005 | P1 ProviderModels | 当前 ProviderConfig 同时持有端点、模型、协议和 API key；routePrefix 来自可变名称 | 拆分 ProviderFamily/Instance/Credential/Model；路由键改为不可变 ID；配置不存秘密值 | 高 |
| E-P1-006 | P1 ProviderPageModel | 已有 DeepSeek/Qwen/Z.ai/MiniMax/Kimi/OpenRouter/Volcengine/Anthropic/Gemini、模型发现、探测、订阅导入 | 不是从零集成 P2；应把现有能力迁移到统一注册表并补齐治理能力 | 高 |
| E-P1-007 | P1 Infrastructure | 已有协议转换、SSE、Reasoning、Compaction、模型缓存、Keychain、远程代理等 | 使用绞杀者模式抽取 RouterKit，禁止重复造第二套平行运行时 | 高 |
| E-P1-008 | P1 CopoolApp | 启动时迁移明文秘密并写入第三方目录/监听缓存 | 秘密迁移和目录同步应从 App 启动副作用改成可观测、可回滚的迁移服务 | 高 |
| E-P2-001 | P2 README | 提供模型目录、语音、Realtime、会话、Agent、Computer Use、图像桥接和协议路由 | 将这些作为可插拔能力域，不直接移植其 Dashboard | 高 |
| E-P2-002 | P2 package.json | 依赖 MCP、PTY、SQLite、WebSocket，说明其能力跨越会话、终端和实时通信 | 分离网关核心、会话索引、实时媒体和外部进程执行边界 | 高 |
| E-P2-003 | P2 src_v2 | adapters/core/services/server 分层，但存在数十万字节巨型文件 | 借鉴责任划分，不复制巨型实现；为每个能力建立接口和体积预算 | 高 |
| E-P2-004 | P2 services | Computer Use 与图像通过原生桥接，Agent 路由有 profile/store/orchestrator | 保留 Codex 作为工具执行器；外部模型只生成工具意图，不自建不受控执行器 | 高 |
| E-P3-001 | P3 README | Codex/Cursor/opencode 共享注册表和转换层，但端口、状态、调用密钥、选择与服务隔离 | TargetBinding 和 TargetRuntime 必须是一等实体，默认按目标隔离 | 高 |
| E-P3-002 | P3 providers.json | 同一模型家族按 OAuth/API/计划/云托管等不同账单通道并存 | ProviderFamily 与 ProviderInstance 分离；模型 ID 不能只按厂商去重 | 高 |
| E-P3-003 | P3 SECURITY | 回环监听、随机 caller/internal capability、精确凭据替换、浏览器来源拒绝、原子配置、权限保护 | 成为 Copool vNext 安全基线和发布门槛 | 高 |
| E-P3-004 | P3 README/registry | 支持 live catalog 策展、凭据感知目录、限流头被动采集 | 模型目录必须可发现/策展/隐藏/测试，并区分元数据来源 | 高 |
| E-P3-005 | P3 LICENSE + P1/P2 缺失 | P3 MIT；P1/P2 根目录没有可见 LICENSE | 对 P2/P3 采用 clean-room；任何代码复用需单独法律确认 | 高 |

## 推导结论

- **不是把 P2/P3 代码塞进 P1**，而是把三者共同问题抽象成：身份、供应商实例、模型目录、目标应用、路由策略、运行时节点和能力插件。
- **P1 已经部分吸收 P2**，最大的新增价值来自重新划清边界、消除双重状态、增加 P3 的安全与配置治理，以及把 P2 的高级能力做成延迟加载插件。
- **UI 容量是硬约束**。P1 的固定菜单栏面板不能容纳传统左侧大导航，因此主导航维持 5 个，复杂能力进入页面内 segmented control、sheet 和 detail stack。
