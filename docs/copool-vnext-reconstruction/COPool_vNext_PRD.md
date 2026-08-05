# Copool vNext — PRD 与重构蓝图


---

> 研究截面：2026-08-05。公开证据驱动，clean-room 原创实现。


---


# 02. 产品简报

## 产品名

**Copool vNext — 原生 AI 账号、模型与 Agent 路由控制中心**

## 一句话定位

在一个保持 Copool 原生菜单栏体验的控制面中，统一管理 OpenAI 账号池、第三方模型供应商、Codex/Cursor/opencode 目标应用、可解释路由、Agent/会话/Computer Use 与本地或远程运行时。

## 主要用户

1. 同时使用多个 ChatGPT/Codex 账号并关注配额的独立开发者。
2. 需要在 Codex 中使用 Kimi、Claude、DeepSeek、Gemini、Grok、Qwen、GLM 等模型的高级用户。
3. 需要为 Codex、Cursor、opencode 分别配置隔离路由和凭据的工具开发者。
4. 需要本地优先、可审计、可回滚，而不愿把全部密钥交给云端控制台的团队。

## 核心价值

- **一个控制面，多个信任域**：统一查看，但不混用目标应用、供应商和账号的秘密。
- **账号池 + 模型路由不是两套产品**：原生 OpenAI 账号、第三方供应商实例和模型能力进入同一个决策引擎。
- **可解释而非黑盒自动切换**：每次自动选择都给出硬约束、评分、失败转移和用量依据。
- **原生能力保留**：原生 GPT、ChatGPT 登录、Codex 工具链、MCP、Computer Use、项目信任和配置不被粗暴覆盖。
- **渐进复杂度**：默认模式只显示连接、模型和健康状态；专家模式才显示协议、目标绑定、别名、限流和转换细节。

## 非目标

- 不做云端密钥托管 SaaS。
- 不复制 OpenCodex 或 Codex Router 的 UI、文案、代码或品牌。
- 不在 vNext 首版自建新的操作系统级 Computer Use 执行器。
- 不承诺所有供应商所有模型永久兼容；采用能力探测、策展和兼容性等级。
- 不将本地回环 capability 描述成能抵御同一 OS 用户下恶意进程的强安全边界。


---


# 03. Copool vNext 产品需求文档（PRD）

## 1. 背景

Copool 当前已经从“账号池”扩展到第三方供应商、Agent 和本地/远程代理，但领域模型仍把供应商、认证、端点、模型和路由耦合在单个配置对象中；运行时能力也集中在大型 Swift 服务及其扩展中。P2 展示了模型目录、会话、语音、Realtime、Computer Use 和 Agent 路由的产品空间，P3 则证明多目标隔离、凭据感知目录、配置回滚和 Doctor 是可靠产品不可缺失的基础。

本次重构允许推倒现有内部边界，但必须保留 P1 的视觉语言、菜单栏形态、账号池价值和已有用户数据。

## 2. 目标

### G1 — 统一领域模型

把 `账号/凭据/供应商/端点/模型/目标应用/路由/运行时节点/Agent` 拆为独立实体，通过稳定 ID 关联，消除基于可变名称和明文秘密的路由耦合。

### G2 — 统一但隔离的运行时

建立共享 Router Core，同时按目标应用隔离 caller capability、状态目录、监听地址、供应商选择、配置补丁和日志视图。

### G3 — 覆盖 P2/P3 主要能力

纳入多协议模型接入、动态目录、模型策展、订阅/OAuth 导入、会话中心、Agent 能力路由、原生工具/Computer Use/图像桥接、语音与 Realtime、登录无关模式、Cursor/opencode 目标、Doctor/回滚、限流/用量和远程节点。

### G4 — 原 UI 规范下扩容

顶层仍维持 5 个胶囊导航，使用页面内二级 segmented control、卡片、sheet、detail push 和专家模式承载复杂功能。

### G5 — 可迁移、可测试、可回滚

所有 schema、Codex 配置和服务变更都有版本、备份、dry-run、差异预览、原子写入和 rollback。

## 3. 成功指标

| 指标 | 目标 |
|---|---|
| 原有账号导入/切换/配额/本地代理/远程代理功能回归 | 100% P0 场景通过 |
| 配置变更可回滚 | 100% 目标适配器提供 dry-run 与 rollback |
| 秘密泄漏 | 配置、日志、Doctor、崩溃报告中 0 明文秘密 |
| 模型目录可用性 | 有效凭据供应商可发现/策展；无凭据供应商不进入默认目录 |
| 路由可解释性 | 每次自动路由保存 decision trace；UI 可查看最近 50 条 |
| 自动化测试 | Router Core 行覆盖目标 ≥80%，关键转换分支 ≥90% |
| UI 回归 | 现有主要页面 snapshot 无非预期视觉变化 |
| 迁移成功率 | v1 数据 fixture 100% 迁移且可回退 |

## 4. 范围与优先级

### P0 — 架构与安全基础

- Swift 包模块化和 Router Core 接口。
- Provider Registry v2、CredentialRef、Model Catalog v2。
- Target Adapter：Codex App/CLI。
- 目标隔离、caller/internal capability、回环安全。
- 路由策略、账号/凭据池、健康与失败转移。
- Doctor、dry-run、配置备份、回滚、支持包脱敏。
- 现有 Providers/Proxy/Accounts 功能迁移。

### P1 — 工作台能力

- Cursor 和 opencode 目标适配器（Beta）。
- 会话中心与外部 Agent 会话导入。
- Agent Profile、能力标签、任务路由。
- MCP/工具调用、原生图像与 Computer Use 桥接。
- 模型目录策展、兼容性测试、限流/成本/用量视图。
- 登录无关模式和目标级模型别名。

### P2 — 实时与跨平台扩展

- Voice Center：STT/TTS/VAD、全局语音条。
- Realtime/GPT-Live 会话和任务委派。
- Linux 远程运行时节点升级。
- Windows 路由守护进程与 CLI；不要求复制 macOS UI。

## 5. 角色与主要任务

| 角色 | 任务 |
|---|---|
| 默认用户 | 添加账号/供应商，选择模型，启动 Codex，无需理解协议 |
| 高级用户 | 配置多个凭据实例、路由策略、成本/限流、目标绑定 |
| Agent 用户 | 创建 Agent Profile，为任务选择能力和推理等级，导入会话 |
| 运维用户 | 管理本地/远程节点、服务、端口、隧道、日志和诊断 |
| 开发者 | 添加新 ProviderDefinition/ProtocolAdapter/TargetAdapter 并通过契约测试 |

## 6. 功能需求

### 6.1 账号与身份中心

- 保留现有 ChatGPT/Codex 账号池、5 小时/周配额、智能切换和手动切换。
- 新增 `CredentialIdentity`：API Key、OAuth Session、Subscription Import、Environment Reference、External CLI Session。
- 同一供应商允许多个身份和多个账单通道并存。
- UI 永不回显秘密；仅显示来源、最后验证时间、权限/过期状态和指纹尾部。
- 导入外部会话必须显示来源路径、将被读取的字段和是否复制；优先引用外部会话，不复制。
- 凭据删除需列出受影响的 ProviderInstance、ModelEntry、TargetBinding 和 RoutePolicy。

### 6.2 供应商注册表

- 内置注册表定义供应商家族、默认端点、认证类型、协议、模型发现方式、限流解析器、余额连接和地区信息。
- 用户可新建自定义 OpenAI-compatible、Anthropic Messages 或 Gemini 端点。
- `ProviderDefinition` 不含用户秘密；`ProviderInstance` 引用 `CredentialRef`。
- 供应商注册表可签名更新，但用户覆盖保留在独立层，不直接修改内置文件。
- 预设至少覆盖：OpenAI Native、Kimi OAuth/API、DeepSeek、Grok OAuth/API、Anthropic、Gemini、Qwen/DashScope、Z.ai、MiniMax、Ollama Cloud、OpenRouter、Groq、Together、Fireworks、Cerebras、Mistral、NVIDIA NIM、SiliconFlow、Hugging Face Router、Volcengine Ark、opencode Go、Custom OpenAI-compatible。
- 相同模型通过不同供应商/计划出现时必须并存，不自动合并账单与配额。

### 6.3 模型目录

- 模型条目唯一键：`providerInstanceID + backendModelID`。
- 元数据来源优先级：供应商实时响应 > 用户确认 > 内置注册表 > 保守回退。
- 支持上下文窗口、推理等级、输入/输出模态、工具调用、并行工具、Computer Use、结构化输出、音频、实时、缓存、区域和价格元数据。
- 模型状态：Available、Unverified、Degraded、Incompatible、Hidden、CredentialMissing。
- 支持 live catalog、搜索、批量策展、隐藏、别名、单模型 smoke test 和契约测试。
- 付费测试默认关闭；执行前显示预计请求和供应商。
- Codex 目录合并必须保留原生目录，并对每次写入生成 diff。

### 6.4 目标应用

- `TargetDefinition`：Codex App、Codex CLI、Cursor、opencode、Custom OpenAI Client。
- 每个目标拥有独立：状态目录、caller capability、内部 capability、端口、启用供应商、默认模型、别名映射、服务实例和配置备份。
- Codex App/CLI 可共享目标配置，但允许用户拆分。
- 目标适配器必须实现：detect、plan、apply、verify、rollback、uninstall。
- 不覆盖未标记的用户配置；所有托管块有开始/结束标记和 schema/version。
- 目标重启由用户确认；除非目标适配器明确支持安全重启，不静默关闭应用。

### 6.5 路由引擎

路由分三层，禁止混成单个 `provider/model` switch：

1. **目标路由**：哪个客户端/服务实例接收请求。
2. **模型路由**：显式模型、别名或 Auto Policy 选择哪个模型实例。
3. **凭据/账号路由**：在同一实例池中选择可用账号或 credential identity。

路由流程：

- 先解析显式选择；显式选择优先。
- 执行硬约束：认证、目标兼容、协议、工具/图像/CUA/Realtime、上下文、区域、预算和用户禁用项。
- 对剩余候选进行可配置评分：用户优先级、健康、剩余配额、延迟、成本、会话亲和性。
- 保存 `RouteDecisionTrace`，包含过滤原因、分数、选中项、失败转移链和重试决定。
- 默认不跨供应商自动失败转移，用户启用后才生效；工具/CUA 会话默认保持模型亲和性。
- 重试必须区分网络、429、5xx、上下文超限、协议错误和工具状态错误，禁止盲目重复会产生副作用的请求。

### 6.6 协议与能力适配

- 支持 OpenAI Responses、Chat Completions、Anthropic Messages、Gemini GenerateContent/OpenAI-compatible。
- 核心采用规范化中间表示 `CanonicalRequest/CanonicalEvent`，适配器只负责边界转换。
- 支持 SSE、chunked、非流式、压缩/解压、背压、取消、超时、结构化错误。
- Tool call ID、arguments、reasoning、usage 和 finish reason 必须可逆或明确标记 lossiness。
- Compaction 只在原生支持或用户指定兼容策略时启用；禁止静默截断工具状态。
- 供应商特有 Header 采用 allowlist，不转发 ChatGPT/Codex 身份、安装或 attestation 信息。

### 6.7 Agent 与工具能力

- Agent Profile 包含：能力描述、默认模型策略、推理等级、工具权限、工作目录策略、环境变量引用、超时和预算。
- 路由依据用户保存的能力标签与模型能力矩阵，不根据模型名猜测。
- MCP 配置由目标应用继续执行；Copool 只做发现、展示、权限提示和兼容性转换。
- Computer Use 通过 Codex 原生执行链或显式注册的受信执行器桥接；外部模型不直接获得系统控制权限。
- 原生图像桥接保留 MIME、尺寸和来源；任何临时文件有生命周期和清理策略。
- 子代理编排记录父子任务、模型、预算、工具和结果引用；不把整段秘密环境复制给子代理。

### 6.8 会话中心

- 索引 Codex 会话、Copool 路由会话和可识别外部 Agent 会话。
- 原始会话文件是 source of truth；SQLite/SwiftData 仅做索引和搜索。
- 支持预览、标签、搜索、导出、删除、恢复引用和去重。
- 外部导入采用 Adapter，显示可导入字段和丢失字段；不伪造“完整兼容”。
- 会话详情展示模型/供应商/账号、工具、路由决策、token、费用估算和错误时间线。

### 6.9 Voice 与 Realtime

- Voice Center 是独立插件，默认不加载麦克风/音频依赖。
- STT、TTS、VAD、Realtime Transport 和 Task Delegate 分离。
- 用户可用实时模型对话，并将结构化任务委派给任一可用 coding model。
- 全局语音条沿用 Copool 胶囊/Material 视觉；必须有明确录音状态、取消、权限和隐私提示。
- 音频默认不持久化；需要保存时显式选择并展示路径和保留期。

### 6.10 运行时与远程节点

- 将现有 Proxy 页升级为 Runtime 页：Local Router、Targets、Remote Nodes、Public Access、Logs。
- 本地服务绑定 `127.0.0.1` 或 Unix Domain Socket；不提供 `0.0.0.0` 快捷开关。
- Cloudflare Tunnel/远程暴露必须单独风险提示，默认只暴露受强认证的管理/代理端点。
- 远程节点使用节点身份、证书/密钥轮换、能力声明和版本握手；不能上传本地 Keychain 秘密。
- 每个节点有健康、版本、路由能力、负载、更新时间和 rollback 版本。

### 6.11 用量、配额与成本

- 原生 OpenAI 账号保持 5h/周配额模型。
- 第三方从 vendor API、rate-limit headers 或路由观测获得数据，并标记来源和时间。
- 不存在公开余额 API时，明确显示“仅路由观测”，不伪装实际余额。
- 支持按供应商、模型、目标、账号、Agent、日期聚合；费用为估算时标明价格版本。
- 路由策略可配置日/月预算和软/硬阈值。

### 6.12 Doctor、诊断与支持包

- Doctor 分层检查：文件权限、端口、服务、caller/internal capability、凭据存在、目录、目标配置、模型路由、可选 live test。
- 输出 PASS/WARN/FAIL、修复建议和可自动修复项。
- 支持包默认不含日志、请求、响应和会话；用户选择附加时先脱敏预览。
- 日志使用结构化事件和关联 ID，秘密/完整 capability/授权头永不记录。

## 7. UI/UX 要求

- 顶层 5 Tab：**账号、模型服务、运行时、Agent、设置**。
- “模型服务”二级：Providers、Models、Routes、Usage。
- “运行时”二级：Overview、Targets、Remote、Public、Logs。
- “Agent”二级：Profiles、Sessions、Tools、Live（P2）。
- “设置”二级：General、Security、Diagnostics、Advanced。
- 保留 16pt 页面与 section 间距、14pt 卡片、胶囊式主切换、Material/Glass、系统图标和统一 NoticeBanner。
- 默认模式隐藏 protocol、raw endpoint、alias table、internal ID；Expert Mode 显示。
- 不引入左侧常驻大导航，不复制 P2/P3 Dashboard。

## 8. 数据迁移

- `ProviderStore v1 -> Registry v2`：生成稳定 providerInstanceID；名称仅作为 displayName。
- 将 `apiKey/refreshToken` 迁入 Keychain/SecureStore，配置只保留 `CredentialRef`；成功验证后再删除明文字段。
- 现有 modelProtocols 转为 `ProtocolBinding`；无法判断时保留原协议并标 `migrated-unverified`。
- 现有代理设置、远程节点和 Codex 模型缓存备份后迁移。
- 每次迁移写 migration journal，可恢复到上一 schema 和文件快照。

## 9. 发布约束

- 默认不进行付费模型测试。
- 不要求用户在聊天、日志或 issue 中粘贴秘密。
- 不在未确认时重启 Codex/Cursor/opencode。
- P0 完成前不发布 Voice/Realtime，避免基础安全和运行时同时失控。
- P1/P2 通过 feature flag 逐步启用。

## 10. 验收定义

- 见 `28_acceptance_matrix.md`。
- 所有 P0 AC 通过、迁移 fixture 通过、Doctor 无 FAIL、秘密扫描通过、UI snapshot 通过，才可将 vNext 默认启用。


---


# 05. 信息架构

## 顶层结构（保持 5 个主 Tab）

```text
Copool
├─ 账号 Accounts
│  ├─ 账号池
│  ├─ 配额概览
│  ├─ 导入/切换
│  └─ 账号策略
├─ 模型服务 Models
│  ├─ Providers
│  ├─ Catalog
│  ├─ Routes
│  └─ Usage
├─ 运行时 Runtime
│  ├─ Overview
│  ├─ Targets
│  ├─ Remote Nodes
│  ├─ Public Access
│  └─ Logs
├─ Agent
│  ├─ Profiles
│  ├─ Sessions
│  ├─ Tools & MCP
│  └─ Live / Voice
└─ 设置 Settings
   ├─ General
   ├─ Security
   ├─ Diagnostics
   └─ Advanced
```

## 导航规则

- 顶层继续使用 P1 胶囊图标切换器，不加文字常驻，accessibility label 保留。
- 二级导航使用紧凑 segmented control 或横向 scroll chips。
- 列表到详情使用 `NavigationStack`/sheet，不在固定宽度上并列三栏。
- 高风险操作统一在 detail sheet 中预览影响和 diff。
- 全局 Usage Summary 只显示 2–4 个最重要指标；详细图表进入 Usage。

## 搜索与命令

- Catalog、Sessions、Logs 提供局部搜索。
- P1 后续可增加 Command Palette，但不作为 P0 阻塞项。


---


# 08. 视觉系统要求

## 必须继承的 P1 视觉规则

- 菜单栏窗口、固定宽度与轻量层级。
- 页面水平内边距 16pt；section 间距 16pt；列表行间距 10pt。
- 卡片圆角 14pt。
- 主导航为胶囊容器；选中项使用 Material/Glass + 低透明度 accent tint。
- SF Symbols、系统字体、系统语义色。
- NoticeBanner 统一承载 success/warning/error，不在每个页面复制 toast。
- 高密度数据优先卡片摘要 + detail sheet，不使用企业 Dashboard 式大表格堆叠。

## 新增视觉 token

| Token | 建议 |
|---|---|
| `statusDotSize` | 8pt |
| `metadataChipRadius` | 8pt |
| `detailSheetMinWidth` | 520pt，仅独立窗口/大屏；菜单栏内保持当前宽度 |
| `compactChartHeight` | 72pt |
| `decisionScoreBarHeight` | 6pt |
| `dangerSurfaceOpacity` | 0.08 |

## 组件扩展原则

- 新组件优先组合 `SectionSurface`、`SectionActionStyle`、`NoticeBanner` 和现有 progress/tag。
- Provider/Target/Agent 卡片共享 `ResourceCardShell`，但内容 slot 独立。
- 状态颜色必须同时配图标/文字，不能仅靠颜色。
- Expert Mode 字段使用 disclosure group，默认折叠。
- 不复制 P2/P3 的 Web/Tauri Dashboard、品牌色、图标和截图构图。


---


# 11. 数据模型

## 核心实体

```swift
struct ProviderDefinition {
    let id: ProviderDefinitionID
    let displayName: String
    let ownership: String
    let supportedProtocols: Set<APIDialect>
    let defaultEndpoints: [EndpointTemplate]
    let credentialKinds: Set<CredentialKind>
    let discoveryStrategy: DiscoveryStrategy
}

struct CredentialIdentity {
    let id: CredentialID
    let kind: CredentialKind
    let secureReference: SecureReference
    let source: CredentialSource
    let scopes: [String]
    let expiresAt: Date?
    let lastVerifiedAt: Date?
}

struct ProviderInstance {
    let id: ProviderInstanceID
    let definitionID: ProviderDefinitionID
    var displayName: String
    var endpoint: URL
    var credentialID: CredentialID
    var protocolBindings: [ProtocolBinding]
    var enabled: Bool
}

struct ModelCatalogEntry {
    let id: ModelEntryID // providerInstanceID + backendModelID
    let backendModelID: String
    var displayName: String
    var capabilities: ModelCapabilities
    var metadataSources: [MetadataField: MetadataSource]
    var compatibility: [TargetID: CompatibilityGrade]
    var visibility: ModelVisibility
}

struct TargetBinding {
    let id: TargetBindingID
    let targetDefinitionID: TargetDefinitionID
    let stateDirectory: URL
    let callerCapabilityRef: SecureReference
    let internalCapabilityRef: SecureReference
    let serviceID: String
    let listenEndpoint: LocalEndpoint
    var enabledProviderInstances: Set<ProviderInstanceID>
}

struct RoutePolicy {
    let id: RoutePolicyID
    let scope: RouteScope
    var hardConstraints: RouteConstraints
    var weights: RouteWeights
    var fallback: FallbackPolicy
    var budget: BudgetPolicy?
}
```

## 关系

```text
ProviderDefinition 1---* ProviderInstance *---1 CredentialIdentity
ProviderInstance 1---* ModelCatalogEntry
TargetDefinition 1---* TargetBinding
TargetBinding *---* ProviderInstance
RoutePolicy *---* ModelCatalogEntry / AccountPool / TargetBinding
AgentProfile 1---1 RoutePolicy
Session *---1 TargetBinding; *---1 ModelCatalogEntry; *---0..1 Account/Credential
RemoteNode 1---* TargetRuntime
```

## 存储

- 非秘密配置：版本化 JSON 或 SQLite，原子写入。
- 秘密：Keychain/系统安全存储；配置仅存 opaque reference。
- 会话索引/使用量/decision trace：SQLite，按保留期清理。
- 目标配置快照：权限保护目录，含 hash、schema、before/after 和 rollback manifest。
- 模型注册表：内置只读层 + 签名更新层 + 用户覆盖层。

## Schema 约束

- 所有 ID 不依赖 displayName。
- URL 必须经过 scheme/host 策略校验；覆盖端点视为高信任配置。
- Secret 类型不可 Codable、不可日志格式化、不可出现在错误 description。
- 每个 snapshot 包含 `createdByVersion` 和 `sourceHash`。


---


# 12. API 与内部契约

## Router Core 协议

```swift
protocol RouterEngine {
    func start(binding: TargetBinding) async throws
    func stop(bindingID: TargetBindingID) async throws
    func route(_ request: CanonicalRequest, context: RouteContext) async throws -> AsyncThrowingStream<CanonicalEvent, Error>
    func health(bindingID: TargetBindingID) async -> RouterHealth
}

protocol ProviderAdapter {
    static var dialect: APIDialect { get }
    func encode(_ request: CanonicalRequest, model: ModelCatalogEntry) throws -> ProviderHTTPRequest
    func decode(_ response: ProviderHTTPResponse) throws -> AsyncThrowingStream<CanonicalEvent, Error>
}

protocol TargetAdapter {
    func detect() async throws -> TargetDetection
    func plan(_ desired: TargetDesiredState) async throws -> ConfigurationPlan
    func apply(_ plan: ConfigurationPlan) async throws -> ApplyReceipt
    func verify(_ receipt: ApplyReceipt) async throws -> VerificationReport
    func rollback(_ receipt: ApplyReceipt) async throws
}
```

## CanonicalRequest 关键字段

- request/session/turn ID
- model selector（explicit/alias/auto policy）
- system/developer/user/tool items
- input image/audio/file references
- tool definitions、tool choice、parallel policy
- reasoning policy
- response format
- context/budget/timeout/idempotency
- target capability context

## CanonicalEvent

- response.created
- reasoning.delta/summary
- output_text.delta
- tool_call.created/arguments.delta/completed
- image/audio event
- usage
- warning（lossy translation/unsupported field）
- response.completed/failed/cancelled

## Local Control API

仅绑定 UDS 或 `127.0.0.1`，需要管理 capability：

- `GET /v1/health`
- `GET /v1/providers`
- `GET /v1/catalog`
- `GET /v1/targets`
- `POST /v1/doctor`
- `POST /v1/config/plan`
- `POST /v1/config/apply`
- `POST /v1/config/rollback`
- `GET /v1/decisions/{id}`

模型流量端点使用目标 caller capability，与管理 capability 分离。

## 错误分类

`AuthenticationError`, `RateLimitError`, `ProviderUnavailable`, `ProtocolTranslationError`, `CapabilityMismatch`, `ContextOverflow`, `ToolStateConflict`, `TargetConfigurationError`, `SecurityPolicyViolation`, `Cancelled`。


---


# 13. 目标架构

## 架构原则

1. **控制面与数据面分离**：SwiftUI 不直接承担网络流转换。
2. **先抽取、后替换**：利用现有 Swift 运行时建立接口和 golden tests，再逐步拆出独立进程。
3. **一个 Canonical Core，多边界 Adapter**：避免每个 provider/target 互相转换形成 N×M。
4. **目标隔离**：共享代码，不共享信任根和运行状态。
5. **秘密引用**：领域模型和 IPC 不传可持久化明文秘密。

## 推荐模块

```text
CopoolApp (SwiftUI/MenuBarExtra)
├─ CopoolDesignSystem
├─ CopoolAccountsFeature
├─ CopoolModelsFeature
├─ CopoolRuntimeFeature
├─ CopoolAgentsFeature
├─ CopoolSettingsFeature
├─ CopoolApplication
│  ├─ UseCases
│  ├─ Migrations
│  └─ DependencyContainer
├─ CopoolDomain
│  ├─ Identity
│  ├─ ProviderRegistry
│  ├─ ModelCatalog
│  ├─ Routing
│  ├─ Targets
│  ├─ Agents
│  └─ Sessions
├─ CopoolRouterKit
│  ├─ CanonicalProtocol
│  ├─ RouteEngine
│  ├─ ProviderAdapters
│  ├─ Streaming
│  ├─ ToolBridge
│  └─ Observability
├─ CopoolTargetKit
│  ├─ CodexTargetAdapter
│  ├─ CursorTargetAdapter
│  └─ OpencodeTargetAdapter
├─ CopoolSecureStore
├─ CopoolPersistence
└─ CopoolRouterHost (standalone executable)
```

## 运行形态

### 过渡期

- `InProcessRouterEngine` 包装当前 `SwiftNativeProxyRuntimeService`。
- 新旧路径同时跑 fixture，不进行真实双发请求。
- UI 只依赖 `RouterEngine` 和 application use cases。

### vNext 默认

- `CopoolRouterHost` 作为每用户后台进程；每个 TargetBinding 拥有独立 listener/capability/state。
- SwiftUI 通过 UDS/受 capability 保护的 local control API 管理。
- Remote Node 使用同一 Canonical/Registry schema 和版本握手。

## 为什么不直接嵌入 P2 Node 网关

- P1 已有 Swift 转换和代理能力；直接嵌入会制造双运行时、双模型目录和双凭据源。
- P2 的部分服务存在巨型文件，维护和测试边界不符合 P1 当前分层方向。
- Clean-room 与许可证边界要求重新实现行为契约。

## 为什么不把 P3 Tauri UI 合并进来

- 用户明确要求保持 P1 原 UI；Tauri/Web UI 会改变交互、打包和视觉系统。
- P3 最值得吸收的是安全/目标隔离/Doctor/注册表，而非 UI 技术栈。

## 扩展点

- 新供应商：`ProviderDefinition + ProviderAdapter + ContractFixtures`。
- 新目标：`TargetAdapter + ManagedConfigSchema + DoctorChecks`。
- 新能力：Feature Plugin 声明依赖和权限；不在 Router Core 中硬编码 UI。


---


# 26. 供应商与认证矩阵

> 模型名称不作为长期硬编码。以下是 ProviderDefinition/认证面的产品范围。

| Provider Family / Instance | 认证 | 主要协议 | 目录 | 首发级别 |
|---|---|---|---|---|
| OpenAI Native / ChatGPT Accounts | Codex/ChatGPT 登录 | Responses native | 原生目录合并 | P0 |
| Generic OpenAI-compatible | API key/env/secure file | Chat/Responses | `/models`/手工 | P0 |
| Anthropic | API key/可识别订阅导入 | Messages | 手工/live | P0 |
| Google Gemini | API key | Gemini native/OpenAI-compatible | live | P0 |
| DeepSeek | API key | OpenAI-compatible | live/registry | P0 |
| Kimi Platform | API key | OpenAI-compatible | live/registry | P0 |
| Kimi Code | 外部 CLI OAuth | OAuth forward | credential-aware | P1 |
| xAI Grok API | API key | OpenAI-compatible | live | P1 |
| xAI Grok OAuth | 外部 CLI OAuth | OAuth forward | credential-aware | P1 |
| Qwen/DashScope | plan/PAYG key | OpenAI-compatible | live | P0 |
| Z.ai | coding/general key | OpenAI-compatible | live | P0 |
| MiniMax | API/token plan key | OpenAI-compatible/特殊适配 | live | P0 |
| OpenRouter | API key | OpenAI-compatible | live 策展 | P0 |
| Volcengine Ark | API key | OpenAI-compatible | endpoint/手工 | P0 |
| Ollama Cloud | API key | OpenAI-compatible | live 策展 | P1 |
| Groq/Together/Fireworks/Cerebras/Mistral/NVIDIA/SiliconFlow/HF Router | API key | OpenAI-compatible | live 策展 | P1 |
| opencode Go | API key | Chat/Messages/Responses variant | live/手工 | P1 |
| Local Ollama/LM Studio | 无/本地 key | OpenAI-compatible | live | P1（通用预设） |
| Cursor/Claude/Antigravity subscription import | 外部会话引用 | 供应商特定 | 探测 | P1/实验 |

## Registry 字段

- id/displayName/owner/kind/protocols/default endpoints/base URL env override。
- credential sources（env、Keychain service、external session path、protected file）。
- discovery strategy、quota/rate-limit parser、balance URL（若存在）。
- headers allowlist、required headers、regional variants。
- compatibility notes、lastVerifiedAt、registryVersion。


---


# 27. 迁移计划

## 数据迁移步骤

1. 获取全局迁移锁。
2. 备份 ProviderStore、账号存储、代理设置、Codex 配置、models cache、remote config。
3. 解析 v1；为每个 provider 生成稳定 UUID 和 definition match。
4. 将 API key/refresh token 写入 SecureStore，读回验证；仅成功后写 `credentialRef`。
5. 转换模型和 protocol binding，保留原 displayName/addedAt。
6. 生成 v2 shadow store，不覆盖 v1。
7. 运行 schema/引用/credential presence/target plan 验证。
8. 原子切换 active store；写 migration receipt。
9. 启动新路径健康检查；失败自动恢复 v1 和原配置。
10. 经过一个发布周期后才清理旧 secret 字段/备份，且用户可主动清理。

## 配置迁移原则

- 只识别 Copool 自己标记的 block；未知来源不接管。
- 保留原生 model/provider/reasoning/profiles/MCP/project trust。
- 每个 Target 独立备份和 receipt。
- WSL/多 CODEX_HOME 需要显式选择，禁止猜测。

## 兼容期

- vNext 首两个版本可读取 v1，但只写 v2。
- rollback 工具可恢复 v1 snapshot。
- 日志记录 migration ID，不记录 secret value。


---


# 14. 测试策略

## 测试金字塔

### 1. 领域单元测试

- ID 稳定性、依赖图、评分、预算、迁移、元数据优先级。
- Secret 类型不可编码/打印。

### 2. 协议 fixture/contract tests

每种协议覆盖：

- 非流式与 SSE。
- reasoning/text/tool calls/parallel tools。
- image input、structured output、usage。
- 错误、429、5xx、取消、超时、断流。
- gzip/br/zstd 与编码/解码上限。
- lossless/lossy 字段声明。

### 3. 目标配置测试

- detect/plan/apply/verify/rollback。
- 保留用户未托管字段。
- 拒绝未知 base URL/catalog。
- 原子写入、权限和损坏恢复。
- 登录无关模式开启/关闭精确恢复。

### 4. 安全测试

- 日志/Doctor/support bundle secret scanning。
- caller/internal capability 不能互换。
- 浏览器 Origin/CORS 拒绝。
- 外部请求不含 ChatGPT/Codex 身份头。
- SSRF/base URL override 风险提示和策略。
- 同一目标、跨目标、同一 OS 用户边界测试。

### 5. UI 测试

- P1 现有 Accounts/Proxy/Providers/Agents/Settings snapshot 基线。
- 新二级导航在固定面板宽度下无截断。
- Voice/permission/错误和动态字体。
- keyboard/VoiceOver。

### 6. 迁移测试

- v1 ProviderStore、明文 secret、旧 modelProtocols、旧缓存、旧 remote config fixtures。
- 中断恢复、重复迁移、回滚、部分 Keychain 失败。

### 7. Live tests

- 默认关闭，需 `--live --yes` 或 UI 二次确认。
- 不在 PR CI 注入供应商秘密。
- 记录 provider/model/estimated cost；不保存 prompt/response。

## CI 门槛

- `swift build`、`swift test`。
- lint/format（若仓库引入）。
- schema compatibility。
- fixture contract suite。
- secret scan。
- UI snapshot（macOS runner）。
- 安装/回滚 smoke test（隔离 HOME/CODEX_HOME）。


---


# 28. 验收矩阵

## P0

| ID | 验收标准 | 验证方式 |
|---|---|---|
| AC-001 | 现有账号导入、切换、配额刷新、智能切换通过 | 回归 UI/单元/fixture |
| AC-002 | 现有本地代理和远程代理核心场景通过 | integration fixtures + smoke |
| AC-003 | ProviderConfig v2 不含可持久化 secret value | 类型/编码/secret scan |
| AC-004 | v1 provider/secret/model protocol 可迁移且可回滚 | migration fixtures |
| AC-005 | 路由键不依赖可变 displayName | rename test |
| AC-006 | OpenAI native 模型/登录/配置未被外部 provider 覆盖 | isolated CODEX_HOME test |
| AC-007 | Codex target 支持 detect/plan/diff/apply/verify/rollback | target contract test |
| AC-008 | 每 target caller/internal capability、state、listener 独立 | cross-target negative tests |
| AC-009 | Router 只绑定 UDS/127.0.0.1，Origin/CORS 安全通过 | network security tests |
| AC-010 | 外部 provider 请求无 ChatGPT/Codex 身份/attestation headers | header fixture |
| AC-011 | Catalog 凭据感知、live discovery、策展、来源优先级正确 | catalog tests |
| AC-012 | Auto route 先硬过滤后评分，并生成 decision trace | deterministic route tests |
| AC-013 | 429/5xx/网络/工具状态重试策略正确 | fault injection |
| AC-014 | Doctor 输出分层 PASS/WARN/FAIL 且已脱敏 | snapshot + secret scan |
| AC-015 | UI 维持 5 主 Tab、原 token，固定宽度无溢出 | UI snapshot/accessibility |
| AC-016 | `swift build`、`swift test` 通过 | CI |

## P1

| ID | 验收标准 |
|---|---|
| AC-101 | Cursor/opencode 配置与状态完全隔离，卸载不影响 Codex |
| AC-102 | Session Center 可索引、搜索、预览和适配器导入 |
| AC-103 | Agent Profile 以能力/策略路由，不基于名字猜测 |
| AC-104 | MCP/tool/image/CUA 保持原生受信执行边界 |
| AC-105 | 登录无关模式开启/关闭精确恢复原配置 |
| AC-106 | Usage 明确区分 vendor/header/observed/estimated |

## P2

| ID | 验收标准 |
|---|---|
| AC-201 | Voice 插件未启用时不请求麦克风或加载媒体服务 |
| AC-202 | Realtime 对话可产生经用户确认的 TaskEnvelope 并委派 |
| AC-203 | 音频默认不持久化，权限/录音状态明确 |
| AC-204 | Remote Node 版本握手、身份、升级和 rollback 可验证 |


---


# 16. 构建计划

## Phase 0 — 基线冻结

- 建立当前功能清单、截图基线、数据 fixture、代理请求/响应 fixture。
- 记录当前构建、测试和已知失败。
- 新建 `docs/refactor/` 决策日志和迁移台账。

## Phase 1 — 模块边界（无行为变化）

- 拆 `CopoolDomain`、`CopoolDesignSystem`、`CopoolApplication`。
- 用协议包裹 ProviderStore、SecureStore、RouterRuntime、TargetConfig。
- 对当前 `SwiftNativeProxyRuntimeService` 建立 façade。

## Phase 2 — Registry v2 与秘密治理

- 引入 ProviderDefinition/Instance/CredentialIdentity/ModelEntry。
- 实现 v1 migration journal、Keychain-only 模型、依赖图。
- 内置 provider registry，支持用户覆盖。

## Phase 3 — Canonical Router Core

- CanonicalRequest/Event/Error。
- 提取 streaming、decompression、retry、compaction、usage。
- 将当前第三方适配器迁到 contract-based adapters。

## Phase 4 — Target 隔离与配置治理

- TargetBinding、capabilities、state dirs、listeners。
- Codex TargetAdapter：detect/plan/apply/verify/rollback。
- Doctor P0、配置 diff、支持包脱敏。

## Phase 5 — 模型目录与路由策略

- credential-aware catalog、live discovery、策展、metadata source。
- RoutePolicy、decision trace、account/credential pools、failover。
- UI Models/Routes/Usage。

## Phase 6 — 独立 Router Host

- 把 RouterEngine 移入 `CopoolRouterHost`。
- UDS/local control API、service lifecycle、migration from in-process。
- 每个 TargetBinding 独立 capability/state/port。

## Phase 7 — Cursor/opencode、Session 与 Agent

- 目标适配器 Beta。
- Session index/import adapters。
- Agent Profiles、MCP/tool bridge、native image/CUA bridge。

## Phase 8 — Voice/Realtime

- STT/TTS/VAD 抽象、Realtime transport、TaskEnvelope。
- 全局 Live capsule、权限和隐私控制。

## Phase 9 — Remote/跨平台

- Remote Node 协议、版本握手、节点身份、更新/回滚。
- Windows router daemon/CLI 可行性；不改 P1 macOS UI。

## 每阶段完成门槛

- 更新 ADR/decision log。
- 单元/contract/migration/security tests 通过。
- UI snapshot 或明确批准的变更。
- 无新增秘密泄漏。
- 生成本阶段 rollback 说明。
- 小粒度提交；不要在未通过门槛时合并到默认分支。
