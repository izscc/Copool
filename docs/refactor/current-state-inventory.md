# Current-State Inventory — Copool vNext Phase 0

> 生成时间：2026-08-05（Phase 0 基线冻结）
> 依据：`Sources/` 源码、`Tests/`、`Package.swift`、`project.yml`、运行时行为

## 1. 工程结构

- SwiftPM + XcodeGen 双轨；Swift 6.0、macOS 14+、单 executable target `Copool`（产品名 icopool，bundle `com.alick.copool`，LSUIElement 菜单栏 app）+ 一个 test target。
- 依赖：vendored zstd 单文件解码器（`Sources/CZstd`，Phase B 引入）。
- 分层：`App/`（组装与启动）、`Features/`（页面级组合）、`UI/`（视觉原语）、`Behavior/`（协调器）、`Infrastructure/`（IO/网络/进程）、`Domain/`（模型与协议）、`Layout/`（布局规则）、`WidgetSupport/`。
- DI：手写构造器注入，`AppContainer.liveOrCrash()` 是唯一组装点。

## 2. 能力清单

### 2.1 账号池（成熟）
- `AccountsCoordinator` + `AccountsPageModel`：多账号导入（auth.json）、手动/智能切换、配额刷新（5h/1week）、failover 冷却（60s/300s）、sticky 账号。
- `AccountRanking`、`UsageWindowSelector`、`AccountsSnapshotFreshnessPolicy` 等纯函数支撑。

### 2.2 本地代理（成熟，vNext 重构核心对象）
- `SwiftNativeProxyRuntimeService`（actor，1131+ 行 + 9 个扩展文件）：NWListener HTTP 服务器（SimpleHTTPServer）、`/health` `/v1/models` `/v1/responses` `/v1/chat/completions` `/v1/images/*`、WebSocket 426 降级、API key 校验。
- 协议翻译：Responses↔Chat↔Anthropic↔Gemini（+RequestTranslation/+ResponseTranslation/+ProviderAdapters/+ProviderSSE）、SSE 解码、流式 failover、retry 分类。
- 请求体解压：zstd（vendored）/gzip/deflate（libz）/brotli（Compression）。
- Compaction 续写（kcr1: payload）、子代理路由（AgentTaskRouter + 被动识别）、图片原生直通。
- 率限制头被动收割 + 用量事件 JSONL + DeepSeek/Grok 账户适配器。
- Codex 集成：`CodexModelsCacheService` 写 `config.toml` + `custom_model_catalog.json` + `models_cache.json`，watch 覆写重注入。

### 2.3 Provider 管理（成熟）
- `ProviderFileRepository`：v1 `providers.json`（ProviderStore{version, providers[]}），Keychain 惰性迁移 + 启动一次性迁移（幂等、3s 超时硬化），文件 0600。
- `ModelCapabilityDiscovery`（provider>registry>fallback 优先级）、`ModelConnectivityTester`、`LocalSubscriptionImporter`（Claude/Grok/Cursor/Antigravity）、`ProviderTokenRefreshService`（Claude/Grok/Cursor/Antigravity）。
- 9 个 UI 预设；模型策展（发现/添加）；率限制/余额/用量展示（Providers 页 + 菜单栏）。

### 2.4 Agents / Settings / 远程（成熟~半成品）
- `AgentTaskRouter`：能力/标签/文本评分路由（显式不依赖模型名猜测）；Profiles CRUD；路由事件日志（含会话名）。
- Settings：语言（11 种）、启动项、代理行为、Doctor 诊断（7 项检查）。
- 远程：Rust proxyd（`RemoteProxydBinaryBuilder` + prebuilt）、Cloudflared 公网隧道、远程账号变更同步（半成品）。

## 3. 领域模型（v1 现状 — vNext 要拆分的对象）

- `ProviderConfig`（Domain/ProviderModels.swift）：**id/name/baseURL/apiKey/refreshToken/authKind/models/modelProtocols/defaultProtocol**——secret value 直接承载在 Codable 配置里（虽已迁移 keychain 但仍可编码落盘）。
- 路由键：`routePrefix` = 小写 name（`ProviderModels.swift:155-157`）——**违反 vNext「路由键不依赖可变 displayName」约束（AC-005）**。
- `ProviderStore`/`ThirdPartyUsageStore`/`ProviderRateLimitSnapshot`/`AgentProfileStore`/`AgentRouteEvent`。
- 无 ProviderDefinition/Instance/CredentialIdentity/ModelCatalogEntry/TargetBinding/RoutePolicy/RouteDecisionTrace/SessionRecord/RemoteNode 等 vNext 领域类型。

## 4. 测试现状

- 34 个测试文件（Domain 纯函数、Presentation、Repository、Runtime 相关）。
- **已知问题**：`FileSystemPaths` 在 6b7dbe6 增加字段后测试构造曾损坏，已通过 `TestFixtures.swift` 便捷 init 修复（但本机无 Xcode，`swift test` 无法运行——见 baseline.md）。
- 覆盖缺口（vNext 需补）：Agent 路由、config 注入、keychain 迁移、cloudflared、compaction、golden fixtures。

## 5. UI 现状

- MenuBarExtra 固定宽度窗口（`LayoutRules`：16pt 页面间距、14pt 卡片圆角、胶囊切换器、Material/Glass）。
- 5 个主 Tab：账号 / 模型服务(Providers) / 运行时(Proxy) / Agent / 设置。
- 统一 `NoticeBanner`、`SectionSurface`、`LiquidProgress` 等视觉原语；11 语言本地化。
- vNext 要求的二级导航（Providers/Catalog/Routes/Usage 等子页）尚不存在。

## 6. 已集成的外部能力（本仓库自研实现，非复制）

- 多协议适配（OpenAI Chat/Responses、Anthropic Messages、Gemini）、zstd 解压、compaction kcr1、率限制收割、用量 JSONL、Doctor、模型策展、会话命名——均为基于公开协议/行为证据的原创实现（对应 codex-router/opencodex 的公开能力面）。
