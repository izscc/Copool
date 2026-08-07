# Copool UI/UX 打磨开发文档（B1–B4）

> 面向实现者。A 部分（分流韧性）已完成并合入，本文档只覆盖 B1–B4。
> 阅读顺序：先读「通用约束」，再按 B1 → B2 → B3 → B4 顺序实现。
> 每一节末尾的「完成判据」是验收标准，不满足即视为未完成。

---

## 0 · 通用约束

### 0.1 架构分层

```
Features → Behavior → Domain ← Infrastructure
```

单模块 Swift **不会**由编译器强制这个方向——违规也能编过。所以：

- `Domain/` 里的文件不得引用 `Behavior/`、`Infrastructure/`、`Features/` 的类型。
- 视图（`Features/`、`UI/`）只读 page model 的 `@Published` 属性，不直接碰 Infrastructure。
- 纯展示计算（格式化、聚合、排序）放 `Domain/`,便于单测；视图里只做布局。

已知既有违规（**不要顺手"修",不在本次范围**）：`Domain/AccountsModels.swift` 依赖 `Behavior/AccountIdentity`,`Domain/ProxyModels.swift` 依赖 `Behavior/RemoteServerConfiguration`。

### 0.2 并发

Swift 6 严格并发已开启。

- Domain 值类型：`Sendable`。
- Features/Behavior：`@MainActor`。
- 视图里的异步动作一律 `Task { await model.xxx() }`,不要在视图里自建 actor。

### 0.3 复用清单（**先查再写**）

写任何新组件前先确认这里没有现成的。重复实现一个已存在的组件会被打回。

| 需求 | 已有组件 | 路径 |
|---|---|---|
| 卡片容器 / 毛玻璃表面 | `SectionSurface`、`SectionCard`、`FrostedCapsuleSurfaceModifier` | `UI/SectionSurface.swift` |
| 空态 | `EmptyStateView(title:message:)` | `UI/EmptyStateView.swift` |
| 凭据五态徽标 | `CredentialStatusBadge(state:throttled:compact:)` | `UI/CredentialStatusBadge.swift` |
| 子 tab 胶囊栏 | `CapsuleSubTabBar` | `UI/CapsuleSubTabBar.swift` |
| 进度条 | `LiquidProgress` | `UI/LiquidProgress.swift` |
| 通知条 | `NoticeBanner` + `rootSceneNoticePresentation` | `UI/NoticeBanner.swift`、`RootScene.swift:97` |
| 间距 / 圆角 token | `LayoutRules`（`sectionSpacing`、`pagePadding` 等） | `UI/SectionSurface.swift` 同层 |
| 分组行 | `ProviderGroupSection` | `UI/ProviderGroupSection.swift` |
| 分流三态 | `ProviderSplitState`（`.active` / `.degraded` / `.inconsistent`） | `Domain/ProxyModels.swift:145` |
| 凭据健康 | `GroupViewData.health` / `.throttled` | `Domain/ProviderRegistryPresenter.swift:35` |

**禁止**新造视觉语言：不新增颜色常量、不新增圆角/间距数值、不引入新字体层级。一切从 `LayoutRules` 与既有组件取。

### 0.4 本地化（硬性）

所有用户可见文案走 `L10n.tr("key")`,**不允许**任何硬编码字面量。

新增键必须一次补齐 **11 个语言**:
`en` `zh-Hans` `ja` `ko` `de` `fr` `es` `nl` `it` `zh-Hant` `ru`
路径：`Sources/Copool/Resources/<locale>.lproj/Localizable.strings`

三个已踩过的坑：

1. **`.strings` 文件无结尾换行。** 用 shell `>>` 追加会把新键接到最后一行尾部,产生一条坏记录。必须用编辑器定位到最后一行,把新内容接在那一行之后。
2. **参数顺序可能随语言变化的必须用位置化说明符**:`"%1$@ · %2$@（%3$@）"`,不要用裸 `%@ · %@`。
3. **不要产生重复键。** 追加前先 `grep` 该键是否已存在。

补完自检（两条都必须通过）:

```bash
# 每个语言的新键数量一致
grep -c '^"<你的键前缀>' Sources/Copool/Resources/*.lproj/Localizable.strings
# 总键数 11 个语言完全相同（当前基线 826）
grep -c '^"' Sources/Copool/Resources/*.lproj/Localizable.strings
```

翻译要求：用目标语言的正字法,保留全部变音符号与特殊字符（`für` 不写成 `fur`,`não` 不写成 `nao`）。技术标识符（`config.toml`、`ChatGPT.app`、模型 ID）保持原文。

### 0.5 构建与验证

**当前环境完整构建跑不起来**:`xcode-select -p` 指向 `/Library/Developer/CommandLineTools`,缺 `SwiftUIMacros` 插件。先执行一次:

```
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

然后每完成一节跑:

```bash
swift build
```

在此之前只能做 Domain 层局部校验（注意要带上 0.1 提到的两个既有违规依赖,否则报的是无关错误）:

```bash
swiftc -typecheck -swift-version 6 Sources/Copool/Domain/*.swift \
  Sources/Copool/Behavior/AccountIdentity.swift \
  Sources/Copool/Behavior/RemoteServerConfiguration.swift
```

目视验证（每节都要）:面板固定宽度 **532pt**,在 `de` 与 `ru`（最长文案）下不得出现文字裁切、换行溢出或横向滚动。

### 0.6 提交纪律

- 不提交 commit,除非被明确要求。
- 不新建文档文件。
- 一节一次改动,不要把 B1–B4 混在一起。

---

## B1 · Models 页信息层级

### 现状

`Features/Providers/ProviderPageView.swift` 有 **1251 行**,是全项目最大的视图文件。内部结构（行号为当前值,实现时以实际为准）:

| 行 | 内容 |
|---|---|
| 5–125 | `ProviderPageView` 主壳:`SubTab` 枚举、`CapsuleSubTabBar`、四路 `switch`、两个 `.sheet`、`externalSessionBullets` |
| 127–243 | `providersContent`（providers 子 tab 的全部内容） |
| 245–826 | providers 子 tab 的私有子视图:`ProviderOnboardingSection`、`SubscriptionImportSection`、`ProviderPresetSection`、`ProviderListSection`、`ProviderModelRow`、`ProviderFormCard`、`ProviderUsageBlock`、`RateLimitLine`、`QuotaBar`、`ProviderCurationSection` |
| 828–1197 | routes 子 tab:`RoutesPolicySection`、`RouteDecisionRow`、`CandidateScoreRow`、`LabeledTraceRow` |
| 1199–1251 | `UsageSection` |

catalog 子 tab 已经独立在 `CatalogSection.swift`（522 行）,是本次拆分的参照样板。

### 任务

**B1-1 按子 tab 拆分文件。** 目标结构:

```
Features/Providers/
  ProviderPageView.swift          ← 只留主壳:SubTab、CapsuleSubTabBar、switch、sheet 装配
  ProviderPageView+Providers.swift ← providersContent + 上表 245–826 的子视图
  RoutesPolicySection.swift        ← 上表 828–1197
  UsageSection.swift               ← 上表 1199–1251
  CatalogSection.swift             ← 已存在,不动
```

关键点:

- 上述子视图目前是 `private struct`。跨文件后 `private` 不可见,改为**无修饰符**(module-internal)。不要改成 `public`。
- 拆分是**纯搬移**:不改任何布局、不改任何参数、不改任何文案。这一步的 diff 应当只有"删一处、加一处"。
- 主壳文件拆完应在 130 行以内。

**B1-2 收敛 sheet 装配。** 两个 `.sheet` 挂在同一层,`CredentialEntrySheet` 的参数列表有 8 个。把每个 sheet 的构造抽成主壳里的一个 `@ViewBuilder private func`,`.sheet` 里只调用它。行为不变。

**B1-3 统一空态。** 四个子 tab 的空态目前各写各的。全部改用既有 `EmptyStateView(title:message:)`。

- 若某处空态需要一个操作按钮（如"添加供应商"）,给 `EmptyStateView` 增加一个可选的 trailing action:`var actionTitle: String? = nil`、`var action: (() -> Void)? = nil`,仅在两者都非 nil 时渲染按钮（用 `SectionActionStyle`）。默认参数保证现有 5 处调用点不受影响。
- 不要为此新建第二个空态组件。

### 完成判据

- `ProviderPageView.swift` ≤ 130 行;新增 3 个文件,`wc -l` 之和与原文件相当（允许 ±20 行的 import/声明差异）。
- `swift build` 通过。
- 四个子 tab 的空态视觉一致,均来自 `EmptyStateView`。
- 无任何文案、间距、颜色变化——B1 是结构重构,不是视觉改动。

---

## B2 · 状态可见性

### 问题

用户要回答的两个问题目前要跨三个页面才能拼出来:**现在能不能用**、**不能用是为什么**。

三处分散的状态:

1. 代理运行态 —— 在 Proxy 页。
2. 凭据健康 —— 在 Models 页各分组行内,没有汇总。
3. 最近一次路由结果 —— 在 Models 页 routes 子 tab。

### 任务

在 Models 页顶部（`CapsuleSubTabBar` **之上**）加一条常驻状态摘要条。

**B2-1 数据源。** 三项都已存在,不要新建采集逻辑:

| 项 | 来源 | 说明 |
|---|---|---|
| 分流三态 | `ProxyRuntimeService.providerSplitState()` → `ProviderSplitState` | 已有协议方法（`Domain/Protocols.swift:150`,带默认实现）。经 `ProxyCoordinator.providerSplitState()`（`Behavior/ProxyCoordinator.swift:45`）取用 |
| 凭据健康计数 | `model.providerGroups` 的 `.health` / `.throttled` 聚合 | `GroupViewData` 字段已有（`Domain/ProviderRegistryPresenter.swift:41-42`） |
| 最近一次路由结果 | `model.recentRouteDecisions.first` | 已有 `@Published` |

`ProviderPageModel` 需要新增一个 `@Published var splitState: ProviderSplitState`,在 `loadProviders()` 与代理状态变化时刷新。注意 `providerSplitState()` 是 `async`,用 `Task { }` 桥到主线程赋值。

**B2-2 聚合计算放 Domain。** 新建 `Domain/ProviderStatusSummary.swift`:

```swift
struct ProviderStatusSummary: Equatable, Sendable {
    var splitState: ProviderSplitState
    var readyCount: Int
    var needsAttentionCount: Int   // unconfigured + expired + unauthorized
    var throttledCount: Int
    var verifyingCount: Int
    var lastRouteOutcome: RouteOutcome?   // 用 trace 已有的 outcome 类型

    static func build(
        splitState: ProviderSplitState,
        groups: [ProviderRegistryPresenter.GroupViewData],
        latestTrace: RouteDecisionTrace?
    ) -> ProviderStatusSummary
}
```

纯函数,无 IO,`Sendable`。这样这段规则可单测,而不必拉起整个视图。

**B2-3 视图。** 新建 `Features/Providers/ProviderStatusBar.swift`,输入就是 `ProviderStatusSummary`。

呈现原则（**照做,不要加指标**）:

- 一行,左侧一句结论,右侧计数徽标。用 `FrostedCapsuleSurfaceModifier`。
- 结论文案直接复用已有的 `proxy.split.state.*` 三个键（`active` / `degraded` / `inconsistent`）——**不要新造同义文案**。
- 计数只显示非零项,复用 `CredentialStatusBadge(compact: true)` 呈现每一类。
- 只报"能不能用"和"为什么不能",不显示吞吐、延迟、token 数这类指标。
- `.degraded` 态必须让用户看懂"原生 GPT 不受影响"——`proxy.split.state.degraded_help` 已有此文案,作为 help/tooltip 挂上。

**B2-4 可访问性。** 状态色不能是唯一区分手段——每个徽标都要有 `accessibilityLabel`,文本本身也要能独立表达状态（`CredentialStatusBadge` 已遵循此规则,照它的做法）。

### 完成判据

- Models 页四个子 tab 下摘要条都常驻可见。
- 手动制造 `.degraded`（停掉代理）与 `.inconsistent`（手工写托管块但不启代理）,摘要条文案正确切换。
- 无新增本地化键（全部复用 `proxy.split.state.*` 与 `credentials.health.*`）。若确实需要新键,按 0.4 补齐 11 语言。
- `ProviderStatusSummary.build` 有单测覆盖:五种健康态混合、三种分流态、`latestTrace` 为 nil。

---

## B3 · 首次使用引导

### 问题

`providers.onboarding.*` 共 5 个键（`title`、`subtitle`、`step1`、`step2`、`step3`）在 **11 个语言里全是英文**——包括 `zh-Hans`。当前值:

```
title    = "Add third-party models"
subtitle = "Use your own providers inside ChatGPT.app — no API key needed if you import a local subscription."
step1    = "Add an API key or import a local subscription login."
step2    = "Pick the models you want to use."
step3    = "Restart ChatGPT.app — models appear in its menu."
```

两个问题:

1. **未翻译。** 中文用户第一眼看到的就是英文。
2. **与实际路径脱节。** step3 说"重启 ChatGPT.app",但没说清在哪一步、也没提代理必须在跑。用户照做会发现模型没出现。

### 任务

**B3-1 核准真实路径。** 实现前先读代码确认实际步骤顺序,不要照抄本文档的推测。要确认的点:

- 加完凭据后,模型是否需要在 catalog 子 tab 显式勾选才会出现在 ChatGPT.app?（看 `ProviderPageModel+Catalog.swift` 的 visibility 逻辑）
- 托管配置何时写入 `config.toml`?（看 `CodexModelsCacheService.applyProxyRouting(port:)` 的调用时机）
- 代理必须处于运行态才有第三方模型——这一条要不要进引导?（A 部分已确立:是,`.degraded` 下第三方模型不可用）

**B3-2 重写三步文案**,每一步必须落到界面上的具体位置（哪个 tab、哪个按钮）。保持三步——不要扩成五步,首次引导越长完成率越低。

**B3-3 补齐 11 语言。** 按 0.4 执行,含 `zh-Hans`。

**B3-4 引导消失条件。** 确认引导在什么条件下隐藏（当前应是"已有 provider 配置"）。若条件是"永久 dismiss",要能在无 provider 时重新出现——否则用户删完 provider 就再也看不到引导。

### 完成判据

- 11 个语言各自都是本地语言,`grep '"providers.onboarding' <locale>` 无英文残留（`en` 除外）。
- 三步文案与实际操作路径逐条对应,照做能成功让第三方模型出现在 ChatGPT.app 菜单里（需人工走一遍）。
- 在 `de` / `ru` 下 532pt 宽度不裁切。

---

## B4 · 账号卡片与用量

**优先级最低,排在 B1–B3 全部完成之后。** 若时间受限,此节可单独延后。

### 任务

**B4-1 账号卡片密度。** `Features/Accounts/AccountsPageSections.swift`（533 行）与 `AccountCardPrimitives.swift`（432 行）。

- 统一卡片内边距与行距,全部取 `LayoutRules` token,清掉散落的字面量数值。
- 进度条统一走 `LiquidProgress`;确认"已用/剩余"两种显示模式（`settings.usage_progress_display`）在所有卡片上一致生效。

**B4-2 用量数字对齐。** `UsageSection`（B1 拆出的新文件）。

- 数字列右对齐,用等宽数字字体特性（`.monospacedDigit()`）,避免刷新时数字跳动。
- 聚合数字与卡片内的单项数字口径一致——若不一致,以 ledger 聚合为准。

**B4-3 不做的事。** 不改用量的计算口径、不改采集逻辑、不加新图表。这一节纯视觉收敛。

### 完成判据

- 卡片与用量区无硬编码间距/圆角字面量。
- 数字刷新时不发生横向跳动。
- `swift build` 通过,视觉在 11 语言下无裁切。

---

## 附:审核会重点看的点

1. **有没有重复实现 0.3 清单里已存在的组件。**
2. **本地化是否 11 语言齐平**——`grep -c '^"'` 必须完全相同。
3. **B1 是否真的只是搬移**——出现布局或文案改动即为超范围。
4. **Domain 层是否被引入新的向上依赖**（引用了 Behavior/Infrastructure/Features 的类型）。
5. **状态色是否是唯一区分手段**（可访问性）。
6. **是否新造了视觉常量**（颜色、圆角、间距字面量）。
7. **`.strings` 文件是否出现重复键或被追加坏的行**（无结尾换行导致的粘连）。
