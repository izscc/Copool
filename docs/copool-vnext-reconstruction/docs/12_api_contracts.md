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
