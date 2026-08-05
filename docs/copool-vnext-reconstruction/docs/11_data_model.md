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
