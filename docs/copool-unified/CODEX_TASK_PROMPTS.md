# CODEX_TASK_PROMPTS · 里程碑执行 Prompt

> 每个里程碑一段可直接投喂给 Codex 的 prompt。执行前先读 `CODEX_MASTER_GOAL.md`。
> 每段 prompt 都是自包含的：任务清单 + 关键约束 + 验收命令 + 完成标志。

---

## M0 · 地基与护栏

```
读 docs/copool-unified/CODEX_MASTER_GOAL.md 与 07/09 两章，然后执行 M0。

目标：打好后续所有工作的地基，清掉三个已知技术债。不新增用户可见功能。

任务：

1. 把 docs/copool-unified/seed/provider-registry-seed.json 复制到
   Sources/Copool/Resources/provider-registry-seed.json，并加入 Package.swift
   的 resources 声明（.copy）。

2. 新建 Sources/Copool/Infrastructure/ProviderRegistrySeedLoader.swift：
   - 从 Bundle.module 读种子，解码为
     (definitions: [ProviderDefinition], catalog: [ModelCatalogEntry],
      profiles: [String: RequestProfile])
   - 结果用 static let 缓存，进程内只解码一次
   - 解码失败不降级为空注册表，抛错（由 TST-01 在构建期拦截）

3. 按 07 章 DM-01..06 扩展 Sources/Copool/Domain/VNextRegistry.swift：
   - ProviderDefinition 新增：ownership, baseUrlEnv, environmentVariables,
     credentialPrompt, catalogOnly, sharedCredentialGroup, externalSession,
     rateLimitHeaderPrefix, publishesRateLimitHeaders, notes
   - CredentialKind 改为五种：apiKey / environmentReference /
     oauthDeviceFlow / externalCLISession / subscriptionImport
     （解码时把旧值 "oauth" 映射到 oauthDeviceFlow）
   - CredentialIdentity 新增：healthState(五态), lastVerifiedAt, expiresAt,
     lastFailureReason（失败原因入库前必须脱敏）
   - ProviderInstance 新增：baseURLOverride, enabled, credentialIdentityIDs
   - ModelCatalogEntry 新增：requestProfileID, autoCompactThreshold,
     visibility, origin, upstreamAvailable
   - ModelCapabilitiesV2 新增：reasoningEfforts: [String]?（nil=未知，
     []=明确不支持，两者语义不同不可合并）、inputModalities: [String]
   - 新增 RequestProfile 类型（见 07 章 DM-06）
   - ProviderRegistryV2 新增 requestProfiles，currentVersion 从 2 改为 3

4. 修复 Sources/Copool/Infrastructure/TargetConfigFileAdapter.swift 的死锁：
   plan(to:) 在持有 lock 时调用了两次 detect()，而 detect() 也会 lock.lock()。
   NSLock 不可重入，这会死锁。
   抽出不加锁的 private func detectLocked() -> TargetConfigSnapshot?，
   由 detect() 与 plan(to:) 各自在自己的临界区内调用。
   同一文件里检查是否还有其他持锁方法互调的情况，一并修掉。

5. 修复同文件 verify(_:)：当前用 current == diff.after.content 全文比较，
   目标应用或用户改动托管块之外的内容会导致误判失败。
   改为只比较 copool-managed / copool-managed-provider 两个托管块区间的内容。

6. 移除 Sources/Copool/App/AppContainer.swift:113-119 中
   TaskEnvelopeDispatcher 与 RemoteNodeControlService 的构造与存储属性——
   它们被创建后从未被任何代码读取。相关类型文件保留（测试仍在用），
   只删 AppContainer 里的无主实例。

7. 删除 Sources/Copool/Features/Providers/ProviderPageView.swift:733-736 的
   ProviderCurationSection.discoverableModels——恒返回 [:] 且无人调用。

8. 新增测试 Tests/CopoolTests/ProviderSeedIntegrityTests.swift（TST-01）：
   - definitions.count == 23，id 全局唯一
   - 除 kimi-oauth / grok-oauth 外，defaultBaseURL 均以 "https://" 开头
   - catalog 共 44 条，按 provider 逐家断言分布，ModelCatalogEntry.id 全局唯一
   - 每个 catalog 条目的 provider 都能在 definitions 中找到
   - 声明了两者的条目满足 autoCompact < contextWindow
   - 每个 requestProfileID 都能在 requestProfiles 中找到

9. 新增测试 Tests/CopoolTests/SecretLeakageTests.swift（TST-02）：
   构造含凭据的完整注册表 → JSONEncoder 编码 → 断言产物字符串中
   不含 "sk-"、不含测试用假 key 值、不含 "Bearer " 后跟非空内容。
   对 RouteDecisionTrace 与 UsageEvent 重复同样断言。

10. 新增测试 Tests/CopoolTests/IdentityStabilityTests.swift（TST-03）：
    创建四类对象 → 修改所有 displayName → 断言所有 id 字段逐一不变。

11. 新增测试 Tests/CopoolTests/TargetConfigDeadlockTests.swift（TST-05）：
    先写会失败的测试证明死锁存在（用 XCTestExpectation + 1 秒超时），
    再验证第 4 步修复后通过。

约束：
- 不改任何 Accounts*Tests 的断言
- 不改 LayoutRules 的任何常量
- Swift 6 严格并发：新增类型全部 Sendable

验收：
  swift build 2>&1 | grep -i warning   # 新增代码零警告
  swift test                           # 全绿，含既有 47 个文件

完成标志：种子能解码出 23 家 / 44 条、死锁测试通过、既有测试全绿。
```

---

## M1 · 供应商注册表

```
读 CODEX_MASTER_GOAL.md 与 02 章（FR-IDT-*、FR-PRV-*）、05/06 章的
CMP-01/02/04/05 与 SCR-PRV-01。执行 M1。

目标：用户打开供应商页能看到 23 家内置供应商，填一次 Key 就能用。

任务：

1. Sources/Copool/Domain/ 新增 ProviderRegistryResolver：
   合并内置 definitions 与 userDefinitions 覆盖层。
   字段级覆盖：userDefinitions[id] 中未设置的字段回落内置值。
   纯函数，无 IO。

2. baseURL 三级优先级（FR-PRV-06）：
   用户覆盖 > 环境变量 baseUrlEnv > 内置 defaultBaseURL
   解析结果要能回答"当前值来自哪一级"，UI 要显示。

3. 新增 Sources/Copool/Behavior/CredentialCoordinator.swift（@MainActor）：
   - 五种 CredentialKind 的增删改查
   - apiKey / oauthDeviceFlow / subscriptionImport → 写 Keychain
   - environmentReference → 只存变量名，运行时读进程环境
   - externalCLISession → 不复制，记录来源路径，每次按需读
   - Keychain 写失败必须抛错中止（SEC-01），禁止降级明文

4. 凭据健康状态机（FR-IDT-07，五态：就绪/未配置/已过期/无权限/校验中）：
   驱动信号 = 本地存在性 + 令牌过期时间 + 最近一次真实请求响应码。
   401 → 无权限；403+配额类 → 保持就绪但标记限流；过期时间已过 → 已过期。
   lastFailureReason 写入前脱敏（去掉响应体中可能出现的 key 片段）。

5. 共用凭据组（FR-PRV-02）：
   sharedCredentialGroup 相同的 provider（opencode-go 三通道）共用一把 Key。
   填一次三个同时就绪。UI 必须显示"该 Key 被 3 个通道共用"，
   删除时明确警告影响面。

6. UI：Sources/Copool/UI/ProviderGroupSection.swift（CMP-01）
   三组折叠：已配置(默认展开) / 内置供应商 / 自定义。
   复用既有 CollapseChevronButton。组标题带计数。
   折叠态不渲染子项（LazyVStack + 条件渲染，23 张卡片常驻会拖慢滚动）。
   容器用 frostedRoundedSurface(cornerRadius: 12, prominent: false)。

7. UI：Sources/Copool/UI/CredentialStatusBadge.swift（CMP-02）
   五态徽章，颜色图标严格按 IA-09。整个徽章可点击，
   点非就绪状态直达修复动作。视觉规格参照既有 AccountTagView。

8. UI：Sources/Copool/UI/CredentialEntrySheet.swift（CMP-04）
   见 06 章的 ASCII 布局。要点：
   - API Key 用 SecureField，已保存显示掩码 sk-••••••••1234
     （前3位+后4位+固定8个圆点，不泄露真实长度）
   - 环境变量模式检测到变量已存在时显示绿色"已检测到"
   - Base URL 下方常驻"当前生效来源"一行
   - 输入框用既有 frostedRoundedInput 修饰器

9. UI：Sources/Copool/UI/DisclosureConsentSheet.swift（CMP-05，SEC-08）
   见 06 章布局。要点：
   - 逐条列出：来源应用、读取路径、账号(脱敏)、用途、是否复制、如何撤销
   - 复选框默认不勾选，不勾选时主按钮禁用
   - 不提供"不再提示"
   - 确认记录写 consent-log.jsonl（时间戳+来源+版本）

10. 改造 ProviderPageView：
    - 二级导航从原生 Picker(.segmented) 换成仓库自带的 CapsuleSubTabBar（IA-02）
    - 供应商 tab 换成新的 SCR-PRV-01 布局
    - 空态：现有 ProviderOnboardingSection 三步引导 +「内置供应商」组默认展开
      （让用户第一眼看到 23 家可选项，而不是只有几个 preset）

11. 全部新增文案进 zh-Hans 与 en 两份 Localizable.strings。

注意：
- FR-IDT-04（CLI 登录态复用）与 FR-IDT-05（订阅导入）是 P1，
  本里程碑只需数据结构就位，实际适配器可延后。
- FileSystemPaths 新增 consentLogPath。

验收：AC-101 / AC-114 / AC-115 / AC-122 / AC-125
  swift test
  人工：打开供应商页 → 展开内置 → 点 DeepSeek → 填 Key → 徽章变🟢就绪

完成标志：23 家可见、填 Key 流程走通、532pt 下无横向溢出。
```

---

## M2 · 模型目录

```
读 02 章 FR-CAT-* 与 06 章 SCR-PRV-02。执行 M2。

目标：模型目录能正确合并三个来源，且只有凭据就绪的模型进目标应用。

任务：

1. 扩展 CatalogBuilder 支持三来源合并：
   种子条目 / 实时发现 / 用户策展。
   唯一键 = providerInstanceID + "/" + backendModelID（INV-3，已实现）。
   合并时种子的元数据字段优先级更高——/models 返回的元数据普遍只有
   id 和 owned_by，不该覆盖种子里的 contextWindow 与 reasoningEfforts。

2. 凭据感知过滤（FR-CAT-01，硬约束）：
   模型进目标应用目录的四个条件全部满足才行：
   instance.enabled && 至少一个凭据就绪 && visibility != .hidden
   && 协议在目标 caller capability 支持范围内。
   注意：Copool 自己的 UI 目录不适用此过滤——要显示这些模型并标注
   "缺少凭据"，这是引导配置的入口。两个目录是不同的东西，别写成一个。

3. 实时发现（FR-CAT-03）：GET {baseURL}/models，超时 10s，失败不重试。
   失败不清空已有目录，只标记"上次刷新失败 + 时间 + 原因"。

4. 【行为变更，先写测试】推理档位规则（FR-CAT-05）：
   档位只有三个合法来源：种子声明 / 供应商明确返回 / 用户手动指定。
   都没有 → reasoningEfforts = nil → 不显示档位选择器 → 请求不附加推理参数。
   禁止根据模型名包含 thinking/reasoner/-r1 推断。
   现有 ProviderModels.swift 的 effectiveReasoningEfforts 在
   supportedReasoningEfforts == nil 时兜底返回 ["low","medium","high"]，
   这与本条冲突：v2 路径改为返回空，v1 路径保留原行为直到迁移完成。
   测试要同时锁定两条路径。

5. 上下文窗口（FR-CAT-06）：沿用已实现的 ModelMetadataSource 优先级
   provider(3) > registry(2) > fallback(1) 与 shouldReplace 语义，不改。
   fallbackContextWindow = 200_000 不改。
   UI 要能看出来源，用 fallback 值的模型标"估算"。

6. 用户策展（FR-CAT-04）：勾选结果存活于后续刷新，刷新只更新元数据。
   上游下架的模型标 upstreamAvailable = false 并保留记录，不静默删除。

7. 隐藏、搜索、批量操作（FR-CAT-08）：
   搜索同时匹配 displayName 与 backendModelID。
   按 provider 分组折叠。多选后批量启用/停用/隐藏。

8. UI：SCR-PRV-02 目录 tab（见 06 章布局）
   - 按 provider 分组，"缺少凭据"单独成组置底
   - 每行右侧显示 上下文窗口 · 推理档位；无档位的不显示档位
   - metadata 来源标注只在专家模式下显示
   - 底部显示已隐藏项计数 + 专家模式开关

9. 目录变更传播（FR-CAT-11）：
   任何影响目标可见性的变更 → 标记受影响的 TargetBinding 为"配置已过期"。
   不自动写目标配置——写配置是用户显式动作。

10. 测试 Tests/CopoolTests/CredentialAwareCatalogTests.swift（TST-06）：
    有凭据→模型在目标目录；删最后一个凭据→重建→模型消失；
    provider停用→消失；hidden→不在目标目录但在UI目录。

验收：AC-102 / AC-103 / AC-127
完成标志：填 Key 后模型自动进目录，删凭据后自动消失。
```

---

## M3 · 目标绑定

```
读 03 章 FR-TGT-* 与 06 章 CMP-03 / SCR-PRX-02。执行 M3。

目标：把模型配置安全地写进目标应用，全程可预览、可校验、可回滚。

任务：

1. 六方法契约统一（FR-TGT-01）：
   detect / plan / apply / verify / rollback / uninstall
   三个适配器（codex / cursor / opencode）都实现同一协议。
   注意 M0 已修的死锁——继续遵守"持锁方法不得互调"。

2. 托管块逐字节可逆（FR-TGT-02，SEC-06）：
   - 写入前先 stripMarkedBlocks 剥离旧块，再追加新块
   - 托管块之外的每一个字节原样保留
   - 起止标记不成对 → 中止操作并报告，不猜边界
   - 同名块出现多次 → 全部剥离后写入一个
   - 备份写目标的独立状态目录，不写在用户配置旁边

3. 带时间戳的备份（FR-TGT-05）：
   <stateDirectory>/config-backup-<timestamp>，保留最近 5 份，超出按时间淘汰。
   apply 后立即 verify，失败自动回滚并报错，不留半应用状态。

4. configState 四态（DM-07）：applied / stale / disabled / notDetected。
   用 configFingerprint 比对：指纹不符说明文件被外部改过，操作前提示确认。

5. models_cache.json 注入（FR-TGT-03）：
   保留现有 500ms 去抖，新增每分钟至多 1 次重注入限速——
   否则和目标应用互相写文件会形成循环（RISK-06）。
   注入的条目要带 displayName / contextWindow / reasoningEfforts /
   inputModalities。原生 GPT 模型条目必须原样保留，这是追加不是替换。

6. UI：Sources/Copool/UI/ConfigDiffSheet.swift（CMP-03）
   见 06 章布局。要点：
   - 三段：将新增(绿) / 将移除(红) / 保持不变的用户内容行数(灰，只给计数)
   - 等宽字体 .system(.caption, design: .monospaced)
   - 明确标注目标文件绝对路径与备份路径
   - 不提供"以后不再预览"

7. UI：SCR-PRX-02 目标 tab（见 06 章布局）
   三张卡片，四态徽章，每张显示该目标启用的供应商数与可见模型数。
   按钮：预览并应用 / 回滚 / 移除托管。
   回滚要列出最近 5 份备份（时间+摘要）供选择。

8. 重启提示（FR-TGT-08，SEC-05）：
   apply 成功后显示 .orange 常驻提示条（不是一闪而过的 toast）：
   "配置已写入。请手动退出并重新启动 <目标应用> 使其生效。"
   加一句"如何确认生效"的说明。
   Copool 绝不代为结束或重启目标应用进程。

9. 测试 Tests/CopoolTests/TargetConfigReversibilityTests.swift（TST-04）：
   - 准备含 50 行用户内容的 config.toml（含注释、空行、中文、特殊字符）
     → apply → uninstall → 断言与初始逐字节相等（含尾部换行）
   - 标记不成对 → 断言操作被拒且文件未改动
   - 同名块出现 3 次 → 断言全部剥离后只剩 1 个
   - 目标文件不存在 → apply 能创建，uninstall 不报错

验收：AC-105 / AC-106 / AC-107 / AC-108
完成标志：应用→回滚→卸载三条路径都验证过，配置逐字节可还原。
```

---

## M4 · 路由与协议

```
读 03 章 FR-RTE-* / FR-PRO-* 与 seed/provider-registry-seed.json 的
requestProfiles 段。执行 M4。

目标：请求能正确路由到对的 provider，用对的请求格式，且不泄露身份信息。

任务：

1. 【行为变更，先写测试】解析优先级固化（FR-RTE-02）：
   ① 精确 ModelCatalogEntry.id 匹配
   ② 别名匹配
   ③ 后端模型 ID 匹配（多条 → 进打分器）
   ④ 全部落空 → 【改这里】现在是全目录兜底，改为返回 nil 并记录 trace
   理由：23 家 provider 场景下，用户手误输入一个不存在的模型名会被静默
   路由到随便打分选出的模型，产生真实费用且结果莫名其妙。
   调用方回落 v1 匹配；v1 也不中则返回 404 + 明确错误体
   "未知模型 <name>，请检查目标应用的模型选择"。
   V2RouteResolver 现有的"失败也写 trace"行为保持。

2. 凭据门禁三态（FR-RTE-03）：就绪 / 未就绪 / 限流中。
   限流中的凭据参与打分但权重降低，不做硬排除——
   短时限流不该让整个 provider 不可用。
   RoutePlanner 仍然只收 [String: Bool] 之外的状态枚举，绝不接触秘密值。

3. 失败分类（FR-RTE-04）：按 03 章的 7 行表实现。重点：
   - 401 → 零重试，标记凭据"无权限"，立即返回
   - SSE 已开始后断开 → 零重试（已产生费用且客户端已收到部分内容）
   - 429 → 换同 provider 其他凭据，无则按 FallbackPolicy 转移
   - 403 要区分配额型与禁止型
   禁止无差别重试。

4. RequestProfile 应用层（FR-PRO-05）：
   实现 11 个 profile。最关键的是 dashscope-compatible：
   DashScope 兼容模式会拒绝各厂商原生 thinking 参数，
   经 qwen-plan 调用 deepseek-v4-pro / glm-5.2 时必须剥离原生参数、
   改用兼容字段 enable_thinking，否则 400。
   未命中 profile（用户自定义 provider）→ 保守默认：不附加任何非标准字段。

5. 出站头白名单（FR-PRO-07，SEC-04）：
   实现为白名单而非黑名单。只转发：content-type、accept、
   Copool 自己的 user-agent、该 provider 所需的鉴权头。
   必须剥离：ChatGPT/Codex 的 account id、session id、installation id、
   device id、attestation 头、originator、所有 chatgpt-* 与 openai-* 头。

6. Body 双重大小限制（FR-PRO-04，SEC-11）：
   编码前 64 MiB、解码后 256 MiB，两道独立限制。
   只限第一道挡不住解压炸弹——几 MB 的 Brotli 能展开成几十 GB。
   超限 413，错误体指明是哪一道。

7. Anthropic Messages 补全工具调用与 thinking 字段映射。
   工具调用分片按 index 累积，跨 chunk 的 JSON 参数字符串拼接后才解析。
   reasoning 内容目标协议不支持时丢弃，不要塞进 content——
   把思维链混进正文会污染用户可见输出。

8. Gemini 简化：gemini-api 走 Google 的 OpenAI 兼容面，
   复用 chat 转发器，不维护独立的原生 Gemini 适配器。

9. UI：SCR-PRV-03 路由 tab（FR-RTE-05）
   最近路由决策列表，每条：时间/请求模型/选中的 provider+model/
   是否转移/耗时/结果。点击展开完整 trace（候选集、各候选得分、淘汰原因）。
   RouteDecisionTrace 已含全部字段，只需消费。

10. 测试：TST-07（解析优先级，含第④步返回 nil）、TST-08（7 类失败）、
    TST-09（profile 应用）、TST-10（头白名单）、TST-12（双重大小限制）。

验收：AC-109 / AC-110 / AC-111 / AC-116
完成标志：未知模型 404 而非静默路由；出站头断言 ⊆ 白名单。
```

---

## M5 · 运行时与 Doctor

```
读 03 章 FR-RUN-* / FR-DOC-* 与 08 章 OBS-*。执行 M5。

目标：运行时安全可控，出问题时用户能自己诊断和修复。

任务：

1. caller capability 校验（FR-RUN-02，SEC-03）：
   现状是 TargetBinding 有 callerCapability 字段但没有校验逻辑——
   本机任意进程（包括浏览器页面请求 localhost）都能访问监听端口。
   实现：每个请求校验 Authorization: Bearer <callerCapability>，不匹配 401。
   token 随绑定生成（32 字节随机），存 Keychain，
   写入目标配置托管块作为该 provider 的 API key。
   提供"重新生成 token"，重新生成后目标配置标记 stale。

2. 端口分配（FR-RUN-03）：
   默认 codex 8787 / cursor 8788 / opencode 8789。
   被占则在 +1..+20 探测，成功后更新绑定并标记目标配置过期
   （因为配置里写的是旧端口）。20 个都不可用则启动失败，Doctor 给诊断。
   崩溃恢复：下次启动清理残留的 state 目录锁文件。

3. 回环绑定启动断言（FR-RUN-01，SEC-02）：
   启动时检查 listenerHost 是回环地址，不是就拒绝启动。

4. 限流头解析接线（FR-RUN-04）：
   RateLimitModels 已存在但未接线，接进响应处理链。
   解析 x-ratelimit-* 系列；Anthropic 系用 anthropic-ratelimit-* 前缀
   （种子数据已标 rateLimitHeaderPrefix）。
   publishesRateLimitHeaders == false 的 provider（gemini-api、qwen-plan）
   显示"该服务不提供配额信息"，不显示 0 或未知数字——那会误导用户。

5. 用量记账 7 日视图（FR-RUN-05）：
   token 数优先取上游返回的 usage；不返回时标"估算"，不假装精确。

6. 操作锁（FR-RUN-06）：目标配置的 apply/rollback/uninstall
   加进程内锁 + 文件锁。并发操作直接拒绝，提示"另一项配置操作正在进行"。

7. Doctor 七分类（FR-DOC）：
   运行时 / 凭据 / 目录 / 目标配置 / 网络 / 文件系统 / 配置健康。
   每项产出 通过|警告|失败，失败必须带具体修复动作。
   自动修复覆盖率 ≥ 60%（AC-118）。
   所有自动修复先展示"将要做什么"，用户确认后执行。
   具体检查项见 03 章的七行表。

8. 日志脱敏与轮转（OBS-01/02）：
   脱敏在**写入时**做不是导出时做——否则磁盘上已经泄露了。
   过滤：API key 片段、Bearer token、邮箱(留首字符+域名)、路径中的用户名。
   jsonl 超 10MB 轮转为 .1，只留 1 份历史。

9. 支持包（OBS-03）：应用版本 + 系统版本 + 注册表结构(去凭据引用 name) +
   目标绑定状态 + Doctor 最近结果 + 三条日志尾部各 500 行。
   导出前展示清单与"已脱敏哪些字段"。

10. UI：SCR-PRX-01 加全局健康摘要行；SCR-PRX-03 诊断 tab
    （7 个 SectionCard，有失败的默认展开、全通过的默认折叠，
      分类标题带计数）。

11. 测试 TST-11（capability 校验四例）。

验收：AC-112 / AC-113 / AC-117 / AC-118 / AC-128
完成标志：无 token 请求被拒；Doctor 七类都有检查项且失败项都有修复动作。
```

---

## M6 · 迁移与打磨

```
读 07 章 MIG-* 与 09 章 TST-13..16、09.4 人工验收清单。执行 M6。

目标：老用户升级零数据丢失，全应用中文完整，性能达标。

任务：

1. v2 → v3 迁移（MIG-02）：
   - 新增 requestProfiles：从种子填充；自定义 provider 填默认 profile
   - ModelCatalogEntry 新字段：origin = .userAdded（存量都是手动加的）、
     visibility = .visible、upstreamAvailable = true
   - TargetBinding.configState：按 configFingerprint 是否非空
     推断为 applied / disabled
   - CredentialKind "oauth" → oauthDeviceFlow
   - 版本号 2 → 3，写 MigrationJournal
   迁移前完整备份为 provider-registry-v2.json.bak-<ts>，
   校验失败即还原。不可逆操作一律禁止。

2. 保持现有 migrateProviderRegistryIfNeeded() 的影子迁移策略：
   影子写 → 校验 → 落记录 → 失败即回滚。
   新增：迁移在后台执行不阻塞 UI；期间 UI 显示"正在升级配置"，
   不允许用户同时编辑 provider。

3. 种子升级与用户数据合并（MIG-03）：
   - 内置 definitions 整体替换（只读常量）
   - userDefinitions 覆盖层原样保留
   - instance 引用了已删除的 definition id → 标记"孤儿"，
     提示"该供应商已不再内置，可转为自定义或删除"，不自动删
   - 种子删掉的模型若用户已启用 → upstreamAvailable = false 保留记录

4. 全量本地化补齐：zh-Hans 与 en 的 key 集合完全相等。
   中文文案要完整，不允许英文导航项或英文术语混排。
   技术标识（provider id、model id、路径、HTTP 头名）保持英文。

5. 错误文案三段式改造：发生了什么 + 为什么 + 怎么办。
   例："无法连接 DeepSeek（连接超时）。请检查网络，或在设置中确认 Base URL。"

6. 性能核对（08.5）：
   冷启动 < 800ms / 种子解码 < 50ms / 目录重建 < 100ms /
   首字节额外开销 < 30ms / 常驻内存 < 150MB。
   流式转发不做缓冲聚合——收到 chunk 立即转发。

7. 测试：
   TST-13 迁移五场景（全新/v1→v3/v2→v3/中途崩溃/失败回落）
   TST-14 布局约束（AppTab.allCases.count == 5、三个宽度常量相等、
          accountsPageTargetWidth 公式）
   TST-15 本地化 key 集合相等 + 中文无英文残留
   TST-16 Accounts*Tests 未被修改（diff 检查）

8. 人工验收清单（09.4）逐条走：
   □ 冷启动 < 1 秒
   □ 23 家分组折叠流畅无卡顿
   □ 532pt 下无横向溢出、无文字截断
   □ 二级 tab 标签中英文都完整显示
   □ 深色/浅色模式下新增组件材质正确
   □ 每个空态都能引导到下一步
   □ 每条错误提示都是三段式
   □ 全流程中文无英文残留
   □ 删除类操作都有二次确认且明示影响面
   □ 配置改动都可回滚

验收：AC-119 / AC-120 / AC-121 / AC-122 / AC-123 / AC-124
完成标志：人工清单十条全过，CI 五道门禁全绿。
```

---

## M7 · Agent / 会话 / 语音（P1/P2，价值验证后启动）

```
读 04 章。注意：本里程碑整体是 P1/P2，需在 P0 交付并收到真实使用反馈后
再决定是否启动，以及启动哪些子项。

优先级排序（若启动）：
  FR-AGT-01..04（P1）> FR-SES-01..03（P2）> FR-VOI-01..05（P2）
  FR-AGT-05（MCP 展示，P2）
  FR-AGT-06（Computer Use，P2，很可能直接放弃）

三条不可越过的线：

1. Agent 路由只依据用户填写的 capabilityDescription（FR-AGT-02）。
   禁止根据模型名推断能力——猜出来的能力画像无法解释，出错时用户没法排查。
   路由结果必须附带可展示的选择理由。

2. Computer Use 唯一合法形态是转交给目标应用自带的执行器（FR-AGT-06，SEC-09）。
   绝对禁止自建屏幕截图 / 鼠标键盘注入 / 任何系统控制执行器——
   那等于让任意配置进来的第三方模型直接获得本机控制权，
   而用户配置一个模型时并不预期授予这种权限。
   无法通过原生执行器实现就放弃该能力，不做替代方案。

3. 语音（SEC-10）：麦克风活跃时菜单栏必须持续可见指示，
   提供全局停止。不实现唤醒词常驻监听。
   STT/TTS 默认走本机路径，用 API 路径必须显式选择并明示
   "你的语音将被发送到 <provider>"。
   TaskEnvelope 的确认门是必需的——语音有误识别率，
   未经确认就执行会造成用户没下达过的操作。
   无人确认的 envelope 超时自动作废（默认 60s），不默认执行。

注意：M0 已移除 AppContainer 里 TaskEnvelopeDispatcher 的无主实例。
若本里程碑启动，需重新接线到真实消费方，而不是恢复无主构造。
InMemoryRealtimeTransport 是测试替身，实现时替换为真实传输，
保留内存实现供单测使用。
```

---

## 附：跨里程碑的常驻检查

每完成一个任务，跑一遍：

```bash
swift build 2>&1 | grep -i warning    # 新增代码零警告
swift test                             # 全绿
```

每完成一个里程碑，额外确认：

- [ ] 没有修改 `Accounts*Tests` 的任何断言
- [ ] 没有修改 `LayoutRules` 的任何常量
- [ ] 没有新增顶层 tab
- [ ] 新增文案已进 zh-Hans 与 en 两份
- [ ] 新增的持锁方法没有调用其他持锁方法
- [ ] 新增的秘密处理路径没有落盘明文
- [ ] commit message 用简体中文，说明"为什么"而不只是"改了什么"
