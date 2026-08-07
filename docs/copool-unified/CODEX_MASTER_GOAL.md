# CODEX_MASTER_GOAL · 总目标 Prompt

> 这份文件是交给 Codex 的**总纲**。开始任何一个里程碑之前先读它，再读对应的里程碑 prompt（`CODEX_TASK_PROMPTS.md`）。

---

## 你的身份与任务

你在 **Copool** 仓库工作——一个 Swift 6 + SwiftUI 的 macOS/iOS 原生菜单栏应用，当前约 38,666 行 Swift。

**总目标**：把两个外部项目的能力科学地整合进本应用：

- **OpenCodex**：协议适配语义、本机订阅导入、Agent 路由、会话中心、语音
- **codex-router**：供应商注册表、凭据隔离、目录合并、Doctor、配置回滚

整合后的产品定位：**macOS 上的本地模型路由控制台**——让 Codex、Cursor、opencode 等客户端在不改变自身使用方式的前提下，用上任意已授权的模型。

---

## 唯一执行依据

`docs/copool-unified/` 是**当前唯一的执行依据**：

| 文档 | 内容 |
| --- | --- |
| `01-scope-and-capability-matrix.md` | 范围契约、~70 条能力矩阵（CAP-\*） |
| `02-requirements-identity-provider-catalog.md` | 身份/凭据/供应商/目录需求（FR-IDT/PRV/CAT-\*） |
| `03-requirements-targets-routing-runtime.md` | 目标/路由/协议/运行时需求（FR-TGT/RTE/PRO/RUN/DOC-\*） |
| `04-requirements-agents-sessions-voice.md` | Agent/会话/语音需求（FR-AGT/SES/VOI-\*），**P1/P2** |
| `05-information-architecture.md` | 导航与 UI 硬约束（IA-\*、DNA-1..5） |
| `06-screen-specifications.md` | 逐屏与组件规格（SCR-\*、CMP-\*） |
| `07-domain-model-storage-migration.md` | 数据模型与迁移（DM-\*、MIG-\*、INV-1..3） |
| `08-architecture-security-observability.md` | 架构/安全红线/可观测（ARC-\*、**SEC-\***、OBS-\*） |
| `09-test-strategy-acceptance.md` | 测试与验收（TST-\*、AC-\*） |
| `10-delivery-plan-milestones-risks.md` | 里程碑与风险（MS-\*、RISK-\*） |
| `seed/provider-registry-seed.json` | 23 家供应商 + 48 个模型 + 11 个 request profile 的种子数据 |

`docs/copool-vnext-reconstruction/` 是**历史参考**，不再更新，冲突时以 `copool-unified/` 为准。

---

## 十二条安全红线（不可协商）

实现与它们冲突时，**改实现，不改红线**。完整表述见 `08-architecture-security-observability.md` 的 SEC-01..12。

1. **SEC-01** 秘密只进 Keychain。落盘只有 `SecureReference{storage, name}`。不进日志、不进支持包、不进崩溃报告。Keychain 写失败 → 报错中止，**不降级为明文**。
2. **SEC-02** 所有监听器绑 `127.0.0.1`。启动时断言，非回环拒绝启动。
3. **SEC-03** 每个请求校验 `Authorization: Bearer <callerCapability>`。回环 ≠ 安全。
4. **SEC-04** 出站请求头走**白名单**。剥离所有 ChatGPT/Codex 身份信息（account id、session id、installation id、device id、attestation、`originator`、`chatgpt-*`、`openai-*`）。
5. **SEC-05** 绝不结束/重启目标应用进程。重启交还用户。
6. **SEC-06** 不删除用户数据。目标配置改动全部可逆（托管块 + 备份 + 回滚）。不删第三方 CLI 的原始登录态。
7. **SEC-07** 付费冒烟测试默认关闭，每次执行需二次确认。
8. **SEC-08** 读第三方登录态前必须走披露确认，默认不勾选，无"不再提示"。
9. **SEC-09** 不自建 Computer Use 执行器。外部模型不得直接获得系统控制权。
10. **SEC-10** 麦克风活跃时菜单栏持续指示。不做唤醒词常驻监听。
11. **SEC-11** Body 双重限制：编码前 64 MiB、解码后 256 MiB（防解压炸弹）。
12. **SEC-12** 公网隧道是 SEC-02 的唯一例外，需醒目警告 + 强制 capability 校验。

**Clean-room 约束**：可以借用产品语义与对外事实（provider id、baseURL、环境变量名、模型上下文窗口、托管块标记格式）；**不得复制** OpenCodex/codex-router 的源码结构、UI 布局、产品文案、品牌名。Swift 侧全部原创实现。

---

## 五条 UI 不可变约束

来自 `05-information-architecture.md` 的 DNA-1..5：

1. **面板宽度锁死 532pt**（`LayoutRules` 中 min == default == max == `accountsPageTargetWidth`）。
2. **顶层导航恒为 5 个 tab**（`tabSwitcherMaxWidth = 260`，已占满）。所有扩容走二级 `CapsuleSubTabBar`。
3. **高度 520 / 620 / 760**。
4. **间距、圆角、色值一律走 `LayoutRules`**，页面里不写魔法数字。
5. **材质用 `SectionSurface` 系列修饰器**，不直接写 `.background(.regularMaterial)`。

扩容手法按优先级：分组折叠 → `SectionCard` 分区 → 行内展开 → Sheet → 专家模式。
**禁止**：横向滚动、tooltip 塞内容、字号小于 `.caption2`、新开独立窗口。

---

## 三条数据不变量

1. **INV-1** 秘密不进任何 `Codable`、日志、支持包。
2. **INV-2** 任何 ID 不从 `displayName` 派生（AC-005）。
3. **INV-3** `ModelCatalogEntry.id == "\(providerInstanceID)/\(backendModelID)"`（AC-011）。

---

## 工程约定

- **语言**：所有注释、文档、commit message、用户可见文案用**简体中文**；类型名、方法名、变量名、provider id、model id 保持英文。
- **注释密度**：与周围代码保持一致——现有代码是"关键决策处写一段 `///` 说明为什么"，不是逐行注释。照做。
- **并发**：Domain 层纯 `Sendable` 值类型无 IO；Behavior 层 `@MainActor`；Infrastructure 用 `actor` 或 `final class + NSLock` + `@unchecked Sendable`。
  **持锁方法不得调用另一个持锁方法**——`NSLock` 不可重入。需要复用时抽 `xxxLocked()` 私有方法。
- **依赖方向**：`Features → Behavior → Domain ← Infrastructure`。Domain 不 import Infrastructure。
- **落盘**：JSON 走原子写（临时文件 + `replaceItemAt`）。写失败必须冒泡为可见错误，不静默吞掉。
- **本地化**：所有用户可见文案走 `L10n.tr(...)`，中英双份，不留硬编码字符串。中文文案要完整——不允许英文导航项或英文术语混排。
- **错误文案三段式**：发生了什么 + 为什么 + 怎么办。

---

## 工作方式

1. **先读文档再动手**。开始一个里程碑前读完对应章节，不要凭印象实现。
2. **先写测试再改既有行为**。以下三处是明确的行为变更，必须先有失败的测试：
   - `TargetConfigFileAdapter.plan(to:)` 死锁修复（M0）
   - 推理档位不再兜底猜测（M2）
   - 路由解析去掉全目录兜底（M4）
3. **每个里程碑独立可发布**。不允许"做完 M3 才能验证 M2"。
4. **现有 47 个测试文件必须保持绿色**。`Accounts*Tests`（10 个文件）**不允许修改断言**——账号池零回归是硬门槛。
5. **完成一个任务就跑一次构建与测试**，不要攒到最后。
6. **遇到文档没覆盖的决策**：按最保守、最可逆、最可解释的方向选，并在 commit message 里说明。不要自行扩大范围。

---

## 已知的既有缺陷（M0 必须修）

1. **死锁**：`Sources/Copool/Infrastructure/TargetConfigFileAdapter.swift:43-52`，`plan(to:)` 持 `lock` 时调用了两次 `detect()`，而 `detect()` 也 `lock.lock()`。`NSLock` 不可重入。
2. **误判**：同文件 `verify(_:)` 用全文相等比较，应只比托管块区间。
3. **无主对象**：`Sources/Copool/App/AppContainer.swift:113-119` 构造的 `TaskEnvelopeDispatcher` 与 `RemoteNodeControlService` 从未被消费。P0 交付里移除构造。
4. **组件不一致**：`ProviderPageView.swift:22-28` 用原生 `Picker(.segmented)` 做二级导航，应改用仓库自带的宽度安全组件 `CapsuleSubTabBar`。
5. **死代码**：`ProviderPageView.swift:733-736` 的 `ProviderCurationSection.discoverableModels` 恒返回 `[:]`，无人调用。

---

## 交付顺序

```
M0 地基与护栏   → M1 供应商注册表 → M2 模型目录
                                      ↓
M3 目标绑定 ────────────────────────→ M4 路由与协议
                                      ↓
                              M5 运行时与 Doctor → M6 迁移与打磨
                                      ↓
                        M7（P1/P2）Agent / 会话 / 语音，价值验证后再启动
```

**M0–M6 = P0 交付**。逐个里程碑执行，每个里程碑的详细任务与验收见 `CODEX_TASK_PROMPTS.md`。

---

## 成功的定义

用户打开 Copool → 供应商页看到 23 家内置供应商 → 选 DeepSeek 填一次 Key → 模型自动出现在目录 → 到运行时页预览 diff 并应用到 Codex → 重启 Codex → 在原生模型选择器里选中 DeepSeek 并正常对话。

**全程 ≤ 4 步，配置全部可回滚，出问题点 Doctor 能看到具体哪项 FAIL 与怎么修。**
