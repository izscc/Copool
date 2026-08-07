# 05 · 信息架构与导航

> 本章是 **UI 扩容的硬约束文件**。P1 的界面 DNA 必须完整保留；所有新增功能都要在既有规则内找位置，不允许突破。
> 编号规则：`IA-<序号>`。

---

## 5.1 不可变更的界面 DNA

以下五条来自 P1 现有实现，**本次整合一律不得改动**：

| # | 约束 | 依据 |
| --- | --- | --- |
| DNA-1 | 面板宽度**锁死 532pt** | `LayoutRules.minimumPanelWidth == defaultPanelWidth == maximumPanelWidth == accountsPageTargetWidth`（= 250×2 + 行距 + 16×2） |
| DNA-2 | 顶层导航**恒为 5 个 tab** | `tabSwitcherMaxWidth = 260`，5 个图标已占满 |
| DNA-3 | 高度受限 **520 / 620 / 760** | `minimum/default/maximumPanelHeight`；菜单栏面板不能无限长 |
| DNA-4 | 所有间距、圆角、色值走 `LayoutRules` 与 `SectionSurface` | 不允许在页面里写魔法数字 |
| DNA-5 | 材质统一用 `frostedRoundedSurface` / `cardSurface` 系列 | 不允许直接写 `.background(.regularMaterial)` |

**推论**：532pt 宽、最多 760pt 高的画布，要装下 23 家供应商 + 48 个模型 + 3 个目标绑定 + Doctor + 路由 trace。唯一可行的扩容方向是**纵向分层**，不是横向铺开。

---

## 5.2 顶层导航（IA-01）

**保持 5 个 tab 不变**：

| Tab | 图标 | 职责 | 本次变化 |
| --- | --- | --- | --- |
| `accounts` | `person.2` | ChatGPT/Codex 账号池 | **零变化**（FR-IDT-01） |
| `proxy` | `network` | 运行时、目标绑定、Doctor、用量 | 大幅扩容 |
| `providers` | `square.stack.3d.up` | 供应商、凭据、模型目录 | **大幅扩容（本次重点）** |
| `agents` | `point.3.connected.trianglepath.dotted` | Agent、会话、语音 | P1/P2，本轮小改 |
| `settings` | `gearshape` | 全局设置 | 增加高级区 |

iOS 端维持 `[.accounts, .proxy]` 两个 tab（`RootScene.visibleTabs`），不承载供应商配置——手机上配 23 家 provider 不是合理场景。

**IA-01 验收**：`AppTab.allCases.count == 5` 写成单测断言，防止后续有人"顺手加一个 tab"。

---

## 5.3 二级导航统一（IA-02）

**现状问题**：`ProviderPageView` 用原生 `Picker(.segmented)` 做 4 个二级 tab（`ProviderPageView.swift:22-28`），而仓库里已经有专为窄面板写的 `CapsuleSubTabBar`（`Sources/Copool/UI/CapsuleSubTabBar.swift`），其文档注释明确写着：原生 segmented picker 按标签固有宽度分配空间，**5 个标签会超出 500pt 内容区**。

**决议**：所有二级导航一律改用 `CapsuleSubTabBar`。`ProviderPageView` 的 segmented Picker 在 M2 替换。

`CapsuleSubTabBar` 的既有参数保持不变：`spacing: 3`、`padding(3)`、`minimumScaleFactor(0.65)`、未选中填充 `Color.primary.opacity(0.05)`、选中填充 `Color.accentColor.opacity(0.16)`。

**二级 tab 数量上限：5 个**。超过 5 项的分组必须改用页内分区（`SectionCard`）或 sheet，不得靠缩小字号硬塞。

---

## 5.4 各页二级结构

### IA-03 · Providers 页（供应商）

```
[ 供应商 | 目录 | 路由 | 用量 ]          ← CapsuleSubTabBar，4 项
```

| 二级 tab | 内容 | 对应需求 |
| --- | --- | --- |
| **供应商** | 内置 23 家分组列表 + 自定义 + 凭据状态 | FR-PRV-01..06, FR-IDT-02..08 |
| **目录** | 凭据感知模型目录、搜索、隐藏、策展 | FR-CAT-01..09 |
| **路由** | 路由决策 trace 列表 | FR-RTE-05 |
| **用量** | 限流、余额、7 日 token 趋势 | FR-RUN-04, FR-RUN-05 |

现有 4 个二级 tab 与本设计**完全吻合**，无需增减，只需替换组件与填充内容。

---

### IA-04 · Proxy 页（运行时）

```
[ 总览 | 目标 | 诊断 | 远程 ]            ← CapsuleSubTabBar，4 项
```

| 二级 tab | 内容 | 对应需求 |
| --- | --- | --- |
| **总览** | 运行状态、端口、开机自启、快捷开关 | FR-RUN-01/03，保留现有总览内容 |
| **目标** | codex / cursor / opencode 绑定卡片、diff 预览入口、回滚 | FR-TGT-01..08 |
| **诊断** | Doctor 分类检查结果 + 修复动作 | FR-DOC-\* |
| **远程** | Cloudflared 隧道 + 远程 Linux 节点 | CAP-RUN-05/06，保留现有 |

---

### IA-05 · Agents 页

```
[ Agent | 会话 | 语音 ]                  ← CapsuleSubTabBar，3 项
```

会话与语音在 P2 落地前显示为"即将推出"的占位说明，**不显示可点击但无效的控件**。

---

### IA-06 · Settings 页

单页滚动，分区用 `SectionCard`：外观 / 语言 / 运行时 / **高级** / 关于。

**高级区**是危险开关的唯一归属地：兼容性冒烟测试（付费）、公网隧道、重新生成 capability token、导出支持包。该区默认折叠。

---

## 5.5 扩容手法（IA-07）

532pt 画布内，按以下优先级选择承载方式：

| 手法 | 适用 | 示例 |
| --- | --- | --- |
| ① **分组折叠列表** | 同类项数量多 | 23 家 provider 按"已配置 / 内置 / 自定义"三组，默认只展开"已配置" |
| ② **`SectionCard` 分区** | 页内并列的不同关注点 | Doctor 的 7 个检查分类 |
| ③ **行内展开（disclosure）** | 详情属于某一行 | 点开某个 provider 看它的模型与用量 |
| ④ **Sheet** | 需要专注、有确认动作 | 凭据录入、diff 预览、导入披露 |
| ⑤ **专家模式开关** | 高级用户才需要的密度 | 目录页显示原始 model ID、显示 metadata 来源 |

**禁止**：横向滚动、把内容塞进 tooltip、缩小字号到 `.caption2` 以下、新开独立窗口（语音栏除外）。

---

## 5.6 关键流程的导航路径（IA-08）

**主流程：从零到用上 DeepSeek（≤ 4 步，01 章成功指标）**

```
1. Providers → 供应商 → 内置分组里点「DeepSeek」
2. 弹出凭据 Sheet → 粘贴 Key → 保存        （FR-IDT-02）
3. 卡片变「就绪」，模型自动进目录            （FR-CAT-01）
4. Proxy → 目标 → codex 卡片「应用配置」→ 预览 diff → 确认   （FR-TGT-04）
   → 提示「请重启 Codex」                   （FR-TGT-08）
```

**排障流程**

```
Proxy → 诊断 → 看到具体 FAIL 项 → 点修复动作
                            ↓（若与路由有关）
              Providers → 路由 → 展开 trace 看淘汰原因
```

**回滚流程**

```
Proxy → 目标 → codex 卡片 → 「回滚到上一次」→ 确认 → 提示重启
```

---

## 5.7 状态与徽章语言（IA-09）

全应用统一，不允许各页自创：

| 状态 | 颜色 | 图标 | 用于 |
| --- | --- | --- | --- |
| 就绪 / 通过 | `.green` | `checkmark.circle.fill` | 凭据、连通性、Doctor |
| 警告 / 需注意 | `.orange` | `exclamationmark.circle.fill` | 限流、配置过期、beta |
| 失败 / 错误 | `.red` | `xmark.circle.fill` | 鉴权失败、Doctor FAIL |
| 未配置 / 未测试 | `.secondary` | `circle.dotted` | 初始态 |
| 进行中 | — | `ProgressView().controlSize(.small)` | 测试、刷新、应用 |

现有 `ProviderModelRow.statusIcon`（`ProviderPageView.swift:446-459`）已符合此规范，作为参照实现。

---

## 5.8 空态与首次使用（IA-10）

每个二级 tab 都必须有明确空态，**空态要能直接引导到下一步动作**，不能只写"暂无数据"。

现有 `ProviderOnboardingSection` 的三步引导卡片是良好范例（标题 + 副标题 + 编号步骤 + 主行动按钮 + `frostedRoundedSurface(tint: .indigo)`），新增空态沿用该结构。

---

## 5.9 本章约束回溯

| ID | 约束 | 影响的需求 |
| --- | --- | --- |
| IA-01 | 顶层恒 5 tab | 全部 UI 需求 |
| IA-02 | 二级导航统一 `CapsuleSubTabBar`，≤ 5 项 | FR-PRV, FR-CAT, FR-TGT, FR-DOC |
| IA-03..06 | 各页二级结构 | 同上 |
| IA-07 | 五种扩容手法，禁横向滚动 | 全部 |
| IA-08 | 主流程 ≤ 4 步 | 01 章成功指标 |
| IA-09 | 统一状态语言 | 全部 |
| IA-10 | 空态必须可引导 | 全部 |
