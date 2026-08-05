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

### D-009：物理多 target 拆分暂缓（PRD Phase 1「调整 Package.swift 为多个 target」）

- 评估：Domain 层无 UI 依赖但 5 个文件引用 `L10n`（依赖主 target 的 lproj 资源 bundle）；拆出 `CopoolDomain` 需要 public 风暴 + 资源移动 + XcodeGen 同步，在「无行为变化」约束下回归风险高。
- 决策：**保持单 executable target**；模块边界用 `Domain/VNextProtocols.swift` 协议层 + 目录边界表达（RouterEngine/SecureStore/TargetConfigManaging + façade）。依赖方向无循环（Domain 不依赖 Infrastructure/Features）。物理拆分推迟到 Phase 6（独立 CopoolRouterHost 进程自然形成模块边界）。
- 不静默偏离：此为记录在案的决策，非遗漏。

### D-010：RouterEngine 生命周期方法收敛

- PRD 设想 RouterEngine 含 start/stop；与现有 `ProxyRuntimeService.status/start/stop`（返回 `ApiProxyStatus`）签名冲突。收敛为状态+能力契约面（`engineStatus()` + `engineCapabilities`），生命周期仍走 ProxyRuntimeService 直至 RouterHost。

### D-011：迁移 journal 的 sourceHash 必须确定性

- 初版用 `String.hashValue` 计算 v1 指纹——Swift 的 hashValue 是 per-process 随机，重启后 journal 匹配失败导致重复迁移。改为 FNV-1a 64 位确定性哈希（`628db436...`），重启幂等验证通过。

### D-012：CanonicalTool.schema 用 Data 承载

- PRD 想用 JSON 对象承载工具参数 schema；Swift 6 严格并发下  不满足 Sendable/Equatable。改为 （序列化字节），构造时用  便捷方法。

### D-013：Anthropic tool_result 归为 user 消息

- Anthropic Messages 方言要求 tool_result 放在 user 角色的 content block 里；Canonical 层保持独立 tool 角色，由 AnthropicAdapter 编码时映射（与原实现一致）。

## 阶段差异日志

| 阶段 | 日期 | 差异 | 处置 |
|---|---|---|---|
| Phase 0 | 2026-08-05 | 见 D-001..D-008 | 记录完成 |
| Phase 1 | 2026-08-05 | D-009（拆 target 暂缓）、D-010（RouterEngine 面收敛） | 协议层 + façade 落地，提交 |
| Phase 2 | 2026-08-05 | D-011（确定性 sourceHash） | FNV-1a 修复 + 重启幂等验证 |
| Phase 3 | 2026-08-05 | D-012（schema 用 Data）、D-013（tool_result 归 user） | Canonical 层 + 四适配器落地，提交 |
| Phase 4 | 2026-08-05 | D-014（TargetAdapter 复用现有 marked-block 机制） | TargetBinding + CodexTargetAdapter + Origin 拒绝 + 脱敏支持包，提交 |
| Phase 5 | 2026-08-05 | D-015（UI 子导航括号重构经编译修复） | Catalog/Routes/Usage 子导航，提交 |
| Phase 6 | 2026-08-05 | D-016（host 端口自动选择，避免占用冲突） | CopoolRouterHost + UDS control，提交 |
| Phase 7 | 2026-08-05 | D-017（Beta adapter 复用通用标记块） | Sessions + Cursor/opencode adapter，提交 |
| Phase 8 | 2026-08-05 | D-018（枚举关联值不能带 raw type；TaskEnvelope 显式 Codable） | Voice/Realtime 权限门，提交 |
| Phase 9 | 2026-08-06 | D-019（heartbeat 白名单防 secret） | RemoteNode + release checklist，提交 |

### D-020：验收差距补全（P0/P1/P2 + UI 结构）

按 `docs/copool-vnext-reconstruction/CODEX_MASTER_GOAL.md` 与 `28_acceptance_matrix.md` 逐条核对后补全的差距（提交 7bc93e2、5692b1e、08675b6、72c4dea）：

- AC-009：Swift 数据面（SimpleHTTPServer + CopoolRouterHost DataPlaneServer）`requiredInterfaceType = .loopback` 显式绑定。
- AC-012：`RoutePlanner` 从纯函数接入生产调用链——`V2RouteResolver` 读 v2 registry，硬过滤→评分→选择，trace 追加 `route-decisions.jsonl`（`RouteDecisionLedger`，500 条剪枝）；v2 缺失时无损回退 v1 匹配。
- AC-013：错误分类补 transient 5xx（排除 501/505）；`parseRetryAfter`（整数秒/HTTP-date）；指数退避 1/2/4/8s 封顶；每候选二次尝试；总尝试硬上限 3。
- AC-014：Doctor 三态（PASS/WARN/FAIL）——proxy.health/providers.store/providers.permissions=fail，codex.config/models_cache/auth/usage.ledger=warn；UI 三色图标。
- AC-004：`rollbackMigration(sourceHash:)`——删 v2 registry + journal 翻转 `rolledBack`，v1 保持源真相，幂等可重迁移（测试）。
- UI 二级导航：运行时 Overview/Targets/Remote/Public/Logs（Targets 卡片展示稳定路由键/方言/凭据状态 AC-008；Logs 本地 tail + 远程入口）；Agent Profiles/Sessions/Tools/Live（Sessions 实现 AC-102 索引+搜索+预览 sheet；Tools 展示 AC-104 边界）；设置 General/Security/Diagnostics/Advanced（Security AC-003 姿态；Advanced AC-105 外部模型开关）。
- AC-101：`TargetConfigCoordinator` 注册适配器到 AppContainer；Targets 子页 plan→确认→apply→verify→rollback 入口。
- AC-106：usage origin 来源判定——5 处构造点改 `.observed`，`fromHeaders`（anthropic-usage/x-usage → `.header`，4/4 解析测试），`estimated()` 工厂。
- AC-202：`TaskEnvelopeDispatcher`（pending→confirmed→executing→completed 生命周期 + task-envelopes.jsonl 审计 trail + agent 路由事件）；TaskEnvelope 改 Codable。
- AC-204：`RemoteNodeControlService`（SSH 传输上的 node-info 握手 evaluate、heartbeat 探测折入 HeartbeatMonitor、SCP+install 升级、previous-version 回滚、.updating 门）。

诚实限制：`swift test` 本机无 Xcode（缺 XCTest）无法运行，新增测试（回滚、envelope、node control、usage origin 等）在 CI/Xcode 环境执行；本机以端到端回归（scripts/vnext-verify.sh 10/10）替代验证。
