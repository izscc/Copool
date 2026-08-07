# 04 · 功能需求：Agent、会话、工具与语音

> 覆盖能力矩阵 E 组（CAP-AGT-\* / CAP-SES-\* / CAP-VOI-\*）。
> **本章整体为 P1/P2 优先级**，不在 P0 交付范围内。写在这里是为了锁定语义边界与安全约束，防止后续实现时走偏。
> 现有代码中的 `VoiceModels.swift`、`SessionModels.swift`、`TaskEnvelopeDispatcher` 均为**脚手架**——有类型定义、无实际驱动方。

---

## 4.1 优先级立场

P2 的三项能力（会话中心、语音、Computer Use）复杂度均为 XL，且**都不是"让第三方模型能用起来"这条主线的必需项**。

判断依据：一个用户装 Copool 的理由是"我想在 Codex 里用 DeepSeek"。语音和会话浏览不解决这个问题。因此本章能力**一律排在 P0 全部完成之后**，且允许按实际价值反馈裁剪。

已经存在的脚手架代码有两条出路：接线到真实实现，或按 FR-RUN-07 移除。**不允许长期保留"看起来能用但其实是空壳"的状态**。

---

## 4.2 Agent 与工具（FR-AGT-\*）

**FR-AGT-01 · Agent Profile**（CAP-AGT-01，P1）

一个 Agent Profile 描述一个可被委派任务的执行单元：

| 字段 | 语义 | 用户可编辑 |
| --- | --- | --- |
| `id` | 稳定标识（UUID，不派生自名称） | 否 |
| `displayName` | 显示名 | 是 |
| `capabilityDescription` | **用户自己填写的能力说明** | 是 |
| `defaultModelEntryID` | 默认使用的模型条目 | 是 |
| `defaultReasoningEffort` | 默认推理档位 | 是 |
| `enabled` | 是否参与自动路由 | 是 |

已有 `AgentModels` 与 `AgentPageModel` / `AgentPageView` 承载基础形态，本次补齐 `capabilityDescription` 与路由接线。

---

**FR-AGT-02 · 按用户填写的能力说明路由**（CAP-AGT-02，**P1，语义红线**）

子任务分派给哪个 Agent，**只依据用户填写的 `capabilityDescription`**。

**明令禁止**：根据模型名推断能力（"名字里有 coder 所以适合写代码"、"opus 所以适合难题"）。理由与 FR-CAT-05 同源——猜测出来的能力画像无法向用户解释，出错时用户无从排查。

`AgentTaskRouter`（已有）的输入必须是能力说明文本 + 任务描述，输出是选中的 Agent + **可展示的选择理由**。选择理由必须能在 UI 上呈现。

---

**FR-AGT-03 · 三种路由模式**（CAP-AGT-03，P1）

| 模式 | 行为 |
| --- | --- |
| `自动分配` | 按 FR-AGT-02 选择 |
| `强制指定` | 全部子任务发给指定 Agent |
| `关闭` | 不做 Agent 分派，请求直达默认模型 |

默认 `关闭`——不主动改变用户既有的使用方式。

---

**FR-AGT-04 · 能力配置独立于导入目录**（CAP-AGT-04，P1）

用户填写的 `capabilityDescription` 存在独立文件（`agents.json`），与从外部导入的 Agent 目录（`agent-routes.json`）分离。重新导入目录**不得覆盖**用户填写的能力说明——匹配以 `id` 为准，只更新导入侧字段。

---

**FR-AGT-05 · MCP 发现与展示**（CAP-AGT-05，P2）

Copool 可以**发现并展示**目标应用配置的 MCP server 清单（读 `~/.codex/config.toml` 的 mcp 段），用于让用户看清当前环境有哪些工具可用。

**Copool 不执行 MCP 调用、不代理 MCP 流量、不修改 MCP 配置**。工具执行归目标应用所有。

---

**FR-AGT-06 · Computer Use 桥接**（CAP-AGT-06，**P2，安全红线**）

若实现，唯一合法形态是：**把请求转交给目标应用自带的执行器**，由目标应用在其既有的权限模型与用户确认流程下执行。

**绝对禁止**：Copool 自建屏幕截图、鼠标键盘注入、或任何形式的系统控制执行器。理由——那等于让任意配置进来的第三方模型直接获得本机控制权，而用户配置一个模型时并不预期授予这种权限。

若无法通过目标应用的原生执行器实现，则**放弃该能力**，不做替代方案。

---

## 4.3 会话中心（FR-SES-\*）

**FR-SES-01 · 浏览本地会话**（CAP-SES-01，P2）

已有 `SessionIndexRepository.sync()` 读取 `~/.codex/session_index.jsonl`。补齐：列表 UI、按时间/项目筛选、查看单次会话的可见上下文。

只读展示，**不修改会话文件**。

---

**FR-SES-02 · 删除会话**（CAP-SES-02，P2）

删除前必须二次确认并明示"这会删除磁盘上的会话文件，不可恢复"。默认不提供批量删除。

---

**FR-SES-03 · 外部 Agent 会话导入**（CAP-SES-03，P2）

`SessionImportAdapter` 协议已定义，当前只有 `JSONLSessionImportAdapter`。若实现，需补 SQLite 与 Markdown 适配器。

导入前必须展示 `SessionImportPreview`（来源、条数、时间跨度）。导入是**复制**而非移动，源文件不动。

---

## 4.4 语音（FR-VOI-\*）

**整体 P2。以下为实现时的约束，不构成本轮交付承诺。**

**FR-VOI-01 · STT**（CAP-VOI-01，P2）

两条路径：本机模型（macOS 原生 `SFSpeechRecognizer` 或本地 Whisper）与 OpenAI 兼容的转写 API。默认使用**本机**路径——语音数据不出本机是合理默认。

使用 API 路径必须显式选择，且在设置页明示"你的语音将被发送到 <provider>"。

---

**FR-VOI-02 · TTS**（CAP-VOI-02，P2）

支持系统语音合成与 OpenAI 兼容 TTS。同样默认本机优先。

---

**FR-VOI-03 · 麦克风权限与状态可见性**（CAP-VOI-03，P2，**隐私红线**）

- 首次使用前走系统权限请求，说明文案必须准确描述用途。
- 麦克风处于活跃采集状态时，菜单栏图标必须有**持续可见**的指示。不允许无指示的后台采集。
- 提供全局"停止采集"，一键生效。
- **不实现唤醒词常驻监听**（01 章已列为 OUT）。

---

**FR-VOI-04 · 全局语音栏**（CAP-VOI-04，P2）

若实现，作为独立的浮动窗口，不占用主面板的 532pt 宽度预算（见 05 章导航约束）。

---

**FR-VOI-05 · 实时任务委派**（CAP-VOI-05，P2）

`TaskEnvelope` 已实现完整的确认/拒绝门（AC-203）。该门是**必需的**：语音识别有误识别率，未经确认就执行的委派会造成用户没有下达过的操作。

- 每个 envelope 必须经用户确认才进入执行。
- 确认界面展示识别出的原文与将要执行的动作。
- 无人确认的 envelope 超时自动作废（默认 60s），**不默认执行**。

`InMemoryRealtimeTransport`（`VoiceModels.swift:75`）是测试替身，实现时须替换为真实传输，并保留内存实现供单测使用。

---

## 4.5 本章需求 → 能力矩阵回溯表

| 需求 | 能力 ID | 优先级 |
| --- | --- | --- |
| FR-AGT-01 | CAP-AGT-01 | P1 |
| FR-AGT-02 | CAP-AGT-02 | P1 |
| FR-AGT-03 | CAP-AGT-03 | P1 |
| FR-AGT-04 | CAP-AGT-04 | P1 |
| FR-AGT-05 | CAP-AGT-05 | P2 |
| FR-AGT-06 | CAP-AGT-06 | P2 |
| FR-SES-01 | CAP-SES-01 | P2 |
| FR-SES-02 | CAP-SES-02 | P2 |
| FR-SES-03 | CAP-SES-03 | P2 |
| FR-VOI-01..05 | CAP-VOI-01..05 | P2 |
