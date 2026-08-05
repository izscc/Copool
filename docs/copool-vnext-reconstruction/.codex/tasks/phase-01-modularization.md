# Phase 01 — 模块化与 façade

目标：拆出 Domain/Application/DesignSystem/Router façade，不改变外部行为。

- 调整 Package.swift 为多个 target/package（按实际仓库最小可行拆分）。
- SwiftUI 只依赖 application use cases。
- 建立 RouterEngine、ProviderStoreRepository、SecureStore、TargetConfigManaging 协议。
- 用 façade 包住现有 SwiftNativeProxyRuntimeService。
- 迁移不应改变 JSON/schema/监听/页面。

验收：现有测试和 UI snapshot 通过；依赖方向无循环；无复制第二套 runtime。
