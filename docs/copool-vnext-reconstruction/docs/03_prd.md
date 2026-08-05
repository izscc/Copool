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
