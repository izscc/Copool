# 17. Codex 主 Goal Prompt

> 将本文件全文作为 Codex Goal 使用。先读取同包 `AGENTS.md` 和文档顺序，再执行。

## Goal

在 `izscc/Copool` 中完成 Copool vNext 的分阶段深度重构：保持现有 SwiftUI 菜单栏产品的视觉规范、账号池能力和用户数据，clean-room 地吸收 OpenCodex 的多协议模型工作台、会话/Agent/Computer Use/图像/Voice/Realtime 能力，以及 Codex Router 的多目标隔离、供应商注册表、凭据隔离、模型策展、Doctor、配置回滚和登录无关模式。不要把参考仓库代码或 UI 直接复制进来；根据本交付包的 PRD、契约和验收矩阵做原创实现。

## 必读顺序

1. 根目录现有 `AGENTS.md`、`README.md`、`Package.swift`。
2. 本包 `AGENTS.md`。
3. `docs/00_source_graph.md`、`01_evidence_log.md`。
4. `docs/03_prd.md`、`05_information_architecture.md`、`08_visual_system.md`。
5. `docs/11_data_model.md`、`12_api_contracts.md`、`13_architecture_hypothesis.md`。
6. `docs/16_build_plan.md`、`28_acceptance_matrix.md`。
7. 对应 `.codex/tasks/phase-*.md`。

## 不可违反的约束

- 保持 P1 的菜单栏窗口、固定宽度、5 个主 Tab、16pt 间距、14pt 卡片、胶囊/Material/Glass、SF Symbols 和统一 NoticeBanner。
- 不复制 P2/P3 的源代码、UI、图标、截图、文案或品牌；只实现公开可观察行为和协议契约。
- 不删除或破坏现有账号导入、手动/智能切换、配额、Providers、Agents、本地代理、远程代理、Cloudflare、Codex/ChatGPT 集成。
- 原生 GPT、ChatGPT 登录、Codex profiles/MCP/project trust/reasoning settings 保持不变，除非用户显式开启对应托管功能。
- 领域配置不保存 API key、refresh token、完整 capability 或授权头；只保存安全引用。
- Router 和管理接口默认仅 UDS/127.0.0.1；拒绝浏览器 Origin，不发送 CORS allow headers。
- 每个 TargetBinding 拥有独立 caller/internal capability、状态目录、端口/endpoint、服务、供应商选择、配置快照。
- 所有目标配置写入必须先 plan/diff，再原子 apply/verify，并可 rollback；不覆盖未标记的用户配置。
- 任何付费 live test 默认关闭，必须显式 `--live --yes` 或 UI 二次确认。
- 不静默重启目标应用。
- 不以“模型名称猜测”作为 Agent 路由依据；使用能力矩阵和用户策略。
- 工具调用/Computer Use 保留 Codex 或显式受信执行器作为执行边界；不得让外部模型直接获得隐式系统控制权。

## 执行模式

### 1. 先侦察，不先编码

- 生成 `docs/refactor/current-state-inventory.md`：实际文件、依赖、schema、测试、运行时、UI 组件和已集成能力。
- 将实际代码与本 PRD 比较；发现冲突时更新 `docs/refactor/implementation-delta.md`，不要静默偏离。
- 建立 `docs/refactor/baseline.md`，记录当前 `swift build`、`swift test`、已知失败和截图基线。

### 2. 使用子代理分工（若环境支持）

- `explorer`：只读检查领域模型、运行时、UI、迁移和测试；输出证据，不改代码。
- `worker-domain`：Provider/Credential/Model/Route schema 与迁移。
- `worker-router`：Canonical protocol、streaming、adapter、retry、usage。
- `worker-targets`：Codex/Cursor/opencode target adapter、config diff/rollback/doctor。
- `worker-ui`：在现有设计系统内实现二级导航和新页面。
- `worker-agents`：sessions/agent/tool/image/CUA。
- `reviewer-security`：秘密、capability、header、listener、config 权限与日志审计。
- `reviewer-tests`：fixture、migration、contract、UI snapshot 和回归矩阵。

任何 worker 开工前必须读取本 Goal、相关任务文件和实际接口；并行分支不得同时修改同一核心文件。主代理负责集成和最终验证。

### 3. 按阶段执行

严格按 `.codex/tasks/phase-00` 到 `phase-09`。每阶段：

1. 写实施计划和受影响文件。
2. 先补测试/fixture，再改实现。
3. 以最小可回滚增量提交。
4. 运行该阶段验证。
5. 更新决策日志、风险和迁移记录。
6. 只有验收通过才进入下一阶段。

### 4. 绞杀者迁移

- 不先删除 `SwiftNativeProxyRuntimeService`。
- 建立 `RouterEngine` façade 和 golden fixtures。
- 将功能逐个迁到 `CopoolRouterKit`；旧实现成为适配层。
- 独立 `CopoolRouterHost` 就绪并通过等价测试后，再由 feature flag 切换。
- 删除旧代码前必须证明没有调用者、迁移已完成、rollback 已记录。

## 必须实现的领域拆分

- `ProviderDefinition`：供应商公共定义，无用户秘密。
- `CredentialIdentity`：认证方式和安全引用。
- `ProviderInstance`：用户配置的端点/账单通道。
- `ModelCatalogEntry`：provider instance + backend model 唯一键和能力来源。
- `TargetBinding`：每目标的状态/服务/capability/配置。
- `RoutePolicy`：硬约束、评分、预算、失败转移。
- `RouteDecisionTrace`：过滤、分数、选择、重试和失败链。
- `AgentProfile`、`SessionRecord`、`RemoteNode`。

禁止继续用可变 provider name 生成稳定路由键；禁止让 Codable Provider 配置承载 secret value。

## 必须实现的 UI 结构

顶层仍为：账号、模型服务、运行时、Agent、设置。

- 模型服务：Providers / Catalog / Routes / Usage。
- 运行时：Overview / Targets / Remote / Public / Logs。
- Agent：Profiles / Sessions / Tools / Live。
- 设置：General / Security / Diagnostics / Advanced。

默认模式只显示必要字段；Expert Mode 展开协议、raw endpoint、元数据来源、别名、内部 ID 和高级路由参数。

## 必须实现的 provider/协议基础

- OpenAI Native、OpenAI-compatible、Anthropic Messages、Gemini、DeepSeek、Kimi、Grok、Qwen、Z.ai、MiniMax、OpenRouter、Volcengine 以及注册表中定义的 catalog-only providers。
- Provider registry 是数据驱动的；模型列表通过 live discovery/curation 更新，不把研究时点模型名硬编码为长期真相。
- CanonicalRequest/CanonicalEvent 支持 text、reasoning、tools、images、usage、cancel、error；明确 lossiness。

## 测试与安全门槛

- 运行现有测试并保留回归。
- 新增 domain、migration、provider contract、target config、security、UI snapshot 测试。
- 对日志、Doctor、support bundle、配置和 fixture 执行秘密扫描。
- 确认 external provider 请求不携带 ChatGPT/Codex 身份、安装、attestation 或 caller authorization。
- 确认目标 capability 不能跨 target 使用。
- 确认配置 apply 失败可恢复原文件和权限。

## 提交与汇报

- 每个阶段至少一个清晰提交，提交信息使用 `refactor(vnext): ...`、`feat(router): ...`、`test(...)` 等。
- 推送当前工作分支；不要 force-push，不要在验证失败时把不完整重构合入默认分支。
- 最终输出：
  - 完成的阶段和提交。
  - 关键架构决策。
  - 数据迁移结果。
  - 测试命令与结果。
  - Doctor/安全检查结果。
  - 未完成项、已知风险和下一任务文件。

## Definition of Done

- `docs/28_acceptance_matrix.md` 的 P0 条目全部通过。
- 原有核心功能无回归。
- v1 数据可迁移、可重复、可回滚。
- 目标配置可 plan/diff/apply/verify/rollback。
- 无明文 secret 进入领域存储、日志或支持包。
- 路由决策可解释。
- UI 保持 Copool 原视觉语言且固定面板无严重拥挤。
- `swift build`、`swift test` 和新增关键测试通过。
