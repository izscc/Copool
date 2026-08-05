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
