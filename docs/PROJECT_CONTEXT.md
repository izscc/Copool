# Copool (icopool) 项目上下文沉淀

> 本文档供 Codex/后续开发接手项目时读取，沉淀了项目背景、架构、关键机制、踩坑记录与待办事项。
> 最后更新：2026-08-04（第三方模型链路已端到端打通，见 §3.6）

---

## 1. 项目是什么

**Copool（App 产物名 `icopool.app`）** 是一个 macOS 菜单栏 App（SwiftUI，Swift 6.0，macOS 14+），核心功能：

- **管理 ChatGPT/Codex 多账号**：导入多个 ChatGPT OAuth 账号，切换账号时原子改写 `~/.codex/auth.json` + `accounts.json` 的 `currentAccountID`，并强杀重启 ChatGPT.app 使新账号生效
- **本地 API 代理**（Swift 原生实现，非 Rust 旧版）：监听 `127.0.0.1:8787`，把 ChatGPT.app 的请求按模型路由——原生模型转发回 chatgpt.com 官方后端（带账号 OAuth token），第三方模型转发到用户配置的 provider
- **账号用量管理**：拉取各账号周配额，评分排序、配额耗尽自动切换账号（failover）、账号卡片显示用量与重置次数
- **第三方模型渠道**：用户可添加 provider（OpenAI-compatible / Anthropic / Google Gemini），模型注入 ChatGPT.app 模型菜单，支持本机订阅导入（Claude/Grok/Cursor/Antigravity 登录态）

**版本**：2.1.0 (28)。仓库 `izscc/Copool`，分支 main。

---

## 2. 架构与关键文件

### 2.1 目录结构（Sources/Copool/）

| 目录/文件 | 职责 |
|---|---|
| `App/AppContainer.swift` | DI 装配中心，所有服务创建与注入 |
| `App/CopoolApp.swift` | App 入口，启动时 sync 第三方模型目录 + watch models_cache |
| `App/RootScene.swift` | 主界面 Tab 切换（accounts/proxy/providers/settings） |
| `App/TrayMenuModel.swift` | 菜单栏模型，用量刷新、账号状态 |
| `Behavior/AccountsCoordinator.swift` | 账号切换编排（核心：切换→写 auth→重启 app） |
| `Behavior/AccountRanking.swift` | 账号评分排序（**周配额单窗口**，5 小时窗口已废弃） |
| `Behavior/ProxyCoordinator.swift` | 代理/Cloudflared/远程服务器命令 |
| `Behavior/ProxyLocalCommandService.swift` | **本地代理按钮命令服务**（之前缺失导致按钮全失效，已补） |
| `Domain/ProviderModels.swift` | ProviderConfig/ProviderStore/ProviderProtocol/用量记账模型 |
| `Domain/AccountsModels.swift` | 账号/用量模型（UsageWindow 含 resetsAvailable） |
| `Domain/Protocols.swift` | 所有服务协议 |
| `Features/Accounts/` | 账号列表页（卡片、用量、第三方用量区块） |
| `Features/Providers/` | 第三方模型管理页（引导/预设/订阅导入/列表/表单） |
| `Features/Settings/` | 设置页 |
| `Infrastructure/SwiftNativeProxyRuntimeService*.swift` | **代理核心**（主文件 + Models/RequestTranslation/ResponseTranslation/ThirdParty/ProviderAdapters/ProviderSSE/RetryFailures 扩展） |
| `Infrastructure/CodexModelsCacheService.swift` | 第三方模型目录写入 models_cache.json + config.toml 的 model_catalog_json |
| `Infrastructure/LocalSubscriptionImporter.swift` | 本机订阅导入（Claude/Grok/Cursor/Antigravity） |
| `Infrastructure/ProviderTokenRefreshService.swift` | 订阅 token 刷新（OAuth refresh） |
| `Infrastructure/ProviderFileRepository.swift` | providers.json / third-party-usage.json 持久化 |
| `Infrastructure/ChatGPTAppService.swift` | 定位/重启 ChatGPT.app |
| `Infrastructure/SimpleHTTPServer.swift` | 轻量 HTTP/1.1 服务器（Network.framework，**不支持 WebSocket**） |
| `Infrastructure/FileSystemPaths.swift` | 所有路径（accounts.json/providers.json/codex 相关） |

### 2.2 数据流

```
ChatGPT.app 请求（带账号 OAuth token）
  → 代理 127.0.0.1:8787（isAuthorized 接受 代理key 或 当前账号 token）
  → 按 model 名路由：
     原生 GPT-5.x → chatgpt.com/backend-api/codex/responses（账号 failover）
     第三方 provider/模型 → provider 直连（独立鉴权头，不触发账号切换）
        ├─ chat      → {baseURL}/chat/completions
        ├─ responses → {baseURL}/responses
        ├─ anthropic → {baseURL}/v1/messages（x-api-key + anthropic-version）
        └─ google    → {baseURL}/models/{model}:generateContent
                       （antigravity/agy 特判 → daily-cloudcode-pa.googleapis.com 内部端点）
  401/403 → 刷新订阅 token（Keychain/~/.grok/auth.json）→ 重试一次
  用量记账：第三方请求 2xx 后按 provider×model 聚合存 third-party-usage.json
```

---

## 3. 第三方模型体系（重点，历尽踩坑）

### 3.1 模型如何出现在 ChatGPT.app 菜单

**机制**（参考 opencodex）：
1. 写 `~/.codex/custom_model_catalog.json`（`{models:[...]}`），并在 `~/.codex/config.toml` 设 `model_catalog_json = "..."` 指向它
2. **同时**把第三方条目 merge 进 `~/.codex/models_cache.json`（Codex 原生缓存，ChatGPT.app 菜单实际读它）
3. icopool 启动时 sync 一次；**watch `models_cache.json`**，被 Codex 覆盖后自动重新注入

**关键坑**：
- **models_cache.json 是 ChatGPT.app 菜单的真实数据源**；custom_model_catalog.json 会被 ChatGPT.app 启动时重写（去掉 provider 字段），所以**第三方条目必须写进 models_cache.json 且带 `provider: "opencodex"`**
- 条目 slug 用**纯后端模型 ID**（如 `gemini-3.6-flash`），**不要带 provider 前缀**（`antigravity/gemini-3.6-flash` 会被 ChatGPT.app 截断成 `agy/...` 导致 "not supported"）
- 条目必须含完整 Codex schema：`shell_type`、`base_instructions`、`experimental_supported_tools`、`truncation_policy`、`supported_reasoning_levels`、`context_window` 等（缺字段会被 Codex 解析拒绝）
- `model_provider: "opencodex"` + config.toml 的 `[model_providers.opencodex]` 块（`requires_openai_auth = true`）让 ChatGPT.app 在 ChatGPT 账号模式下接受第三方模型
- **`openai_base_url` 全局配置会导致原生模型也走代理且触发 WebSocket**——已移除，只靠 model_providers 按模型路由

### 3.2 config.toml 关键配置（当前生效）

```toml
model_catalog_json = "/Users/zscc.in/.codex/custom_model_catalog.json"

[model_providers.opencodex]
name = "Copool"
base_url = "http://127.0.0.1:8787/v1"
wire_api = "responses"
requires_openai_auth = true
supports_websockets = false
request_max_retries = 3
stream_max_retries = 3
stream_idle_timeout_ms = 600000
```

**注意**：`model_providers` 段必须放在文件**顶部**（全局区），不能落在 `[agents]` 段之后（虽 TOML 合法但 Codex 解析行为不同）。`[features]` 段里加过 `responses_websockets = false`（不确定是否必需，保留无害）。

### 3.3 WebSocket 问题（Codex 0.146）

- Codex 对 `openai_base_url`/model_provider 指向本地时**默认尝试 WebSocket**（`ws://127.0.0.1:8787/v1/responses`）
- SimpleHTTPServer 不支持 WS，代理对 Upgrade 请求返回 **426**（opencodex 同款），并带 `Connection: close` + `Sec-WebSocket-Version: 13`
- **但实测 Codex 0.146 收到 426 后不自动回退 HTTP**（报 `invalid_request_error` 解析失败）
- 实际生效的解决：**移除 `openai_base_url`**（避免全局 WS）+ provider 配置 `supports_websockets = false` + 纯 ID 条目——CLI 不再试 WS，直接走 HTTP
- 遗留：ChatGPT.app 桌面端请求是否走代理仍待最终验证（见待办）

### 3.4 订阅导入与 token 刷新

**导入器**（LocalSubscriptionImporter）读取本机登录态：
- **Grok**：`~/.grok/auth.json`（key/token/refresh_token + oidc_issuer/client_id）
- **Claude**：`~/.claude/.credentials.json`（Claude Code OAuth）+ `~/.claude.json` API key + Claude Desktop config.json 明文 tokenCache（加密缓存解密未实现）
- **Cursor**：`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`（sqlite）
- **Antigravity**：macOS Keychain（`security find-generic-password -a antigravity -s gemini -w`，`go-keyring-base64:` 前缀 JSON）

**刷新**（ProviderTokenRefreshService，401/403 时自动）：
- **Antigravity**：Keychain 是 refresh_token 权威来源（providers.json 里可能只有过期 access_token）；OAuth client id/secret 从 `/Applications/Antigravity.app/Contents/Resources/bin/language_server` 二进制用正则提取；**必须穷举所有 client×secret 组合**（实测 client2+secret1 才有效，取第一个会失败）；刷新端点 `https://oauth2.googleapis.com/token`
- **Grok**：refresh_token 从 `~/.grok/auth.json` 读（issuer `https://auth.x.ai`），端点 `{issuer}/oauth2/token`
- **Claude**：provider.refreshToken → `platform.claude.com/v1/oauth/token`（client_id `9d1c250a-e61b-44d9-88ed-5944d1962f5e`）
- **Cursor**：provider.refreshToken → `api2.cursor.sh/oauth/token`

**Antigravity 请求端点特殊**：它的 OAuth token scope **只覆盖内部 CloudCode 端点**，公开 `generativelanguage.googleapis.com` 会 403 insufficient scopes。必须路由到 `https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse`（body 包 `{project:"default-cli-project", model, request: geminiPayload}`，User-Agent `antigravity/hub/2.2.1 darwin/arm64`）。

**已实测验证**：
- antigravity token 刷新成功（Keychain 读取 + client2/secret1 组合）→ 请求到内部端点 → **429 quota exhausted**（账号配额问题，非代码问题）
- grok token 刷新成功（auth.json）→ 请求到 api.x.ai → **402 spending-limit**（账号余额问题，非代码问题）

### 3.5 当前 providers.json 状态

```
antigravity | https://generativelanguage.googleapis.com/v1beta | google | authKind: apiKey
grok        | https://api.x.ai/v1                            | chat   | authKind: apiKey
```

注意：这俩 authKind 是 `apiKey` 且无 refreshToken（用户手动添加的），但刷新逻辑对 antigravity/grok **按名字特判**（不依赖 authKind/refreshToken），所以仍能刷新。

---

## 3.6 第三方模型链路修复（2026-08-04，已端到端验证）

此前"模型出现在菜单但一选就报 `The 'gemini-3.6-flash' model is not supported when using Codex with a ChatGPT account`"的问题，实际是**六个独立缺陷叠加**。以下全部已修复并用真实 Codex 验证通过。

### 3.6.1 根因一：Codex 没有"按模型选 provider"的机制

**关键事实**（从 `/Applications/ChatGPT.app/Contents/Resources/codex` 二进制 strings 反推）：

- Codex 的 `ModelInfo`（38 字段：`display_name`/`shell_type`/`context_window`/…）**根本没有 provider 字段**。我们写进 catalog 条目的 `provider` / `model_provider` / `backend_provider` **全部被忽略**。
- ChatGPT.app 在 `thread/start` 里**硬编码 `modelProvider: null`**（app.asar 可见），所以 provider 只能由 config.toml 的**全局 `model_provider`** 决定，默认 `openai` → 请求直奔 chatgpt.com → 后端拒绝未知模型。
- 那句报错**不在 ChatGPT.app 里**（全盘 grep 无果），是 OpenAI 后端返回的 —— 这就是"请求根本没走代理"的铁证。

**解法**：Copool 在代理**健康后**往 `~/.codex/config.toml` 写入受管块（`CodexModelsCacheService.applyProxyRouting(port:)`），代理停止时摘除（`removeProxyRouting()`）：

```toml
# >>> copool managed >>>
model_provider = "opencodex"
# <<< copool managed <<<
… 用户原有内容 …
# >>> copool managed provider >>>
[model_providers.opencodex]
name = "Copool"
base_url = "http://127.0.0.1:<实际端口>/v1"
wire_api = "responses"
requires_openai_auth = true
supports_websockets = false
…
# <<< copool managed provider <<<
```

**排版约束**：标量键必须在文件顶部（全局区），`[model_providers.opencodex]` 表必须在**末尾**——若把表放前面，用户原有的顶层键（`notify` / `service_tier` …）会被吞进该表。

**为什么不用 opencodex 的 `openai_base_url`**：实测它会让 Codex 尝试 `ws://127.0.0.1:<port>/v1/responses`，426 后重试 5 次才回退 HTTP，**每轮多花约 8 秒**。改用 `model_provider` + 该 provider 的 `supports_websockets = false` 后，**零 WebSocket 尝试**，直接走 HTTP。

**代价**：`model_provider` 是全局的，原生模型也会经代理（代理本就负责原生转发 + 账号 failover，符合设计）。因此 icopool 未运行时 ChatGPT.app 不可用；**被强杀（非优雅退出）会残留受管块**，重启 icopool 即恢复。

### 3.6.2 根因二：Antigravity 的 429 其实是 User-Agent 问题（最迷惑的一个）

`daily-cloudcode-pa.googleapis.com` **按 User-Agent 鉴别客户端**：UA 不是 `antigravity/hub/2.2.1 darwin/arm64` 时，一律返回

```
429 "Resource has been exhausted (e.g. check quota)."
```

`makeThirdPartyRequest` 在 google 分支设好了正确 UA，**结尾又用下游客户端的 UA 无条件覆盖**，于是永远 429。这正是 §8.5.4 里"用户说有 99% 额度却 429"的答案 —— 额度一直是满的。

已修：分支设置的 provider 专用 UA 不再被覆盖（同时给 grok 补上 `grok-cli/1.89.0`）。

验证：`fetchAvailableModels` 显示所有模型 `remainingFraction: 1`。

### 3.6.3 根因三：Antigravity 模型 ID 是猜的

该端点上**不存在 `gemini-3.6-flash`**，只有 `gemini-3.6-flash-low/medium/high/tiered`；`gemini-3-pro` 也不存在。**未知模型同样返回 429**（而非 404），极具误导性。

已修：`LocalSubscriptionImporter` 改为调用
`POST https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`（body `{"project":"default-cli-project"}`）拉取真实列表，只保留有 `displayName` 的条目（无 displayName 的是 `tab_*` / `chat_*` 内部模型）。`detectAll()` 因此改为 `async`。

**注意**：即便在列表里也未必可用 —— 实测 `gemini-3.1-pro-high` 直连也报 `400 INVALID_ARGUMENT`（订阅层级不含），`gemini-3.1-pro-low` / `gemini-pro-agent` 正常。

### 3.6.4 根因四：请求/响应协议方向反了

Codex **只说 Responses API**（`wire_api` 仅支持 `responses`），但：

- **请求**：chat / anthropic / google 三个适配器都读 `messages`，而收到的是 `{instructions, input:[…]}` → 上游报 `Messages cannot be empty`。
  已补 `convertResponsesRequestToChat()`：`instructions`→system、`function_call`→`tool_calls`、`function_call_output`→`role:"tool"`、`reasoning` 丢弃、tools 转 `{type:"function",function:{…}}`。
- **响应**：适配器产出的是 `chat.completion.chunk`，Codex 无法解析 → idle timeout。
  已补 `SwiftNativeProxyRuntimeService+ChatToResponses.swift`：发出 `response.created` / `output_item.added` / `content_part.added` / `output_text.delta` / `output_text.done` / `output_item.done` / `response.completed`（含 usage）。
  **`output_item.added` 不可省**，否则 Codex 报 `OutputTextDelta without active item`。

### 3.6.5 根因五：`.chat` 分支解码器用错 + 每行重建

`consumeChatCompletionsSSEStreamChunk` 是 **Responses→chat** 方向的，却被用来解析 chat provider 的上游 chat SSE；且解码器在**每行**重建，跨行状态全丢 —— 所以 chat 协议 provider（grok）从来没工作过。

已修：新增 `consumeUpstreamChatSSEChunk()` 直读上游 chat chunk 并改写 model 为客户端请求的 ID；解码器改为整条流复用一个实例。

### 3.6.6 根因六：Gemini 3.x 的 thoughtSignature

Antigravity 内部端点把载荷**嵌在 `response` 键下**（公开 API 在顶层）——已在 `translateGeminiSSEChunk` / `convertGeminiResponseToChatCompletion` 里解包。

且 Gemini 3.x **要求后续轮次回传它签发的 `thoughtSignature`**，否则报
`Function call is missing a thought_signature in functionCall parts`。该签名无法穿过 Codex 的 Responses item 往返，因此代理内维护 `geminiThoughtSignatures[callID]`（上限 500 条），回程时挂回 functionCall part；缺失时回退到 opencodex 的 `defaultGeminiThoughtSignature`。

### 3.6.7 其他

- 流式路径**原本没有 401/403 刷新重试**（只有非流式有）。Codex 永远流式，所以刷新逻辑在真实流量里从未触发过。已补。
- 426 响应的 reason phrase 是 `HTTP`、且 `Connection: close` 重复。已修。
- `wantsStream`：Responses 客户端强制走流式（非流式分支会返回它读不懂的 `chat.completion` 对象）。

### 3.6.8 验证结果（真实 `codex exec`，非 mock）

| 模型 | 结果 |
|---|---|
| `gemini-3.6-flash-medium` | ✅ PONG；✅ 多轮工具调用（`cat a.txt` → hello → 总结） |
| `gemini-3.1-pro-low` / `gemini-pro-agent` | ✅ PONG |
| `claude-sonnet-4-6`（经 antigravity） | ✅ PONG（后续偶发上游 `503 No capacity`） |
| `grok-4-fast` | ❌ 403 —— `~/.grok/auth.json` 的 refresh_token **已被吊销**（`invalid_grant: Refresh token has been revoked`），需重新登录 grok CLI；代码侧刷新请求与 CLI 一致 |

### 3.6.9 排障必读：`HTTP_PROXY` 会伪装成代理故障

若 shell 里设了 `HTTP_PROXY=http://127.0.0.1:7890`，**Codex 会遵循它**，于是发往 `127.0.0.1:8787` 的请求被系统代理接管并返回
`502 Bad Gateway: Unknown error, url: http://127.0.0.1:8787/v1/responses`
—— 看起来完全像 Copool 代理挂了。排查时务必：

```bash
env -u HTTP_PROXY -u HTTPS_PROXY no_proxy="127.0.0.1,localhost" codex exec …
```

---

## 4. 账号体系与用量

### 4.1 账号切换流程

1. 用户点账号卡片 → `AccountsCoordinator.switchAccountAndApplySettings`
2. `CurrentAccountProjectionWriter.apply`：原子写 `accounts.json`（currentAccountID）+ `~/.codex/auth.json`（该账号 authJSON）
3. 副作用：opencode auth 同步（可选）、编辑器重启（可选）、`ChatGPTAppService.launchApp()`（强杀 + `open -na` 重启 ChatGPT.app，默认开启）
4. `launchApp()` 前会 sync 第三方模型目录（注入时机）

### 4.2 用量与 failover

- **周配额单窗口**：`AccountRanking` 只按 `oneWeek.usedPercent` 评分（5 小时窗口已废弃，字段保留兼容旧数据）
- `UsageWindow` 含 `resetsAvailable`/`resetsAvailableAt`（banked resets，从 usage API 宽容解析 `resets_available`/`banked_resets`/`num_resets` 等键）
- 账号卡片显示：周配额进度 + 重置次数徽章 + **重置时间（月日时分格式，`MMMdHm`）**
- 代理 failover：当前账号 429/配额耗尽 → 按剩余配额评分自动切下一账号；成功候选自动设为当前账号（`recordSuccessfulCandidate`）

### 4.3 用量面板

- 账号列表页有「第三方模型用量」区块（provider/model、请求数、tokens、最近使用），数据来自 `third-party-usage.json`
- 第三方用量**不计入**账号用量

---

## 5. 代理实现细节（SwiftNativeProxyRuntimeService）

- actor 实现，Network.framework 起 SimpleHTTPServer，默认 8787，**端口被占用时自动尝试 8788-8797**
- API key 持久化 `~/.codex-tools-proxyd/api-proxy.key`
- 鉴权：`x-api-key` = 代理 key **或** `Authorization: Bearer` = 代理 key **或当前 ChatGPT 账号 access_token**（关键：ChatGPT.app 带的是 OAuth token）
- 请求翻译：
  - `/v1/responses`：normalizeResponsesRequest（强制 stream/store=false，strip 不支持键）
  - `/v1/chat/completions`：convertChatRequestToResponses
  - Anthropic：chat→`/v1/messages`（system 提取、tool_use/tool_result、图片块、x-api-key）
  - Google：chat→Gemini contents/functionDeclarations
- 响应翻译：Anthropic/Gemini SSE → OpenAI chunk 形状；非流式 → chat.completion
- 流式记账：Anthropic message_delta usage / Gemini usageMetadata → token 计数

---

## 6. 踩坑记录（重要，避免重蹈覆辙）

1. **config.toml 相对路径会让 ChatGPT.app 配置加载失败**：`model_instructions_file = "./instruction.md"`、`[agents.xxx] config_file = "./agents/..."` 必须绝对路径，否则报 `AbsolutePathBuf deserialized without a base path`，模型列表全挂
2. **`chatgpt_base_url` 不能追加到文件末尾**（会落进 `[agents]` 段报 `expected struct AgentRoleToml`）——要么放顶部要么不用（桌面版根本不读它，用 `openai_base_url`/model_providers）
3. **`wire_api = "chat"` 在新版 Codex 已不支持**（`no longer supported`），只能用 `responses`
4. **Swift 读 Mach-O 二进制提取字符串**必须用 `String(decoding:as:UTF8.self)`（lossy），`String(data:encoding:)` 对二进制返回 nil
5. **security 命令输出末尾有换行**，base64 解码前要 trim
6. **models_cache.json 被 Codex 定期覆盖**：必须 watch 并在覆盖后重新注入；第三方条目要写进它（不是只写 custom catalog）
7. **provider 名必须规范**：`agy`（ChatGPT.app 截断产物）会导致 backend_provider 不匹配，改成 `antigravity`
8. **测试环境无 Xcode**（只有 CommandLineTools）：`swift build` 可用，`xcodebuild`/XCTest 不可用；测试文件改动只能静态核对
9. **icopool 手动启动**：`open /Applications/icopool.app` 偶尔失败（launchd 冲突），直接跑二进制更可靠：`/Applications/icopool.app/Contents/MacOS/icopool &`
10. **构建 App**：`swift build -c release` → 组装 dist/icopool.app（cp 二进制 + bundle + Info.plist 修正）→ 冒烟测试（启动存活 + curl health）

---

## 7. 当前状态与待办

### 已完成
- ✅ 第三方模型出现在 ChatGPT.app 菜单（11 个模型：7 官方 + 4 第三方）
- ✅ 账号切换启动 ChatGPT.app（com.openai.codex + 可执行 ChatGPT 识别）
- ✅ 周配额单窗口、重置次数展示、月日时分重置时间
- ✅ 本地代理（HTTP/1.1）+ 端口回退 + 账号 token 鉴权
- ✅ 第三方协议适配（chat/responses/anthropic/google）
- ✅ 订阅导入（Grok/Claude/Cursor/Antigravity）+ 401/403 token 刷新
- ✅ Antigravity 内部端点路由（解决 403 scope 问题）
- ✅ 独立 Providers Tab（引导/预设/导入/列表/测试）
- ✅ 第三方用量独立记账 + 面板
- ✅ config.toml 修复（相对路径、model_providers 配置）

### 待办/未验证
- [x] ~~第三方模型 "not supported" 报错~~ **已修复并端到端验证**，见 §3.6
- [ ] **ChatGPT.app 桌面端 GUI 实操验证**（CLI `codex exec` 已全绿；桌面端走同一 app-server + config.toml，预期一致，但未由人工点选确认）
- [ ] grok 需用户重新登录 grok CLI（refresh_token 已被吊销），之后才能验证 chat 协议在真实 provider 上的表现
- [ ] Claude Desktop 加密缓存解密（safeStorage AES-CBC）未实现（当前只支持明文凭证路径）
- [ ] Antigravity OAuth client 选择未用 opencodex 的上下文打分（用穷举替代，可用但多几次请求）
- [ ] icopool 被**强杀**时 config.toml 的受管块会残留，导致 ChatGPT.app 指向已关闭的端口（重启 icopool 即恢复）；优雅退出/启动失败已会自动摘除
- [ ] `~/Library/Application Support/CodexToolsSwift/auth-flow-debug.log` 实测已涨到 **1.09 GB**，需要加轮转或关闭
- [ ] providers.json 解码失败时整个文件会消失（曾因手工插入的条目 `models` 用字符串而非 `{"id":…}` 触发）——应改为保留原文件并报错
- [ ] 第三方 provider 间 failover 未实现（失败即报错）
- [ ] 正式签名/公证需 Xcode 环境（`scripts/release_macos.sh`），本机只有 CommandLineTools
- [ ] `ProxyPageModel` 的 `localProxyCommandService` 已实现注入（之前按钮全失效的 bug 已修），但远程服务器命令未接（throw 占位）
- [ ] dist/icopool.app 未提交（gitignore），每次发版手动组装

### 潜在改进方向
- 按 opencodex 方式实现 provider 模型**测试**（逐个模型发最小请求验证）
- 第三方模型用量面板增强（趋势图/按日聚合）
- WebSocket 支持（如果 Codex 新版强制 WS）——或跟进 opencodex 的 426 回退在新版的行为
- Claude Desktop 加密 OAuth 缓存解密（参考 opencodex subscription_auth.ts 的 v10 AES-CBC + Keychain）

---

## 8. 参考项目

- **opencodex**（github.com/AITabby/opencodex）：第三方模型接入 ChatGPT.app/Codex Desktop 的权威参考
  - `src_v2/services/catalog_sync.ts`：模型目录机制（写 models_cache.json、buildFullCatalogEntry 完整 schema、getOfficialModels 用 `codex debug models`）
  - `src_v2/services/subscription_auth.ts`：本机订阅读取（Grok auth.json、Antigravity Keychain + 二进制提 client、Claude Desktop 加密缓存、Cursor state.vscdb）
  - `src_v2/server/gateway.ts`：`buildManagedCodexConfig`（model_providers 配置块、openai_base_url、426 WS 回退）、Antigravity 内部端点路由、401/403 刷新重试
  - `src_v2/adapters/`：Anthropic/Google/OpenAI 协议适配器
- **orca**（github.com/stablyai/orca）：账号用量/重置次数展示参考（banked resets）

---

## 8.5 关键决策与排障记录（对话过程沉淀）

> 本节约是按时间顺序的对话决策与排障结论，帮助 Codex 理解"为什么这么做"而非只看现状。

### 8.5.1 需求演进（用户原始诉求 → 最终方案）

1. **最初**：切换 codex 账号默认启动 ChatGPT.app（而非 codex.app），因为两者已合并
2. **扩展**：永久支持第三方渠道模型（借鉴 opencodex），在 ChatGPT.app 中能选第三方模型，切换账号不丢用量
3. **再扩展**：所有 codex 账号能无缝承接用量（全自动 failover）；用量统计面板；codex 取消 5 小时限制只剩周限制
4. **最终**：多协议（chat/responses/anthropic/google）+ 授权登录导入（Grok/Claude/Cursor/Antigravity）+ 独立模型管理页 + 账号重置次数展示

**关键决策点**：
- 用户拍板：failover 全自动；第三方消耗**不计入账号用量**、单独记账；用量面板集成进账号列表页
- 用 goal 流程（dbs-goal）审计目标到可检查交付物

### 8.5.2 关键排障结论（按发现顺序）

1. **代理按钮全失效** → 根因 `ProxyLocalCommandService` 协议从未注入实现（AppContainer 缺失），已补
2. **代理无法启动** → 8787 被 `openai-anthropic-adapter`（用户自己的 launchd 常驻服务）占用；处理：用户同意停用该服务（bootout + plist 移到 .disabled），并给代理加端口回退 8788-8797
3. **第三方模型看不到** → 三原因叠加：
   - 注入写错文件（models_cache.json 会被 Codex 覆盖，需 watch 重新注入）
   - 缺启动注入时机（只在切换账号时注入）
   - 代理拒绝 ChatGPT.app 的 OAuth token（只认自己 key）→ 改为接受当前账号 token
4. **官方模型丢失** → `model_catalog_json` 指向 custom catalog 后，菜单只显示 catalog 里的模型；必须把官方模型（从 models_cache 读）也合并进 catalog（opencodex 同款）
5. **"The 'agy/gemini-3.6-flash' model is not supported"** → slug 带 provider 前缀（`antigravity/...`）被 ChatGPT.app 截断成 `agy/...` 后拒绝；改为**纯后端 ID slug + provider: "opencodex"**
6. **ChatGPT.app 配置加载失败**（`AbsolutePathBuf deserialized without a base path`）→ config.toml 里 `model_instructions_file`/`[agents] config_file` 是相对路径；改绝对路径
7. **`chatgpt_base_url` 追加到文件末尾报 `expected struct AgentRoleToml`** → 落进了 `[agents]` 段；且实测桌面版不读该键，改用 `openai_base_url`/`model_providers`
8. **antigravity 401/403** → token 过期；Keychain 是 refresh_token 权威来源；OAuth client 必须穷举组合（client2+secret1 才有效）；且 **Antigravity token scope 不含公开 Gemini API**，必须走内部 CloudCode 端点 `daily-cloudcode-pa.googleapis.com/v1internal`
9. **grok 403** → token 过期；refresh_token 在 `~/.grok/auth.json`
10. **Codex 0.146 WebSocket 问题** → 对本地 base_url 默认试 WS；426 后**不回退 HTTP**（报 invalid_request_error）；解法：移除 `openai_base_url` 全局配置 + provider `supports_websockets = false` + catalog 条目同字段
11. **`wire_api = "chat"` 报 no longer supported** → 新版 Codex 只支持 responses
12. **Swift 读二进制字符串** → `String(data:encoding:)` 对 Mach-O 返回 nil，必须 `String(decoding:as:)` lossy

### 8.5.3 验证结论（哪些实测通过）

- ✅ `codex debug models` 识别 11 个模型（7 官方 + 4 第三方）
- ✅ 代理 `/v1/models` 返回 49 个（含 4 第三方纯 ID）
- ✅ 代理接受当前账号 OAuth token（HTTP 200）
- ✅ antigravity token 刷新成功 → 内部端点 → **429 quota exhausted**（账号配额问题）
- ✅ grok token 刷新成功 → api.x.ai → **402 spending-limit**（账号余额问题）
- ✅ config.toml 0 配置错误、ChatGPT.app 正常加载
- ❓ **ChatGPT.app 桌面端最终选择第三方模型**：机制已按 opencodex 配齐，但用户最后反馈仍见 "not supported"，且 CLI 请求未确认到达代理——**这是接手后第一优先验证项**

### 8.5.4 未竟事项的线索（给接手者的提示）

- ~~用户称 antigravity 有 99% 额度但请求返回 429~~ **已破案**：额度确实是满的，429 是 User-Agent 被覆盖 + 模型 ID 不存在共同导致的误导性错误，见 §3.6.2 / §3.6.3
- ChatGPT.app 前端对 `model_provider: "opencodex"` 的校验逻辑未完全定位（app.asar 压缩 JS 难读）——若重测仍失败，优先查：模型是否在 ChatGPT.app 的 `model/list` 响应里带 `model_provider` 字段、前端是否要求特定 provider 名
- CLI 测试用 `codex exec` 行为与桌面端不同（可能走系统代理挂起），桌面端验证应以 ChatGPT.app 实际操作 + 代理连接日志为准

---

## 9. 常用操作

```bash
# 构建 release
swift build -c release

# 组装 dist/icopool.app（版本 2.1.0 (28)）
STAGE=/tmp/icopool-app-stage && rm -rf "$STAGE" dist && mkdir -p "$STAGE/icopool.app/Contents/MacOS" "$STAGE/icopool.app/Contents/Resources" dist
cp .build/release/Copool "$STAGE/icopool.app/Contents/MacOS/icopool"
cp -R .build/release/Copool_Copool.bundle/* "$STAGE/icopool.app/Contents/Resources/"
cp Sources/Copool/Info-macOS.plist "$STAGE/icopool.app/Contents/Info.plist"
plutil -replace CFBundleExecutable -string icopool "$STAGE/icopool.app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "com.alick.copool" "$STAGE/icopool.app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "2.1.0" "$STAGE/icopool.app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "28" "$STAGE/icopool.app/Contents/Info.plist"
cp -R "$STAGE/icopool.app" dist/ && rm -rf /Applications/icopool.app && cp -R dist/icopool.app /Applications/icopool.app

# 启动（直接跑二进制更可靠）
/Applications/icopool.app/Contents/MacOS/icopool &

# 验证代理
curl -fsS http://127.0.0.1:8787/health
# 验证模型列表（带账号 token 或代理 key）
curl -fsS -H "x-api-key: $(cat ~/.codex-tools-proxyd/api-proxy.key)" http://127.0.0.1:8787/v1/models

# 验证 Codex 识别模型
/Applications/ChatGPT.app/Contents/Resources/codex debug models

# 重启 ChatGPT.app
pkill -f '/Applications/ChatGPT.app/Contents/MacOS/ChatGPT'; sleep 2; open /Applications/ChatGPT.app
```

**常用路径**：
- `~/.codex/config.toml` — Codex 配置（model_catalog_json、model_providers、agents 等）
- `~/.codex/models_cache.json` — 模型缓存（ChatGPT.app 菜单源，会被 Codex 覆盖）
- `~/.codex/custom_model_catalog.json` — 我们的模型目录（含官方+第三方）
- `~/Library/Application Support/CodexToolsSwift/` — accounts.json / providers.json / third-party-usage.json / settings.json
- `~/.codex-tools-proxyd/api-proxy.key` — 代理 API key
- `~/Library/Logs/com.openai.codex/` — ChatGPT.app 日志（排查配置错误）
