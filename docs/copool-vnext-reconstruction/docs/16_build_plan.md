# 16. 构建计划

## Phase 0 — 基线冻结

- 建立当前功能清单、截图基线、数据 fixture、代理请求/响应 fixture。
- 记录当前构建、测试和已知失败。
- 新建 `docs/refactor/` 决策日志和迁移台账。

## Phase 1 — 模块边界（无行为变化）

- 拆 `CopoolDomain`、`CopoolDesignSystem`、`CopoolApplication`。
- 用协议包裹 ProviderStore、SecureStore、RouterRuntime、TargetConfig。
- 对当前 `SwiftNativeProxyRuntimeService` 建立 façade。

## Phase 2 — Registry v2 与秘密治理

- 引入 ProviderDefinition/Instance/CredentialIdentity/ModelEntry。
- 实现 v1 migration journal、Keychain-only 模型、依赖图。
- 内置 provider registry，支持用户覆盖。

## Phase 3 — Canonical Router Core

- CanonicalRequest/Event/Error。
- 提取 streaming、decompression、retry、compaction、usage。
- 将当前第三方适配器迁到 contract-based adapters。

## Phase 4 — Target 隔离与配置治理

- TargetBinding、capabilities、state dirs、listeners。
- Codex TargetAdapter：detect/plan/apply/verify/rollback。
- Doctor P0、配置 diff、支持包脱敏。

## Phase 5 — 模型目录与路由策略

- credential-aware catalog、live discovery、策展、metadata source。
- RoutePolicy、decision trace、account/credential pools、failover。
- UI Models/Routes/Usage。

## Phase 6 — 独立 Router Host

- 把 RouterEngine 移入 `CopoolRouterHost`。
- UDS/local control API、service lifecycle、migration from in-process。
- 每个 TargetBinding 独立 capability/state/port。

## Phase 7 — Cursor/opencode、Session 与 Agent

- 目标适配器 Beta。
- Session index/import adapters。
- Agent Profiles、MCP/tool bridge、native image/CUA bridge。

## Phase 8 — Voice/Realtime

- STT/TTS/VAD 抽象、Realtime transport、TaskEnvelope。
- 全局 Live capsule、权限和隐私控制。

## Phase 9 — Remote/跨平台

- Remote Node 协议、版本握手、节点身份、更新/回滚。
- Windows router daemon/CLI 可行性；不改 P1 macOS UI。

## 每阶段完成门槛

- 更新 ADR/decision log。
- 单元/contract/migration/security tests 通过。
- UI snapshot 或明确批准的变更。
- 无新增秘密泄漏。
- 生成本阶段 rollback 说明。
- 小粒度提交；不要在未通过门槛时合并到默认分支。
