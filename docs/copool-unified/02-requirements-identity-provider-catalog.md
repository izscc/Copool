# 02 · 功能需求：身份、凭据、供应商与模型目录

> 覆盖能力矩阵 A 组（CAP-IDT-\*）与 B 组（CAP-PRV-\* / CAP-CAT-\*）。
> 需求编号规则：`FR-<域>-<序号>`。每条需求标注**来源能力 ID**、**优先级**、**验收要点**。
> 种子数据见 [`seed/provider-registry-seed.json`](./seed/provider-registry-seed.json)。

---

## 2.1 领域词汇（先统一口径）

本章反复出现的四个概念必须严格区分，它们已经落地在 `Sources/Copool/Domain/VNextRegistry.swift`：

| 概念 | 类型 | 谁产生 | 是否含秘密 | 生命周期 |
| --- | --- | --- | --- | --- |
| **ProviderDefinition** | 公开定义 | Copool 随包发布 / 用户自定义 | 否 | 跟随版本升级 |
| **ProviderInstance** | 用户配置 | 用户 | 否（只存引用） | 用户创建/删除 |
| **CredentialIdentity** | 凭据身份 | 用户授权动作 | 否（只存 `SecureReference`） | 可失效、可重授权 |
| **ModelCatalogEntry** | 模型条目 | 种子数据 / 实时发现 | 否 | 随目录刷新 |

**一条铁律**：秘密值（API Key、access token、refresh token）永远不进任何 `Codable` 结构、不进任何日志、不进支持包。落盘的只有 `SecureReference{storage, name}`——要么是 Keychain account 名，要么是环境变量名。

**第二条铁律**（AC-005，沿用旧 vNext 结论）：任何 ID 都不得由 `displayName` 派生。用户改显示名不能改变任何持久化键。

---

## 2.2 身份与凭据需求（FR-IDT-\*）

### 2.2.1 凭据种类与生命周期

Copool 支持五种 `CredentialKind`。现有代码已定义 `apiKey` / `oauth` / `subscriptionImport`，本次扩展为五种：

| Kind | 用户动作 | 存储位置 | 失效表现 | 恢复路径 |
| --- | --- | --- | --- | --- |
| `apiKey` | 粘贴 Key | Keychain | 401/403 | 重新粘贴 |
| `environmentReference` | 填变量名 | 不存储（运行时读进程环境） | 变量缺失 → 未就绪 | 提示用户设置变量并重启应用 |
| `oauthDeviceFlow` | 应用内授权 | Keychain（access + refresh） | refresh 失败 | 重新走授权 |
| `externalCLISession` | 授权读取本机 CLI 登录态 | **不复制**，每次按需读取 | 源文件缺失/过期 | 提示用户在对应 CLI 里重新登录 |
| `subscriptionImport` | 导入本机订阅客户端登录态 | Keychain（导入快照 + refresh） | refresh 失败 | 重新导入 |

---

**FR-IDT-01 · 账号池能力零回归**（CAP-IDT-01/02，P0）

现有 ChatGPT/Codex 账号池的导入、切换、删除、5h/周配额展示、智能切换评分**行为完全不变**。v2 注册表以**并行新增**方式引入，不改写 `AccountRecord` 的任何字段语义。

- 验收：现有 `Tests/CopoolTests` 中账号相关用例全部保持绿色，不允许以"重构"为由修改其断言。

---

**FR-IDT-02 · 统一凭据录入**（CAP-IDT-03，P0）

新增 `CredentialEntrySheet`，是所有凭据录入的**唯一入口**。

- 输入框使用 `SecureField`，永不回显明文；已保存的凭据显示为掩码 `sk-••••••••1234`（保留前 3 位 + 后 4 位，中间固定 8 个圆点，不泄露真实长度）。
- 保存时立即写 Keychain，内存中的明文字符串在 `defer` 中清零后释放。
- 同一 `ProviderInstance` 可挂多个 `CredentialIdentity`（多账号轮换），但**至少一个**才算就绪。
- Keychain 写入失败必须显式报错并中止，**禁止**降级为明文落盘。

---

**FR-IDT-03 · 环境变量凭据引用**（CAP-IDT-04，P1）

用户可选择"使用环境变量"，只填变量名（如 `DEEPSEEK_API_KEY`）。

- Copool 只持久化变量名，运行时从 `CopoolRouterHost` 进程环境读取。
- 每个内置 provider 预置候选变量名（见种子数据 `environmentVariables`），首次配置时如检测到该变量已存在，UI 上直接标记"已检测到"并作为默认选项。
- 变量在运行时缺失 → 该 instance 状态为 `未就绪`，其模型不进目标目录（见 FR-CAT-01）。

---

**FR-IDT-04 · 本机 CLI 登录态复用**（CAP-IDT-05/06，P1）

针对 `kimi-oauth` 与 `grok-oauth` 两个 provider。

- **不复制凭据**：Copool 不把 CLI 的登录态拷进自己的 Keychain，每次请求按需读取源文件，源文件变更立刻生效。
- 读取路径与请求端点见种子数据的 `externalSession` 块。
- 只读取，永不写回、永不删除源文件。

---

**FR-IDT-05 · 订阅客户端登录态导入**（CAP-IDT-07/08/09，P1/P2）

覆盖 Claude Desktop / Claude Code（P1）、Cursor（P2）、Antigravity（P2）。

- 每个来源需实现 `SubscriptionImportAdapter`：`detect() -> ImportCandidate?`、`preview() -> ImportPreview`、`import() -> CredentialIdentity`、`refresh()`。
- `ImportPreview` 必须展示：来源应用名、登录账号标识（邮箱/用户名，**脱敏**）、将要读取的文件路径、令牌有效期。
- 需兼容旧版加密缓存格式；解析失败时给出"请在 <应用名> 中重新登录后重试"，**不得**尝试猜测或修复源文件。

---

**FR-IDT-06 · 导入前来源披露与显式确认**（CAP-IDT-11，P0，**合规红线**）

任何读取第三方应用登录态的动作（FR-IDT-04、FR-IDT-05）在首次执行前，必须弹出确认页，逐条列出：

1. 将读取哪个应用、哪个文件路径；
2. 读到的凭据将用于什么（"仅用于向该服务商发起你在 Copool 中发起的推理请求"）；
3. 凭据是否会被复制存储（CLI 复用 = 否；订阅导入 = 是，存 Keychain）；
4. 如何撤销。

用户必须主动勾选"我已阅读并授权"才能继续。**默认不勾选**，**不提供"不再提示"**。确认记录（时间戳 + 来源 + 版本）写入本地审计日志。

---

**FR-IDT-07 · 凭据健康状态与修复引导**（CAP-IDT-10，P0）

每个 `CredentialIdentity` 有五态：`就绪` / `未配置` / `已过期` / `无权限` / `校验中`。

- 状态由三个信号驱动：本地存在性检查、令牌过期时间、**最近一次真实请求的响应码**。
- 401 → `无权限`；403 + 配额类错误体 → 保持 `就绪` 但标记限流（属 CAP-RUN-07 范畴，不算凭据失效）；令牌过期时间已过 → `已过期`。
- 非 `就绪` 状态在供应商卡片上显示橙色/红色徽章，点击直达对应修复动作，**不需要用户自己去猜**。

---

**FR-IDT-08 · 凭据撤销**（P0）

删除 `CredentialIdentity` 时：删除 Keychain 条目 → 从所有引用它的 `ProviderInstance` 解绑 → 触发目录重建 → 若导致某目标应用的已启用模型失去凭据，提示用户"目标配置需要重新应用"。

**不删除**用户在第三方 CLI/客户端中的原始登录态。

---

## 2.3 供应商需求（FR-PRV-\*）

### 2.3.1 内置注册表

**FR-PRV-01 · 内置 23 家供应商**（CAP-PRV-01，**P0，本次整合的头号价值**）

随应用发布只读种子数据 `provider-registry-seed.json`，编译进 Bundle。用户打开供应商页即可看到完整列表，**无需手填 baseURL**。

| # | Provider ID | 显示名 | 协议 | 凭据方式 | 备注 |
| --- | --- | --- | --- | --- | --- |
| 1 | `kimi-oauth` | Kimi Code（OAuth 登录态） | chat | CLI 登录态 | 与 API 通道计费独立 |
| 2 | `kimi-api` | Kimi Platform API | chat | API Key | |
| 3 | `deepseek` | DeepSeek API | chat | API Key | |
| 4 | `grok-oauth` | xAI Grok（OAuth 登录态） | chat | CLI 登录态 | 附加 hosted 检索工具 |
| 5 | `grok-api` | xAI Grok API | chat | API Key | |
| 6 | `anthropic-api` | Anthropic API | **anthropic** | API Key | 独立限流头前缀 |
| 7 | `zai-coding` | Z.ai GLM Coding Plan | chat | API Key | 订阅制专用端点 |
| 8 | `qwen-plan` | Qwen（Model Studio 套餐） | chat | API Key | DashScope 兼容模式 |
| 9 | `ollama-cloud` | Ollama Cloud | chat | API Key | |
| 10 | `minimax-token-plan` | MiniMax Token Plan | chat | API Key | |
| 11 | `opencode-go` | opencode Go（Chat） | chat | API Key | 三通道共用一把 Key |
| 12 | `opencode-go-messages` | opencode Go（Messages） | **anthropic** | API Key | 同上 |
| 13 | `opencode-go-responses` | opencode Go（Responses） | **responses** | API Key | 同上 |
| 14 | `groq` | Groq | chat | API Key | 仅目录 |
| 15 | `openrouter` | OpenRouter | chat | API Key | 仅目录 |
| 16 | `together` | Together AI | chat | API Key | 仅目录 |
| 17 | `fireworks` | Fireworks AI | chat | API Key | 仅目录 |
| 18 | `cerebras` | Cerebras | chat | API Key | 仅目录 |
| 19 | `mistral` | Mistral AI | chat | API Key | 仅目录 |
| 20 | `nvidia-nim` | NVIDIA NIM | chat | API Key | 仅目录 |
| 21 | `siliconflow` | SiliconFlow 硅基流动 | chat | API Key | 仅目录 |
| 22 | `huggingface` | Hugging Face Router | chat | Access Token | 仅目录 |
| 23 | `gemini-api` | Google Gemini API | chat（OpenAI 兼容面） | API Key | 仅目录 |

**"仅目录"（`catalogOnly: true`）** 指该 provider 不带内置模型条目，模型全部来自实时发现（FR-CAT-03）——这些是聚合平台/推理平台，模型清单变化太快，硬编码只会过时。

- 验收：种子数据必须能被解码为 `[ProviderDefinition]` 且 ID 唯一；单测断言数量 = 23。
- 验收：所有 `defaultBaseURL` 必须是 `https://`（`kimi-oauth`/`grok-oauth` 为空字符串，由 CLI 登录态决定端点）。

---

**FR-PRV-02 · 同家厂商多通道并存**（CAP-PRV-04，P0）

Kimi、Grok 各有 OAuth 与 API 两条通道；opencode Go 有三条协议通道。它们是**独立的 ProviderDefinition**，不是同一个的两种模式。

理由：鉴权体系不同、计费独立、可用模型不同、限流独立。合并会导致用量统计与限流展示全部错乱。

- `opencode-go*` 三者共享 `sharedCredentialGroup: "opencode-go"`：用户填一次 Key，三个 instance 同时就绪；UI 上必须显示"该 Key 已被 3 个通道共用"，删除时明确警告影响面。

---

**FR-PRV-03 · 用户覆盖层**（CAP-PRV-03，P0）

用户对内置 provider 的修改（改 baseURL、改显示名、改超时）落在 `ProviderRegistryV2.userDefinitions` 覆盖层，**不写回种子**。

- 读取顺序：`userDefinitions[id]` → `builtInDefinitions[id]`；字段级覆盖，未设置的字段回落内置值。
- UI 必须显示"已修改"标记与"恢复默认"按钮。
- 应用升级带来新种子时，用户覆盖必须存活；若某字段的内置默认值发生变化而用户未覆盖过，直接采用新值并在变更日志中记录。

---

**FR-PRV-04 · 自定义供应商**（CAP-PRV-02，P0）

用户可新建 OpenAI-Compatible 供应商，填 `displayName` / `baseURL` / 协议 / 凭据。

- 自定义 ID 由 UUID 生成，**不从显示名派生**（AC-005）。
- 与内置 provider 在数据结构上完全平权，只有 `isBuiltIn` 标志不同。
- 现有 `ProviderConfig`（`Sources/Copool/Domain/ProviderModels.swift`）的手填能力保留，作为 v1 → v2 迁移的来源。

---

**FR-PRV-05 · 启用/停用**（CAP-PRV-05，P0）

`ProviderInstance.enabled` 为假时：其模型不进任何目标目录、不参与路由、不做连通性检查；但配置与凭据保留。

停用一个正在被目标应用引用的 provider 时，必须提示"这会从 <目标> 移除 N 个模型，需要重新应用配置"。

---

**FR-PRV-06 · baseURL 环境变量覆盖**（CAP-PRV-06，P1）

每个内置 provider 有 `baseUrlEnv`（如 `DEEPSEEK_API_BASE_URL`）。优先级：

```
用户覆盖层 baseURL  >  环境变量 baseUrlEnv  >  内置 defaultBaseURL
```

用于自建网关与区域切换（典型场景：`qwen-plan` 默认新加坡端点，国内用户需切北京）。当前生效来源必须在 UI 上标注。

---

## 2.4 模型目录需求（FR-CAT-\*）

### 2.4.1 目录的三个来源与合并顺序

```
① 内置种子条目（48 个）
② 实时发现（GET /models）
③ 用户策展与覆盖（隐藏、改显示名、改上下文窗口、加别名）
        ↓ 合并
   ModelCatalogEntry 集合（唯一键 = providerInstanceID + "/" + backendModelID）
        ↓ 凭据感知过滤（FR-CAT-01）
   目标应用可见目录
```

唯一键已在 `VNextRegistry.swift` 中实现为 `ModelCatalogEntry.id`（AC-011）。**不同 provider 下的同名模型是不同条目**——`deepseek/deepseek-v4-pro` 与 `qwen-plan/deepseek-v4-pro` 是两条独立记录，走不同鉴权、不同计费、不同 request profile。

---

**FR-CAT-01 · 凭据感知目录**（CAP-CAT-01，**P0，硬约束**）

一个模型只有在**全部**满足以下条件时才进入目标应用目录：

1. 所属 `ProviderInstance.enabled == true`；
2. 该 instance 至少有一个 `CredentialIdentity` 处于 `就绪`；
3. 该条目未被用户隐藏（`visibility != .hidden`）；
4. 该条目的协议在目标应用的 caller capability 支持范围内。

**理由**：目标应用的模型选择器里出现一个点了就报错的模型，比它压根不出现更糟——用户无法分辨是配置错了还是服务挂了。

- 验收：删除某 provider 的最后一个凭据后，重建目录，断言其所有模型均已从目标目录消失。
- UI 侧不适用此过滤：Copool 自己的供应商页**要**显示这些模型，并标注"缺少凭据"，这是引导用户配置的入口。

---

**FR-CAT-02 · 内置模型条目**（CAP-CAT-02，P0）

44 个种子条目见 `provider-registry-seed.json` 的 `catalog` 数组，每条至少含：`provider`、`backendModelID`、`displayName`、`contextWindow`、`autoCompact`、`reasoningEfforts`、`defaultReasoningEffort`、`inputModalities`、`requestProfile`。

逐家分布（13 家非 `catalogOnly` 供应商）：`kimi-oauth` 3、`kimi-api` 1、`deepseek` 4、`grok-oauth` 1、`grok-api` 1、`anthropic-api` 1、`zai-coding` 2、`qwen-plan` 8、`ollama-cloud` 4、`minimax-token-plan` 1、`opencode-go` 11、`opencode-go-messages` 6、`opencode-go-responses` 1。单测按此表逐家断言，而非只比总数——总数相等掩盖得了"一家掉了两条、另一家多了两条"。

- `autoCompact` 是建议的自动压缩阈值，恒小于 `contextWindow`（种子数据约取 85–90%）。单测断言此不变量。
- 标 `visibility: "hidden"` 的条目（如 `deepseek-chat`/`deepseek-reasoner`）是为兼容旧配置保留的别名，默认不在选择器出现，但路由时可解析。

---

**FR-CAT-03 · 实时模型发现**（CAP-CAT-03，P0）

对支持 `GET {baseURL}/models` 的 provider，提供"刷新模型列表"。

- 结果与种子条目按唯一键合并：**种子的元数据字段优先级更高**，实时发现只补充种子里没有的新模型。理由是 `/models` 返回的元数据普遍贫乏（多数只有 id 和 owned_by）。
- 发现失败不清空已有目录，只标记"上次刷新失败 + 时间 + 原因"。
- 请求超时 10s；失败不重试（用户可手动再点）。

---

**FR-CAT-04 · 用户策展**（CAP-CAT-04，P1）

对聚合平台（`catalogOnly` 的 10 家），实时目录常有数百条。用户从中勾选需要的，勾选结果**存活于后续刷新**——刷新只更新元数据，不重置勾选。

被移除的上游模型：保留勾选记录并标记"上游已下架"，不静默删除（否则用户下次刷新会莫名其妙丢配置）。

---

**FR-CAT-05 · 推理档位识别**（CAP-CAT-05，P0）

**绝对不猜测**。档位来源，按优先级：

1. 种子条目的 `reasoningEfforts`；
2. 供应商 `/models` 明确返回的推理能力字段；
3. 用户手动指定。

以上都没有 → 该模型**不显示推理档位选择器**，请求中**不附加**任何推理参数。

**明令禁止**：根据模型名包含 `thinking` / `reasoner` / `-r1` 等字样推断能力。猜错的代价是请求被上游 400 拒绝，而用户完全无从知晓原因。

现有 `ProviderModels.swift` 的 `effectiveReasoningEfforts` 会在 `supportedReasoningEfforts == nil` 时兜底返回 `["low","medium","high"]`——**这是与本条冲突的现存行为，v2 路径必须改为返回空数组**；v1 路径为兼容保留原行为直至迁移完成。

---

**FR-CAT-06 · 上下文窗口识别**（CAP-CAT-06，P0）

沿用已实现的 `ModelMetadataSource` 优先级（`ProviderModels.swift`）：

```
provider (3)  >  registry (2)  >  fallback (1)
```

`fallbackContextWindow = 200_000` 保持不变。`shouldReplace` 的语义（同级可覆盖，用于刷新同源数据）保持不变。UI 上必须能看出当前值来自哪一层——用 `fallback` 值的模型要有"估算值"标注。

---

**FR-CAT-07 · 显示名、后端 ID 与别名分离**（CAP-CAT-07，P0）

- `backendModelID`：发给上游的真实值，用户不可改。
- `displayName`：目标应用选择器里显示的名字，用户可改。
- `aliases[]`：路由时可接受的额外入参名，用于兼容用户既有配置与迁移。

别名解析冲突（两个条目声明了同一别名）→ 拒绝保存并指出冲突方，**不做静默优先级裁决**。

---

**FR-CAT-08 · 隐藏、搜索与批量操作**（CAP-CAT-08，P1）

模型列表支持按显示名/后端 ID 搜索、按 provider 分组折叠、多选后批量启用/停用/隐藏。这是 23 家 provider 场景下的可用性刚需。

---

**FR-CAT-09 · 连通性测试**（CAP-CAT-09，P0，**免费**）

复用已有 `ModelConnectivityTester`。约束：

- 只做**不消耗推理配额**的探测：优先 `GET /models`；若不支持，发 `max_tokens: 1` 的最小请求并明确告知用户"这会消耗极少量配额"。
- 结果三态：`通过` / `失败（含 HTTP 状态与响应摘要）` / `未测试`。
- **不得**把连通性失败当作凭据失效——网络问题与鉴权问题必须区分展示。

---

**FR-CAT-10 · 兼容性冒烟测试**（CAP-CAT-10，P1，**付费，默认关闭**）

发起真实推理请求验证工具调用、流式、推理参数是否被上游接受。

- 开关**默认关闭**，位于设置页的"高级"区。
- 打开后每次执行仍需**二次确认**，确认框明示"这会产生真实费用"。
- 结果写入模型条目的兼容性报告，展示每项（流式/工具调用/推理参数/多模态）的通过情况。

---

**FR-CAT-11 · 目录变更传播**（P0）

目录发生任何影响目标可见性的变更时，标记受影响的 `TargetBinding` 为 `配置已过期`，在目标页显示"需要重新应用"。

**不自动写入目标配置**——写目标配置是用户显式动作（见 03 章 FR-TGT-\*）。

---

## 2.5 请求 Profile（前置说明）

`requestProfile` 在种子数据中随模型条目下发，完整语义在 03 章 FR-PRO-07 定义。此处只声明它属于**模型元数据的一部分**，随目录一起管理。

已识别的 11 个 profile 见种子数据 `requestProfiles`。其中最关键的是 `dashscope-compatible`：DashScope 兼容模式会**拒绝**各厂商原生 thinking 参数，跨厂商模型（如经由 `qwen-plan` 调用的 `deepseek-v4-pro`、`glm-5.2`）必须剥离原生参数、改用兼容字段。这是"同名模型在不同 provider 下必须是独立条目"最有力的证据。

---

## 2.6 本章需求 → 能力矩阵回溯表

| 需求 | 能力 ID | 优先级 |
| --- | --- | --- |
| FR-IDT-01 | CAP-IDT-01, CAP-IDT-02 | P0 |
| FR-IDT-02 | CAP-IDT-03 | P0 |
| FR-IDT-03 | CAP-IDT-04 | P1 |
| FR-IDT-04 | CAP-IDT-05, CAP-IDT-06 | P1 |
| FR-IDT-05 | CAP-IDT-07, CAP-IDT-08, CAP-IDT-09 | P1/P2 |
| FR-IDT-06 | CAP-IDT-11 | P0 |
| FR-IDT-07 | CAP-IDT-10 | P0 |
| FR-IDT-08 | CAP-IDT-10 | P0 |
| FR-PRV-01 | CAP-PRV-01 | P0 |
| FR-PRV-02 | CAP-PRV-04 | P0 |
| FR-PRV-03 | CAP-PRV-03 | P0 |
| FR-PRV-04 | CAP-PRV-02 | P0 |
| FR-PRV-05 | CAP-PRV-05 | P0 |
| FR-PRV-06 | CAP-PRV-06 | P1 |
| FR-CAT-01 | CAP-CAT-01 | P0 |
| FR-CAT-02 | CAP-CAT-02 | P0 |
| FR-CAT-03 | CAP-CAT-03 | P0 |
| FR-CAT-04 | CAP-CAT-04 | P1 |
| FR-CAT-05 | CAP-CAT-05 | P0 |
| FR-CAT-06 | CAP-CAT-06 | P0 |
| FR-CAT-07 | CAP-CAT-07 | P0 |
| FR-CAT-08 | CAP-CAT-08 | P1 |
| FR-CAT-09 | CAP-CAT-09 | P0 |
| FR-CAT-10 | CAP-CAT-10 | P1 |
| FR-CAT-11 | 新增（支撑 CAP-TGT-03） | P0 |
