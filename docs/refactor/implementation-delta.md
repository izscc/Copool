# Implementation Delta — Copool vNext

> 生成时间：2026-08-05（Phase 0 基线）；此文件随阶段推进持续更新。
> 规则：实际代码与 PRD 冲突时**记录在此，不静默偏离**。

## Phase 0 初始差异

### D-001：领域模型缺失（PRD `docs/11_data_model.md` vs 现状）

| vNext 要求 | 现状 | 差距 |
|---|---|---|
| `ProviderDefinition`（无秘密的供应商公共定义） | 无；`ProviderPreset` 是 UI 级常量 | 需新增 |
| `CredentialIdentity`（认证方式 + 安全引用） | 无；`ProviderConfig.apiKey/refreshToken` 直接承载 | 需新增 |
| `ProviderInstance`（用户配置端点/账单通道） | `ProviderConfig` 混载定义+实例+秘密 | 需拆分 |
| `ModelCatalogEntry`（instance+model 唯一键 + 来源） | `ProviderModel` 有 `contextWindowSource`，无唯一键概念 | 需增强 |
| `TargetBinding`（每目标隔离） | 无（单一 in-process 代理） | 需新增 |
| `RoutePolicy` / `RouteDecisionTrace` | `AgentTaskRouter` 有评分但无硬约束/预算/失败链 trace | 需扩展 |
| `SessionRecord` / `RemoteNode` | 无 | 需新增 |

### D-002：路由键依赖可变 name（违反 AC-005）

- 现状：`ProviderConfig.routePrefix` 由小写 name 派生（`ProviderModels.swift:155-157`），clientModelID 形如 `name/model`。
- 风险：用户重命名 provider 会改变所有已保存路由/会话引用。
- 处置：Phase 2 引入稳定 `ProviderInstance.id` 作为路由键前缀；name 仅展示。

### D-003：v1 配置可编码 secret（违反 AC-003）

- 现状：`ProviderConfig.apiKey/refreshToken` 是 Codable 存储属性（运行中经 Keychain 回填，但类型层面仍可编码落盘）。
- 处置：Phase 2 将 secret 移出 Codable 类型（`CredentialIdentity` 引用 + Keychain-only），并加编码测试（AC-003）。

### D-004：多目标隔离缺失（AC-008）

- 现状：单一 in-process 代理（8787）服务 Codex；无 Cursor/opencode target、无 per-target capability/state/端口。
- 处置：Phase 4 引入 `TargetBinding`；Phase 6 独立 Router Host。

### D-005：Router 监听仅 127.0.0.1 ✅（AC-009 部分满足）

- 现状：`SimpleHTTPServer` 绑定 loopback；无 CORS/Origin 处理（非浏览器端）。已符合 AC-009 的绑定要求；浏览器 Origin 拒绝策略在 Phase 4 补测。

### D-006：外部 provider 请求身份隔离 ✅（AC-010 满足）

- 现状：`makeThirdPartyRequest` 只带 provider 自己的 Authorization；不转发 ChatGPT/Codex 头。Phase 4 补 header fixture 测试固化。

### D-007：UI 二级导航缺失（PRD `docs/05_information_architecture.md`）

- 现状：模型服务 Tab = Providers 单页；运行时 Tab = Proxy 单页。
- 处置：Phase 5 引入 Models/Catalog/Routes/Usage、Targets/Remote/Public/Logs 子导航；保持 5 主 Tab + 设计 token（AC-015）。

### D-008：UI 截图基线未建立

- 现状：无 UI snapshot 测试；Phase 0 截图因环境（无 GUI 交互通道）延后。
- 处置：Phase 5 用 `screencapture`/XCTest snapshot 补；验收 AC-015 关联。

## 阶段差异日志

| 阶段 | 日期 | 差异 | 处置 |
|---|---|---|---|
| Phase 0 | 2026-08-05 | 见 D-001..D-008 | 记录完成，进入 Phase 1 |
