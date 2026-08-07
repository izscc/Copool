# 03 · 功能需求：目标应用、路由引擎、协议适配与运行时

> 覆盖能力矩阵 C 组（CAP-TGT-\* / CAP-RTE-\* / CAP-PRO-\*）与 D 组（CAP-RUN-\* / CAP-OPS-\*）。
> 本章是整个系统的**执行路径**：模型目录（02 章）如何真正被目标应用用起来。

---

## 3.1 数据流全景

```
用户在 Copool 启用模型
        ↓
构建目标可见目录（FR-CAT-01 凭据感知过滤）
        ↓
生成目标配置 diff（FR-TGT-03）→ 用户预览 → 用户确认
        ↓
写入托管块 + 备份（FR-TGT-04）→ 校验（FR-TGT-05）
        ↓
提示用户重启目标应用（FR-TGT-08，Copool 不代劳）
        ↓
━━━━━━━━━━━━ 以下为运行时 ━━━━━━━━━━━━
目标应用发请求 → 127.0.0.1:port
        ↓
caller capability 校验（FR-RUN-02）
        ↓
入站协议识别 + 解压（FR-PRO-06）
        ↓
V2RouteResolver：硬过滤 → 打分 → 选中（FR-RTE-02）+ 写 trace
        ↓
应用 request profile（FR-PRO-07）
        ↓
出站协议转换（FR-PRO-01..04）→ 上游
        ↓
SSE 流式回传 + 限流头解析（FR-RUN-07）+ 用量记账（FR-RUN-08）
        ↓
失败 → 分类 → 重试/转移（FR-RTE-04）
```

---

## 3.2 目标应用绑定（FR-TGT-\*）

### 3.2.1 适配器契约

**FR-TGT-01 · 六方法契约**（CAP-TGT-04，P0）

所有目标适配器实现同一协议（已部分落地为 `TargetConfigManaging`）：

| 方法 | 语义 | 必须满足 |
| --- | --- | --- |
| `detect()` | 探测目标是否安装、配置在哪、当前内容 | 无副作用；目标未安装返回 `nil` 而非抛错 |
| `plan(to:)` | 生成 diff，**不写盘** | 幂等；可重复调用 |
| `apply(_:)` | 备份 → 原子写入 | 先备份后写；写失败必须保持原文件完好 |
| `verify(_:)` | 回读校验 | 校验托管块内容，**不比较全文** |
| `rollback(_:)` | 从备份还原 | 无备份时明确报错，不静默成功 |
| `uninstall()` | 剥离托管块，保留用户内容 | 剥离后文件必须仍是合法配置 |

**已知缺陷（必须在 M1 修复）**：`Sources/Copool/Infrastructure/TargetConfigFileAdapter.swift:43-52` 的 `plan(to:)` 在持有 `lock` 的情况下调用了两次 `detect()`，而 `detect()` 自身也会 `lock.lock()`。`NSLock` 不可重入——**这会死锁**。修复方式：拆出不加锁的私有 `detectLocked()`，由 `detect()` 与 `plan(to:)` 分别在自己的临界区内调用。

**已知缺陷 2**：同文件 `verify(_:)` 用 `current == diff.after.content` 做全文相等比较。目标应用自身或用户在两次操作间修改了托管块之外的内容，就会误判为失败。修复方式：只比较托管块区间。

---

**FR-TGT-02 · 托管块，绝不覆盖用户配置**（CAP-TGT-02，**P0，数据安全红线**）

沿用 P1 已实现的标记格式（`TargetConfigFileAdapter.stripMarkedBlocks`）：

```
# >>> copool-managed-provider >>>
   ...Copool 生成的内容...
# <<< copool-managed-provider <<<
```

规则：

1. 写入前先 `stripMarkedBlocks` 剥离旧托管块，再追加新块——托管块之外的每一个字节原样保留。
2. 起止标记不成对（用户手工编辑破坏了标记）→ **中止操作**并报告，不猜测边界。
3. 同名托管块出现多次 → 全部剥离后写入一个（现有 `while let` 循环已具备此行为）。
4. 备份写入目标的独立状态目录（`stateDirectory/config-backup`，AC-008），**不写在用户配置旁边**，避免污染目标应用的配置目录。

- 验收：构造一份含大量用户自定义内容的 `config.toml`，apply → uninstall，断言文件内容与初始**逐字节相等**。

---

**FR-TGT-03 · 目录合并进目标原生选择器**（CAP-TGT-03，P0）

Codex 走 `~/.codex/models_cache.json` 注入（已有 `ChatGPTAppService.syncThirdPartyModels` 与 `AppContainer.startModelsCacheWatch()`，500ms 去抖）。

- 注入的模型条目必须携带 02 章确定的元数据：`displayName`、`contextWindow`、`reasoningEfforts`、`inputModalities`。
- **原生 GPT 模型条目必须原样保留**——注入是"追加托管区"，不是"替换列表"。
- 目标应用自身覆写了 `models_cache.json`（升级、重新登录等）→ 监听器检测到托管块消失，自动重新注入；重新注入需去抖并限速（每分钟至多 1 次），避免与目标应用写文件互相打架形成循环。

---

**FR-TGT-04 · 应用前 diff 预览**（CAP-TGT-05，P0）

写入任何目标配置前，必须展示 diff sheet：

- 分三段显示：**将新增**（绿）、**将移除**（红）、**保持不变的用户内容行数**（灰，只给计数不展开）。
- 明确标注目标文件绝对路径与备份路径。
- 用户点"应用"才写盘。**不提供**"以后不再预览"。

---

**FR-TGT-05 · 备份、校验与一键回滚**（CAP-TGT-06，P0）

- 每次 `apply` 前必备份，备份带时间戳，**保留最近 5 份**，超出的按时间淘汰。
- `apply` 后立即 `verify`；校验失败**自动回滚**并报错，不留下半应用状态。
- 目标页常驻"回滚到上一次"按钮，展示每份备份的时间与摘要。
- `TargetBinding.configFingerprint`（已有字段）记录成功应用后的内容指纹；下次操作前比对，指纹不符说明文件被外部改动过，需提示用户确认。

---

**FR-TGT-06 · 每目标独立状态、端口与凭据**（CAP-TGT-07，P0，AC-008）

已由 `TargetBinding` 承载（`stateDirectoryPath`、`callerCapability`、`internalCapability`、`listenerHost`）。本次只需保证：

- 三个目标（codex / cursor / opencode）的监听端口互不冲突，端口分配见 FR-RUN-03。
- 每个目标的 `enabledProviderInstanceIDs` 独立——用户可以只给 Cursor 开 DeepSeek，不影响 Codex。

---

**FR-TGT-07 · Cursor 与 opencode 转正**（CAP-TGT-08/09，P1）

`TargetBindingStore.defaults` 中两者当前为 disabled beta。转正条件：六方法契约全部实现 + 通过 FR-TGT-02 的逐字节验收 + Doctor 有对应检查项。未达标前保持 beta 标记且默认关闭。

---

**FR-TGT-08 · 不静默重启目标应用**（CAP-TGT-10，P0，**安全红线**）

Copool **绝不**结束、重启、或以任何方式干预目标应用进程。

配置应用成功后显示明确提示：「配置已写入。请手动退出并重新启动 <目标应用> 使其生效。」并给出"如何确认生效"的一句话说明。

理由：目标应用可能持有未保存的用户工作；进程生命周期是用户的决定权。

---

**FR-TGT-09 · 免 OpenAI 登录模式**（CAP-TGT-11，P2）

允许用户在完全不登录 ChatGPT 的情况下把原生模型名映射到第三方模型（native-alias 语义）。属 P2，首版不实现，但**数据结构须预留**：`ModelCatalogEntry.aliases` 已可承载映射关系，无需新增字段。

---

## 3.3 路由引擎（FR-RTE-\*）

**FR-RTE-01 · 三层路由**（CAP-RTE-01/02/03，P0）

| 层 | 输入 | 决策 | 实现 |
| --- | --- | --- | --- |
| 目标路由 | caller capability token | 定位 `TargetBinding` | 已有 |
| 模型路由 | 请求的 model 字符串 | 定位 `ProviderInstance` + `ModelCatalogEntry` | `V2RouteResolver`（已有） |
| 账号路由 | 选中的 instance | 从凭据池选具体账号 | `AccountRanking`（已有） |

---

**FR-RTE-02 · 模型解析优先级**（CAP-RTE-02，P0）

`V2RouteResolver.resolve` 已实现的匹配顺序，本次**固化为契约**：

```
① 精确匹配 ModelCatalogEntry.id（"providerInstanceID/backendModelID"）
② 别名匹配 aliases 包含请求值
③ 后端模型 ID 匹配（可能多条 → 交给打分器）
④ 全部落空 → 全目录参与打分（兜底）
```

**要改的一点**：第 ④ 步"全目录兜底"在 23 家 provider 场景下过于危险——用户手误输入一个不存在的模型名，会被静默路由到某个随便打分选出的模型，产生真实费用且结果莫名其妙。

**修正**：④ 改为**返回 nil 并记录 trace**，由调用方回落 v1 匹配；v1 也匹配不上则返回 404 + 明确错误体「未知模型 `<name>`，请检查目标应用的模型选择」。`RouteDecisionTrace` 必须记录这次失败（现有代码已做到"失败也写 trace"，保持）。

---

**FR-RTE-03 · 凭据门禁**（P0）

`V2RouteResolver` 已把 `credentials` 映射为 `[id: Bool]`（只传"是否存在引用"，**规划器永远看不到秘密值**）。此设计保持不变，并在本次扩展为三态：`就绪` / `未就绪` / `限流中`。限流中的凭据参与打分但权重降低，不做硬排除——否则短时限流会导致整个 provider 不可用。

---

**FR-RTE-04 · 失败分类与转移**（CAP-RTE-04，P0）

上游失败必须先分类，再决定动作。**禁止无差别重试**：

| 类别 | 判据 | 动作 | 是否换账号 |
| --- | --- | --- | --- |
| 网络/超时 | 连接失败、读超时 | 重试同账号，最多 2 次，指数退避 | 否 |
| 限流 429 | HTTP 429 或限流响应体 | 换同 provider 的其他凭据；无其他凭据则按 `FallbackPolicy` 转移 | 是 |
| 鉴权 401 | HTTP 401 | **不重试**，标记凭据 `无权限`，立即返回 | 否 |
| 权限 403 | HTTP 403 | 区分配额型与禁止型：配额型按限流处理，禁止型不重试 | 视情况 |
| 请求错误 4xx | 400/404/422 | **不重试**，原样透传上游错误体 | 否 |
| 上游 5xx | 500/502/503 | 重试 1 次，仍失败则按 `FallbackPolicy` 转移 | 是 |
| 流中断 | SSE 已开始后断开 | **不重试**（已产生费用且客户端已收到部分内容），发送 error 事件收尾 | 否 |

`FallbackPolicy` 已有 `strategy: .sameProvider, maxAttempts: 3`，保持默认值不变；扩展 `.sameProvider` / `.anyReady` / `.none` 三档并暴露到设置页。

---

**FR-RTE-05 · 路由决策可查**（CAP-RTE-05，P1）

`RouteDecisionLedger` 已在写 `route-decisions.jsonl`，但**没有任何 UI**。本次补上：运行时页新增"最近路由"列表，每条展示：时间、请求模型、选中的 provider/model、是否转移过、耗时、结果。点击展开完整 trace（候选集、各候选得分、被淘汰原因）。

这是 Doctor 之外最重要的自查手段——"为什么我选的模型没走 DeepSeek"必须能被回答。

---

## 3.4 协议适配（FR-PRO-\*）

**FR-PRO-01 · 四种协议**（CAP-PRO-01..04，P0）

| 协议 | 入站 | 出站 | 状态 |
| --- | --- | --- | --- |
| OpenAI Responses | ✅ | ✅ | 已有 |
| OpenAI Chat Completions | ✅ | ✅ | 已有（含 Chat↔Responses 互转） |
| Anthropic Messages | ✅ | ✅ | 已有 `CanonicalAdapters`，需补全工具调用与 thinking |
| Google Gemini | — | ✅ | **可简化**：`gemini-api` 走 Google 的 OpenAI 兼容面，复用 chat 转发器即可，无需维护原生 Gemini 适配器 |

任意入站协议 × 任意出站协议的组合都必须可用（4×4 中实际有效的组合），通过统一的中间表示（canonical message）转换。

---

**FR-PRO-02 · 流式、工具调用与 reasoning**（CAP-PRO-05，P0）

保持现有 `+ProviderSSE` 行为。补充约束：

- 工具调用分片必须按 `index` 累积，跨 chunk 的 JSON 参数字符串拼接后才解析，**不做逐片解析**。
- reasoning/thinking 内容按目标协议的对应字段回填；目标协议不支持时**丢弃而非塞进正文**——把思维链混进 content 会污染用户可见输出。
- 上游发送非法 SSE（缺 `data:` 前缀、JSON 不完整）→ 跳过该行并计数，连续 10 行非法则中断并报错。

---

**FR-PRO-03 · 请求体解压**（CAP-PRO-06，P0）

已有 Brotli/Zstd/gzip 支持，保持。

---

**FR-PRO-04 · Body 大小上限**（CAP-PRO-08，P1）

两道独立限制，**编码前与解码后分别设限**：

- 编码后（wire 上的字节数）：**64 MiB**
- 解码后（解压展开的字节数）：**256 MiB**

超限返回 413 并明确指出是哪一道限制。第二道限制是防解压炸弹的必需项——只限第一道，一个几 MB 的 Brotli 包可以展开成几十 GB。

---

**FR-PRO-05 · Per-provider Request Profile**（CAP-PRO-07，**P0**）

每个模型条目携带 `requestProfile`（见 `seed/provider-registry-seed.json` 的 `requestProfiles`）。Profile 描述该上游对请求体的特殊要求：

| 字段 | 语义 |
| --- | --- |
| `reasoningParameter` | 推理参数以什么形式发送：`none` / `reasoning_effort` / `thinking` / `enable_thinking` / `thinking_budget` |
| `supportsDisable` | 是否允许关闭推理 |
| `forcedEffort` | 强制档位（如 `kimi-k3` 恒为 max） |
| `stripVendorNativeThinking` | 是否需剥离厂商原生 thinking 参数 |
| `injectHostedTools` | 需注入的托管工具声明 |

**最关键的一条**：`dashscope-compatible`。DashScope 兼容模式会**拒绝**各厂商的原生 thinking 参数——经 `qwen-plan` 调用 `deepseek-v4-pro` 时，若沿用 DeepSeek 原生的 `thinking` 字段，请求会被 400 拒绝。必须剥离后改用兼容字段 `enable_thinking`。

Profile 未命中（用户自定义 provider）→ 使用保守默认：`reasoningParameter: none`，不附加任何非标准字段。

---

**FR-PRO-06 · Grok OAuth 托管检索工具**（CAP-PRO-09，P2）

`xai-oauth-hosted-tools` profile 在请求中附加 `web_search` / `x_search` 的**裸工具声明**。检索由 xAI 后端决定与执行，本地不提供检索开关、不解析检索结果、不做二次请求。

---

**FR-PRO-07 · 身份信息隔离**（**P0，安全红线**）

发往第三方 provider 的请求，**必须剥离**：ChatGPT/Codex 的 account id、session id、installation id、device id、attestation 头、`originator` 标识、以及任何 `chatgpt-*` / `openai-*` 自定义头。

- 实现方式为**白名单**而非黑名单：只转发明确列举的标准头（`content-type`、`accept`、`user-agent`（Copool 自己的）、以及该 provider 所需的鉴权头）。
- 验收：针对每个内置 provider 构造一次请求，断言出站头集合 ⊆ 白名单。

---

## 3.5 运行时（FR-RUN-\*）

**FR-RUN-01 · 仅回环监听**（CAP-RUN-01，P0，AC-009）

所有监听器绑定 `127.0.0.1`。`TargetBinding.listenerHost` 已有此约束，本次加**运行时断言**：启动时若 host 不是回环地址，拒绝启动并报错。

Cloudflared 隧道（CAP-RUN-05）是**显式的例外**，由用户主动开启，开启时必须有醒目警告说明这会把服务暴露到公网，且强制要求 capability token 校验开启。

---

**FR-RUN-02 · caller capability 校验**（CAP-RUN-02，P0）

`TargetBinding` 已有 `callerCapability` / `internalCapability` 字段，但**校验逻辑未实现**——当前任何本机进程都能访问监听端口。

本次实现：

- 每个请求必须携带 `Authorization: Bearer <callerCapability>`；不匹配返回 401。
- token 随绑定生成（32 字节随机），存 Keychain，写入目标配置的托管块中作为该 provider 的 API key。
- 提供"重新生成 token"，重新生成后目标配置标记为过期，需重新应用。

理由：回环监听不等于安全——本机上任何进程（包括浏览器里的网页通过 localhost 请求）都能访问。

---

**FR-RUN-03 · 端口分配与冲突处理**（CAP-RUN-03，P0）

- 默认端口：codex `8787`、cursor `8788`、opencode `8789`。
- 启动时端口被占 → 自动在 `+1..+20` 范围内探测可用端口，成功后**更新绑定并标记目标配置过期**（因为配置里写的是旧端口）。
- 20 个都不可用 → 启动失败，Doctor 给出明确诊断。
- 崩溃恢复：进程异常退出后，下次启动清理残留的 state 目录锁文件。

---

**FR-RUN-04 · 限流头解析**（CAP-RUN-07，P0）

`RateLimitModels` 已存在但**未接线**。本次接入响应处理链：

- 解析 `x-ratelimit-limit-requests` / `-remaining-requests` / `-reset-requests` 及 tokens 系列。
- Anthropic 系用 `anthropic-ratelimit-*` 前缀（种子数据已标注 `rateLimitHeaderPrefix`）。
- 不返回限流头的 provider（如 `gemini-api`、`qwen-plan`，种子数据已标 `publishesRateLimitHeaders: false`）→ UI 显示"该服务不提供配额信息"，**不显示 0 或未知数字**，避免误导。
- 结果落 `provider-rate-limits.json`，在供应商卡片上展示剩余量与重置时间。

---

**FR-RUN-05 · 用量记账**（CAP-RUN-08，P0）

`UsageEventLedger` 已有。补充：每次请求记录 provider、model、input/output tokens、耗时、是否转移、结果。运行时页提供 7 日视图，按 provider 分组。

Token 数优先取上游返回的 usage；上游不返回时**标记为估算**，不假装精确。

---

**FR-RUN-06 · 操作锁**（CAP-OPS-04，P1）

对目标配置的 apply/rollback/uninstall 加互斥锁（进程内 + 文件锁）。并发操作直接拒绝并提示"另一项配置操作正在进行"。

---

**FR-RUN-07 · 死接线清理**（P0）

`Sources/Copool/App/AppContainer.swift:113-119` 构造了 `TaskEnvelopeDispatcher` 与 `RemoteNodeControlService` 但从未被消费。二选一：

- 若 M5（Agent/语音）在本轮交付 → 接线到实际消费方；
- 若不在本轮 → **移除构造**，避免误导后续维护者以为该能力已可用。

**默认选择后者**：P2 优先级的能力不应在 P0 交付里留下无主对象。

---

## 3.6 Doctor（FR-DOC-\*，CAP-OPS-01，P0）

现有 `ProxyDoctor` 需扩展为分类检查体系。每项检查产出 `通过 / 警告 / 失败`，失败项必须带**具体修复动作**（可点击执行或明确的手工步骤）。

| 分类 | 检查项 | 自动修复 |
| --- | --- | --- |
| **运行时** | 监听端口可用；进程存活；回环绑定正确 | 换端口、重启运行时 |
| **凭据** | 每个启用的 instance 至少一个就绪凭据；令牌未过期 | 跳转录入/重授权 |
| **目录** | 目标目录非空；每个模型的 provider 就绪 | 重建目录 |
| **目标配置** | 托管块存在且成对；指纹与上次应用一致；端口与当前监听一致 | 重新应用配置 |
| **网络** | 每个启用 provider 的 baseURL 可达（HEAD/GET /models） | 无（给出诊断） |
| **文件系统** | 状态目录可写；备份存在；日志未超限 | 创建目录、清理日志 |
| **配置健康** | 无重复别名；无孤儿凭据引用；无指向已删除 instance 的目录条目 | 清理孤儿 |

**自动修复率目标 ≥ 60%**（01 章成功指标）。所有自动修复必须先展示"将要做什么"，用户确认后执行。

---

## 3.7 本章需求 → 能力矩阵回溯表

| 需求 | 能力 ID | 优先级 |
| --- | --- | --- |
| FR-TGT-01 | CAP-TGT-04 | P0 |
| FR-TGT-02 | CAP-TGT-02 | P0 |
| FR-TGT-03 | CAP-TGT-03 | P0 |
| FR-TGT-04 | CAP-TGT-05 | P0 |
| FR-TGT-05 | CAP-TGT-06 | P0 |
| FR-TGT-06 | CAP-TGT-07 | P0 |
| FR-TGT-07 | CAP-TGT-08, CAP-TGT-09 | P1 |
| FR-TGT-08 | CAP-TGT-10 | P0 |
| FR-TGT-09 | CAP-TGT-11 | P2 |
| FR-RTE-01 | CAP-RTE-01/02/03 | P0 |
| FR-RTE-02 | CAP-RTE-02 | P0 |
| FR-RTE-03 | CAP-RTE-03 | P0 |
| FR-RTE-04 | CAP-RTE-04 | P0 |
| FR-RTE-05 | CAP-RTE-05 | P1 |
| FR-PRO-01 | CAP-PRO-01..04 | P0 |
| FR-PRO-02 | CAP-PRO-05 | P0 |
| FR-PRO-03 | CAP-PRO-06 | P0 |
| FR-PRO-04 | CAP-PRO-08 | P1 |
| FR-PRO-05 | CAP-PRO-07 | P0 |
| FR-PRO-06 | CAP-PRO-09 | P2 |
| FR-PRO-07 | 新增（安全红线） | P0 |
| FR-RUN-01 | CAP-RUN-01 | P0 |
| FR-RUN-02 | CAP-RUN-02 | P0 |
| FR-RUN-03 | CAP-RUN-03 | P0 |
| FR-RUN-04 | CAP-RUN-07 | P0 |
| FR-RUN-05 | CAP-RUN-08 | P0 |
| FR-RUN-06 | CAP-OPS-04 | P1 |
| FR-RUN-07 | 新增（技术债清理） | P0 |
| FR-DOC-\* | CAP-OPS-01 | P0 |
