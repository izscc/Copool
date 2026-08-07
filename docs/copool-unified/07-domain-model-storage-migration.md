# 07 · 领域模型、存储与迁移

> 编号规则：`DM-<序号>` 为数据模型，`MIG-<序号>` 为迁移。
> 已落地部分见 `Sources/Copool/Domain/VNextRegistry.swift`、`TargetModels.swift`、`ProviderModels.swift`。

---

## 7.1 三条模型不变量

| ID | 不变量 | 强制手段 |
| --- | --- | --- |
| **INV-1** | 秘密值不进任何 `Codable` 结构、日志、支持包 | `SecureReference` 是唯一持久化形式；单测扫描编码产物断言无 `sk-` 前缀字符串 |
| **INV-2** | 任何 ID 不从 `displayName` 派生（AC-005） | 单测：改 displayName 后重新编码，断言所有 id 字段不变 |
| **INV-3** | `ModelCatalogEntry.id == "\(providerInstanceID)/\(backendModelID)"`（AC-011） | 已实现为计算属性；单测断言唯一性 |

---

## 7.2 数据模型

### DM-01 · `ProviderDefinition`（公开定义）

| 字段 | 类型 | 说明 | 状态 |
| --- | --- | --- | --- |
| `id` | String | 稳定标识，内置为语义 slug，自定义为 UUID | 已有 |
| `displayName` | String | 显示名 | 已有 |
| `ownership` | String | 归属厂商（用于分组与图标） | **新增** |
| `supportedProtocols` | [APIDialect] | chat / responses / anthropic / google | 已有 |
| `defaultBaseURL` | String | 内置默认端点 | 已有 |
| `baseUrlEnv` | String? | 环境变量覆盖名（FR-PRV-06） | **新增** |
| `environmentVariables` | [String] | 候选凭据变量名（FR-IDT-03） | **新增** |
| `credentialKinds` | [CredentialKind] | 支持的凭据方式 | 已有 |
| `credentialPrompt` | String? | 录入提示文案 | **新增** |
| `isBuiltIn` | Bool | 区分内置与自定义 | 已有 |
| `catalogOnly` | Bool | 无内置模型，全靠实时发现（FR-PRV-01） | **新增** |
| `sharedCredentialGroup` | String? | 共用凭据组（opencode-go 三通道） | **新增** |
| `externalSession` | ExternalSessionSpec? | CLI 登录态复用规格（FR-IDT-04） | **新增** |
| `rateLimitHeaderPrefix` | String? | 限流头前缀，默认 `x-ratelimit-` | **新增** |
| `publishesRateLimitHeaders` | Bool | 是否提供限流头（FR-RUN-04） | **新增** |
| `notes` | String? | 展示给用户的注意事项 | **新增** |

### DM-02 · `CredentialKind`（五种）

```swift
enum CredentialKind: String, Codable, Sendable {
    case apiKey
    case environmentReference   // 新增
    case oauthDeviceFlow        // 由 oauth 更名细化
    case externalCLISession     // 新增
    case subscriptionImport
}
```

**迁移注意**：现有 `CredentialKind` 含 `oauth`。解码时把 `oauth` 映射到 `oauthDeviceFlow`（MIG-03）。

### DM-03 · `CredentialIdentity`

新增 `healthState`（五态，FR-IDT-07）、`lastVerifiedAt`、`expiresAt`、`lastFailureReason`。

**`secureReference` 仍是唯一的秘密指针**，`healthState` 只记录状态不记录原因中的敏感信息——失败原因必须先脱敏（去掉响应体中可能出现的 key 片段）。

### DM-04 · `ProviderInstance`

新增 `baseURLOverride: String?`（用户覆盖层，FR-PRV-03）、`enabled: Bool`（FR-PRV-05）、`credentialIdentityIDs: [String]`（多账号）。

### DM-05 · `ModelCatalogEntry`

新增：

| 字段 | 说明 |
| --- | --- |
| `requestProfileID` | 指向 `requestProfiles` 的键（FR-PRO-05） |
| `autoCompactThreshold` | 建议压缩阈值，恒 < contextWindow |
| `visibility` | `visible` / `hidden` |
| `origin` | `seed` / `discovered` / `userAdded` |
| `upstreamAvailable` | 上游是否仍存在（FR-CAT-04） |

`capabilities: ModelCapabilitiesV2` 已有 `contextWindow`；新增 `reasoningEfforts: [String]?`（**`nil` 表示未知，空数组表示明确不支持**——两者语义不同，不可合并）与 `inputModalities: [String]`。

### DM-06 · `RequestProfile`（新增类型）

```swift
struct RequestProfile: Codable, Equatable, Sendable {
    enum ReasoningParameter: String, Codable, Sendable {
        case none, reasoningEffort, thinking, enableThinking, thinkingBudget
    }
    var reasoningParameter: ReasoningParameter
    var supportsDisable: Bool
    var forcedEffort: String?
    var stripVendorNativeThinking: Bool
    var injectHostedTools: [String]
}
```

未命中 profile 时的默认值：`reasoningParameter = .none`，其余全 false/空（FR-PRO-05）。

### DM-07 · `TargetBinding`

已有字段保持。新增 `configState: TargetConfigState`（`applied` / `stale` / `disabled` / `notDetected`，对应 SCR-PRX-02 四态）、`backupHistory: [BackupRecord]`（保留最近 5 份）、`lastAppliedAt`。

### DM-08 · `ProviderRegistryV2`

`userDefinitions` 覆盖层已有。新增 `requestProfiles: [String: RequestProfile]`。

**版本号从 2 → 3**（因为新增了必需字段与 `CredentialKind` 语义变更）。`currentVersion` 常量同步更新，`V2RouteResolver` 的版本门槛（`registry.version == ProviderRegistryV2.currentVersion`）自动跟随。

---

## 7.3 存储布局

全部落在 `~/Library/Application Support/CodexToolsSwift/`（`FileSystemPaths`）：

| 文件 | 内容 | 本次变化 |
| --- | --- | --- |
| `accounts.json` | ChatGPT 账号池 | 不变 |
| `settings.json` | 全局设置 | 增加高级区开关 |
| `providers.json` | v1 ProviderConfig | **只读**，迁移来源 |
| `provider-registry-v2.json` | v2 注册表 | 版本 → 3 |
| `migration-journal.json` | 迁移日志 | 增加 v2→v3 条目 |
| `target-bindings.json` | 目标绑定 | 增加 configState / backupHistory |
| `provider-rate-limits.json` | 限流快照 | 接线（FR-RUN-04） |
| `usage-events.jsonl` | 用量事件 | 不变 |
| `route-decisions.jsonl` | 路由 trace | 增加 UI 消费 |
| `agents.json` / `agent-routes.json` | Agent 配置 / 导入目录 | 保持分离（FR-AGT-04） |
| `<target>/config-backup-<ts>` | 目标配置备份 | **新增**，带时间戳，保留 5 份 |
| `consent-log.jsonl` | 披露确认审计 | **新增**（FR-IDT-06） |

**种子数据**（`provider-registry-seed.json`）编译进 Bundle，**不写入 Application Support**——它是只读常量，写出去只会造成升级时的合并困扰。

### DM-09 · 落盘规则

- 所有 JSON 写入走**原子写**（临时文件 + `replaceItemAt`），`TargetConfigFileAdapter.apply` 已是正确范例。
- JSONL 追加写：单行原子追加；文件超 10MB 时轮转为 `.1`，只保留 1 份历史。
- 任何写失败**必须冒泡为可见错误**，不允许静默吞掉。

---

## 7.4 迁移

### MIG-01 · v1 `providers.json` → v2 注册表

现有 `migrateProviderRegistryIfNeeded()`（`AppContainer.swift`）已实现影子迁移。本次保持其策略：

1. **影子写**：生成 v2 结构写入新文件，v1 文件保持不动；
2. **校验**：读回 v2，逐条比对 provider 数、模型数、baseURL；
3. **落记录**：写 `MigrationJournal`；
4. **失败即回滚**：删除 v2 文件，运行时继续走 v1 路径（`V2RouteResolver` 返回 nil 时的回落路径已存在）。

新增约束：迁移在后台执行，**不阻塞 UI**；迁移期间 UI 显示"正在升级配置"，不允许用户同时编辑 provider。

### MIG-02 · v2 → v3（本次新增）

| 变更 | 迁移动作 |
| --- | --- |
| 新增 `requestProfiles` | 从种子数据填充；用户自定义 provider 填默认 profile |
| `ModelCatalogEntry` 新增字段 | `origin = .userAdded`（存量条目都是用户手动加的）、`visibility = .visible`、`upstreamAvailable = true` |
| `TargetBinding` 新增字段 | `configState` 按现有 `configFingerprint` 是否非空推断为 `applied` / `disabled` |
| `CredentialKind.oauth` | 映射为 `oauthDeviceFlow` |
| 版本号 2 → 3 | 写 journal |

**不可逆操作一律禁止**：迁移前完整备份 v2 文件为 `provider-registry-v2.json.bak-<ts>`，校验失败即还原。

### MIG-03 · 内置种子与用户数据的合并

应用升级带来新种子时：

1. 内置 `ProviderDefinition` **整体替换**（它是只读常量）；
2. `userDefinitions` 覆盖层**原样保留**；
3. 用户已配置的 `ProviderInstance` 若引用了新种子中已删除的 definition id → 标记为 `孤儿`，UI 提示"该供应商已不再内置，你可以转为自定义或删除"，**不自动删除**；
4. 种子新增的模型条目直接进目录；种子删除的模型条目若用户已启用 → 标记 `upstreamAvailable = false`，保留记录（FR-CAT-04）。

### MIG-04 · 迁移的验收

| 场景 | 期望 |
| --- | --- |
| 全新安装 | 直接建 v3，无迁移 |
| 从 v1 升级 | v1 数据完整出现在 v3；v1 文件仍在 |
| 从 v2 升级 | 新字段填默认值；已有配置零丢失 |
| 迁移中途崩溃 | 下次启动检测到不完整迁移，从备份还原后重试 |
| 迁移失败 | 回落旧版本路径，功能不中断，UI 明确提示 |

---

## 7.5 数据模型回溯

| ID | 对应需求 |
| --- | --- |
| INV-1 | FR-IDT-02，全章 |
| INV-2 | FR-PRV-04（AC-005） |
| INV-3 | FR-CAT-01（AC-011） |
| DM-01 | FR-PRV-01/03/06 |
| DM-02 | FR-IDT-03/04/05 |
| DM-03 | FR-IDT-07/08 |
| DM-04 | FR-PRV-03/05 |
| DM-05 | FR-CAT-02/04/05/06/07 |
| DM-06 | FR-PRO-05 |
| DM-07 | FR-TGT-05 |
| DM-08 | FR-PRV-03 |
| DM-09 | FR-TGT-02 |
| MIG-01..04 | CAP-OPS-03 |
