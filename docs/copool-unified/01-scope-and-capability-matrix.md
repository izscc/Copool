# 01 · 产品定位、范围与能力覆盖矩阵

> 本章是整个重构的**范围契约**。后续所有章节的需求编号都必须能回溯到本章的能力 ID。

---

## 1.1 一句话定位

**Copool 是 macOS 上的本地模型路由控制台**：把 ChatGPT/Codex 账号池、第三方模型供应商、目标应用绑定与本地路由运行时收拢到一个菜单栏原生应用里，让 Codex、Cursor、opencode 等客户端在不改变自身使用方式的前提下，用上任意已授权的模型。

## 1.2 三方项目定位与本次整合关系

| 项目 | 形态 | 本次整合中的角色 |
| --- | --- | --- |
| **P1 Copool**（本仓库） | SwiftUI 原生 macOS/iOS 应用，38,666 行 Swift | **载体**。保留其 UI 设计规范、账号池能力、Swift 原生路由运行时 |
| **P2 OpenCodex** | Electron/TypeScript 本地网关 + 控制中心 | **能力来源**。提供协议适配语义、本机订阅导入、Agent 路由、会话中心、语音的产品定义 |
| **P3 codex-router** | Node.js 本地路由器 + CLI + 后台服务 | **能力来源**。提供供应商注册表、凭据隔离、目录合并、Doctor、配置回滚的工程语义 |

**Clean-room 约束**：P2/P3 的代码、文案、品牌、UI 布局一律不得复制。本文档提炼的是**产品语义与工程约束**，Swift 侧必须原创实现。

## 1.3 目标用户

| 画像 | 核心痛点 | 关键场景 |
| --- | --- | --- |
| **多账号 Codex 重度用户** | 5h/周配额频繁耗尽，手动切号割裂 | 账号池 + 智能切换（P1 已有，保留） |
| **成本敏感的工程师** | 想用 DeepSeek/GLM/Kimi 等便宜模型，但配置门槛高 | 内置 23 家供应商，填 Key 即用 |
| **已有订阅的多栖用户** | 手里有 Claude/Grok/Cursor/Kimi 订阅，但只能在各自客户端用 | 本机订阅导入，复用官方登录态 |
| **团队工具维护者** | 配置改坏了要能回滚，出问题要能自查 | Doctor + 配置回滚 + 支持包 |

## 1.4 核心价值主张

1. **原生而非网关**——不需要 Node.js、不需要 Electron、不需要常驻终端；一个签名的 macOS 应用。
2. **凭据隔离**——每家供应商独立凭据，秘密只进 Keychain，配置文件只存引用。
3. **目录可信**——模型只在"凭据已就绪"时才出现在目标应用的选择器里，不制造无法调用的死条目。
4. **不破坏原生路径**——原生 GPT 模型、ChatGPT 登录、MCP、Computer Use 全部保持原样；只有用户显式启用的模型才走 Copool。
5. **可回滚**——任何对目标应用配置的改动都有托管块标记、备份与一键回滚。

## 1.5 成功指标

| 指标 | 基线（当前） | 目标 |
| --- | --- | --- |
| 内置可用供应商数 | 0（全靠手填） | ≥ 23 |
| 从零到第一个第三方模型可用的步骤数 | 未定义 | ≤ 4 步 |
| 配置改动可回滚率 | 0% | 100% |
| Doctor 可自动修复的故障类别占比 | 无 Doctor | ≥ 60% |
| 现有账号池功能回归数 | — | 0 |

---

## 1.6 能力覆盖矩阵

**优先级**：P0 = 首版必做；P1 = 首版重要；P2 = 增强；OUT = 明确不做。
**复杂度**：S ≤ 1 天，M ≤ 3 天，L ≤ 1 周，XL > 1 周。

### A. 身份与凭据（CAP-IDT-*）

| ID | 能力 | 来源 | 目标形态 | 优先级 | 复杂度 |
| --- | --- | --- | --- | --- | --- |
| CAP-IDT-01 | ChatGPT/Codex 账号池、导入、切换、删除 | P1 | 保留现状 | P0 | — |
| CAP-IDT-02 | 5h/周配额展示与智能切换评分 | P1 | 保留现状 | P0 | — |
| CAP-IDT-03 | API Key 凭据（隐式输入、Keychain 存储、掩码显示） | P1+P3 | 统一 CredentialIdentity | P0 | M |
| CAP-IDT-04 | 环境变量凭据引用（不落盘） | P3 | CredentialKind.environmentReference | P1 | S |
| CAP-IDT-05 | Kimi Code CLI OAuth 登录态复用 | P3 | 读 `~/.kimi` 系登录态 | P1 | L |
| CAP-IDT-06 | Grok CLI OAuth 登录态复用 | P3 | 读 `~/.grok/auth.json` | P1 | L |
| CAP-IDT-07 | Claude Desktop / Claude Code 登录态导入 | P2 | 加密 OAuth 缓存 + 旧缓存兼容 | P1 | XL |
| CAP-IDT-08 | Cursor 登录态导入 + AgentService 模型发现 | P2 | 刷新令牌 + 模型拉取 | P2 | L |
| CAP-IDT-09 | Antigravity 登录态导入 | P2 | OAuth 登录态 + 动态目录 | P2 | L |
| CAP-IDT-10 | 凭据失效检测与重新授权引导 | P2+P3 | 状态徽章 + 修复入口 | P0 | M |
| CAP-IDT-11 | 导入前的来源披露与显式确认 | 新增 | 合规必需，见 08 章 | P0 | S |

### B. 供应商与模型目录（CAP-PRV-* / CAP-CAT-*）

| ID | 能力 | 来源 | 目标形态 | 优先级 | 复杂度 |
| --- | --- | --- | --- | --- | --- |
| CAP-PRV-01 | **内置供应商注册表（23 家）** | P3 | 随应用发布的种子数据 | **P0** | L |
| CAP-PRV-02 | 用户自定义 OpenAI-Compatible 供应商 | P1+P2 | 保留并强化 | P0 | S |
| CAP-PRV-03 | 用户覆盖层（改 baseURL / 改显示名不影响内置定义） | P3 | userDefinitions 分离 | P0 | M |
| CAP-PRV-04 | 同家供应商多计费通道并存 | P3 | 独立 ProviderDefinition | P0 | S |
| CAP-PRV-05 | 供应商启用/停用（只有启用的才进目标目录） | P3 | enabled 开关 | P0 | S |
| CAP-PRV-06 | baseURL 环境变量覆盖（区域/自建网关） | P3 | baseUrlEnv | P1 | S |
| CAP-CAT-01 | **凭据感知目录**（无凭据的模型不进选择器） | P3 | 目录构建硬约束 | **P0** | M |
| CAP-CAT-02 | 内置模型条目（48 个，含上下文窗口/推理档位/模态） | P3 | 种子数据 | P0 | M |
| CAP-CAT-03 | 模型实时发现（拉 `/models`） | P2+P3 | ModelDiscovery | P0 | M |
| CAP-CAT-04 | 模型策展（从实时目录勾选，存活于更新） | P3 | 用户模型层 | P1 | M |
| CAP-CAT-05 | 推理档位识别（不猜测、不补齐） | P2 | 见 02 章规则 | P0 | M |
| CAP-CAT-06 | 上下文窗口识别（provider > registry > 200K 兜底） | P2 | 已有 `ModelMetadataSource` | P0 | S |
| CAP-CAT-07 | 显示名与后端模型 ID 分离 + 别名 | P2 | ModelCatalogEntry.aliases | P0 | S |
| CAP-CAT-08 | 模型隐藏/搜索/批量操作 | P2 | visibility | P1 | M |
| CAP-CAT-09 | 连通性测试（免费，不消耗配额） | P1+P3 | 已有 ModelConnectivityTester | P0 | S |
| CAP-CAT-10 | 兼容性冒烟测试（付费，默认关闭 + 二次确认） | P3 | 显式开关 | P1 | M |

### C. 目标应用与路由（CAP-TGT-* / CAP-RTE-* / CAP-PRO-*）

| ID | 能力 | 来源 | 目标形态 | 优先级 | 复杂度 |
| --- | --- | --- | --- | --- | --- |
| CAP-TGT-01 | Codex App / CLI 绑定 | P1+P3 | 已有 CodexTargetAdapter，需补全 | P0 | M |
| CAP-TGT-02 | **托管块标记，不覆盖用户配置** | P3 | BEGIN/END 标记 | **P0** | M |
| CAP-TGT-03 | 目录合并进目标原生选择器 | P2+P3 | 已有 syncThirdPartyModels，需强化 | P0 | M |
| CAP-TGT-04 | 适配器六方法契约 detect/plan/apply/verify/rollback/uninstall | P3 | 统一协议 | P0 | L |
| CAP-TGT-05 | 应用前 diff 预览 | P3 | UI sheet | P0 | M |
| CAP-TGT-06 | 配置备份与一键回滚 | P3 | 已有 fingerprint 字段 | P0 | M |
| CAP-TGT-07 | 每目标独立状态目录与端口 | P1 | 已有 TargetBinding | P0 | S |
| CAP-TGT-08 | Cursor 绑定 | P1+P3 | 从 beta 转正 | P1 | L |
| CAP-TGT-09 | opencode 绑定 | P1+P3 | 从 beta 转正 | P1 | M |
| CAP-TGT-10 | 不静默重启目标应用（交还用户） | P3 | 明确提示 | P0 | S |
| CAP-TGT-11 | 无 OpenAI 登录模式 + 原生别名映射 | P3 | native-alias 语义 | P2 | XL |
| CAP-RTE-01 | 目标路由（按 caller capability 分流） | P1 | 已有 | P0 | — |
| CAP-RTE-02 | 模型路由（按 providerInstance + backendModel） | P1 | 已有 V2RouteResolver | P0 | S |
| CAP-RTE-03 | 凭据/账号路由（账号池评分选号） | P1 | 已有 AccountRanking | P0 | — |
| CAP-RTE-04 | 失败转移与重试分类 | P1+P2 | 已有 +RetryFailures，需分类细化 | P0 | M |
| CAP-RTE-05 | 路由决策 trace 可查 | P1 | 已有 RouteDecisionLedger（无 UI） | P1 | M |
| CAP-PRO-01 | OpenAI Responses 协议 | P1 | 已有 | P0 | — |
| CAP-PRO-02 | OpenAI Chat Completions 协议 | P1 | 已有 +ChatToResponses | P0 | — |
| CAP-PRO-03 | Anthropic Messages 协议 | P1 | 已有 CanonicalAdapters | P0 | M |
| CAP-PRO-04 | Google Gemini 协议 | P1 | 已有（P3 走 OpenAI 兼容面，可简化） | P1 | S |
| CAP-PRO-05 | 流式 SSE、工具调用累积、reasoning 回填 | P1 | 已有 +ProviderSSE | P0 | — |
| CAP-PRO-06 | 请求体解压（Brotli/Zstd/gzip） | P1 | 已有 | P0 | — |
| CAP-PRO-07 | Per-provider request profile（如 DashScope 拒绝原生 thinking 参数） | P3 | 新增 profile 层 | P0 | M |
| CAP-PRO-08 | 大 body 安全上限（编码前/解码后分别限制） | P3 | 64MiB/256MiB | P1 | S |
| CAP-PRO-09 | Grok OAuth 路径附加 hosted web_search/x_search | P3 | 特定 profile | P2 | M |

### D. 运行时与运维（CAP-RUN-* / CAP-OPS-*）

| ID | 能力 | 来源 | 目标形态 | 优先级 | 复杂度 |
| --- | --- | --- | --- | --- | --- |
| CAP-RUN-01 | 本地回环 HTTP 服务 | P1 | 已有 SimpleHTTPServer | P0 | — |
| CAP-RUN-02 | caller 鉴权（capability token） | P1+P3 | 已有 capability 字段，需实现校验 | P0 | M |
| CAP-RUN-03 | 端口冲突处理与崩溃恢复 | P3 | 新增 | P0 | M |
| CAP-RUN-04 | 开机自启 | P1 | 已有 LaunchAtStartupService | P0 | — |
| CAP-RUN-05 | Cloudflared 公网隧道 | P1 | 已有 | P1 | — |
| CAP-RUN-06 | 远程 Linux 节点部署/启停/日志 | P1 | 已有 RemoteProxyService | P1 | — |
| CAP-RUN-07 | 限流头解析（x-ratelimit-* / anthropic-ratelimit-*） | P3 | 已有 RateLimitModels，需接线 | P0 | M |
| CAP-RUN-08 | 用量记账与 7 日视图 | P1+P3 | 已有 UsageEventLedger | P0 | S |
| CAP-OPS-01 | **Doctor 诊断（分类检查 + 修复建议 + 自动修复）** | P3 | 已有 ProxyDoctor 需大幅扩展 | **P0** | L |
| CAP-OPS-02 | 支持包（脱敏收集） | P3 | 已有 SupportBundle | P1 | M |
| CAP-OPS-03 | 数据迁移（v1 → v2，journaled、可回滚） | P1 | 已有 MigrationJournal | P0 | M |
| CAP-OPS-04 | 操作锁（防并发改配置） | P3 | 新增 | P1 | S |

### E. Agent / 会话 / 语音（CAP-AGT-* / CAP-SES-* / CAP-VOI-*）

| ID | 能力 | 来源 | 目标形态 | 优先级 | 复杂度 |
| --- | --- | --- | --- | --- | --- |
| CAP-AGT-01 | Agent Profile（能力描述、默认模型、推理强度） | P1+P2 | 已有 AgentModels | P1 | M |
| CAP-AGT-02 | **按用户填写的能力说明路由子任务（禁止按模型名猜测）** | P2 | 已有 AgentTaskRouter | P1 | M |
| CAP-AGT-03 | 三种路由模式：自动分配 / 强制指定 / 关闭 | P2 | 已有部分 | P1 | S |
| CAP-AGT-04 | 能力配置独立于导入目录，重导入不覆盖 | P2 | 存储分离 | P1 | S |
| CAP-AGT-05 | MCP 发现与展示（执行仍归目标应用） | P1+P2 | 已有 MCPModels | P2 | M |
| CAP-AGT-06 | Computer Use 桥接（复用目标原生执行器） | P2 | 不自建执行器 | P2 | XL |
| CAP-SES-01 | 浏览本地 Codex 会话与可见上下文 | P2 | 已有 SessionModels 脚手架 | P2 | L |
| CAP-SES-02 | 删除会话 | P2 | — | P2 | S |
| CAP-SES-03 | 扫描导入外部 Agent 会话 | P2 | JSONL/SQLite/MD 适配器 | P2 | XL |
| CAP-VOI-01 | STT（本地 Whisper / OpenAI 兼容 API） | P2 | 已有 VoiceModels 脚手架 | P2 | XL |
| CAP-VOI-02 | TTS（Edge / 火山 / MiniMax / OpenAI 兼容） | P2 | — | P2 | XL |
| CAP-VOI-03 | VAD、语音系统提示、HUD | P2 | — | P2 | XL |
| CAP-VOI-04 | 全局语音栏 | P2 | — | P2 | XL |
| CAP-VOI-05 | Realtime / GPT-Live 式任务委派 | P2 | 已有 TaskEnvelope 脚手架 | P2 | XL |

---

## 1.7 明确不做（OUT）

| 能力 | 来源 | 不做的理由 |
| --- | --- | --- |
| Windows / Linux 后台服务 | P3 | P1 是 macOS/iOS 原生应用，跨平台服务不在载体能力内 |
| Tauri / Electron 托盘伴侣 | P2/P3 | P1 自身就是原生菜单栏应用，重复 |
| 移动端独立网关 | P2 | P1 的 iOS 端定位为账号池查看器，不承载路由 |
| CLI 全量命令表面 | P3 | P1 是 GUI 应用；仅保留 `CopoolRouterHost` 作为运行时进程 |
| 托管式 Git checkout 自更新 | P3 | macOS 应用走签名分发 + Sparkle 式更新，不做 git 自更新 |
| LiteLLM 外部依赖 | P3 | P1 已有 Swift 原生协议适配层，不引入 Python/Node 依赖 |
| 唤醒词监听（Python） | P2 | 引入 Python 运行时与常驻麦克风，收益/成本比过低 |
| 伪造独立 Computer Use 执行器 | P2 | 安全红线：外部模型不得直接获得系统控制权 |

---

## 1.8 P0 范围的用户可见价值

| P0 能力簇 | 用户能做到的事 |
| --- | --- |
| CAP-PRV-01/05 + CAP-IDT-03 | 打开供应商页 → 选 DeepSeek → 填 Key → 启用 |
| CAP-CAT-01/02/09 | 模型自动出现在目录，测试连通性通过后才可用 |
| CAP-TGT-01/02/03/05/06 | 预览将要写入 Codex 配置的 diff → 应用 → 出问题一键回滚 |
| CAP-RTE-02/04 + CAP-PRO-* | 在 Codex 原生选择器里选中第三方模型，正常对话与工具调用 |
| CAP-OPS-01 | 出问题点 Doctor，看到具体哪一项 FAIL 与怎么修 |
| CAP-IDT-01/02 | 原有账号池能力完全不受影响 |

---

## 1.9 与旧 vNext 文档的关系

`docs/copool-vnext-reconstruction/` 共 32 篇、2,563 行，多数章节 15–50 行，属骨架级：

- **保留**：`11_data_model.md` 的 ProviderDefinition/ProviderInstance/CredentialIdentity 三层拆分结论（已落地为 `Sources/Copool/Domain/VNextRegistry.swift`）。
- **保留**：AC-005（ID 不派生自显示名）、AC-008（每目标独立状态目录）、AC-009（仅回环监听）三条不变量。
- **推翻**：`26_provider_matrix.md` 仅 33 行，未覆盖 P3 的 23 家供应商；本章 1.6 节 B 组取代之。
- **推翻**：`31_observability_and_doctor.md` 仅 29 行，无检查项清单；本文档集 08 章取代之。
- **补齐**：旧文档完全未覆盖 request profile（CAP-PRO-07）、凭据感知目录（CAP-CAT-01）、托管块（CAP-TGT-02）三项 P0 能力。

本文档集 `docs/copool-unified/` 为**当前唯一执行依据**；旧目录保留作历史参考，不再更新。
