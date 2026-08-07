# 09 · 测试策略与验收矩阵

> 编号规则：`TST-<序号>` 测试要求，`AC-<序号>` 验收条件。
> 现有 47 个测试文件全部保持绿色是**准入门槛**，不是目标。

---

## 9.1 测试分层

| 层 | 覆盖对象 | 数量目标 | 现状 |
| --- | --- | --- | --- |
| **纯域单测** | Domain 层值类型与纯函数 | 新增功能 100% | `RoutePolicyTests`、`SessionAndTargetTests` 等已覆盖部分 |
| **契约测试** | 适配器、协议转换 | 每个适配器 6 方法各 1 例 | `TargetConfigContractTests`、`CanonicalContractTests` 已有骨架 |
| **仓库/IO 测试** | 文件读写、迁移 | 全部落盘路径 | `ProviderFileRepositoryTests`、`VNextRegistryMigrationTests` 已有 |
| **展示逻辑测试** | PageModel 状态推导 | 每个新页面 | `ProxyPageModelTests`、`SettingsPageModelTests` 是范例 |
| **本地化一致性** | 中英文案完整性 | 全量 | `LocalizationConsistencyTests` 已有，新增 key 自动纳入 |
| **布局约束测试** | LayoutRules 不变量 | 全量 | `LayoutRulesTests` 已有 |
| **冒烟测试** | 应用能启动、能构建视图 | 1 例 | `AppSmokeTests` 已有 |

**不做**：UI 自动化测试（SwiftUI 的 UI 测试成本高、脆弱，性价比低于展示逻辑测试 + 人工核对）。

---

## 9.2 必须新增的测试

### TST-01 · 种子数据完整性（P0）

```
断言 provider 数量 == 23
断言 provider id 全局唯一
断言除 kimi-oauth/grok-oauth 外，defaultBaseURL 均以 "https://" 开头
断言 catalog 条目数 == 48
断言每个 catalog.provider 都能在 definitions 中找到
断言 ModelCatalogEntry.id 全局唯一
断言 autoCompact < contextWindow（对所有声明了两者的条目）
断言每个 requestProfile 引用都能在 requestProfiles 中找到
断言种子 JSON 能被解码为强类型，无字段丢失
```

这一组是**构建期护栏**——种子数据是手写 JSON，没有编译器保护，只能靠测试。

### TST-02 · 秘密不泄露（P0，INV-1）

```
构造含凭据的完整注册表 → 编码为 JSON → 断言产物中不含：
  - "sk-" 前缀字符串
  - 任何测试用的假 key 值
  - "Bearer " 后跟非空内容
对 RouteDecisionTrace、UsageEvent、SupportBundle 重复同样断言
```

### TST-03 · ID 稳定性（P0，INV-2 / AC-005）

```
创建 ProviderDefinition/Instance/CredentialIdentity/ModelCatalogEntry
→ 修改所有 displayName
→ 断言所有 id 字段逐一不变
```

### TST-04 · 托管块逐字节可逆（P0，FR-TGT-02）

```
准备含 50 行用户自定义内容的 config.toml（含注释、空行、中文、特殊字符）
→ apply → uninstall
→ 断言文件内容与初始逐字节相等（含尾部换行）
```

再加三个边界：

- 标记不成对 → 断言操作被拒绝且文件未改动
- 同名托管块出现 3 次 → 断言全部剥离后只剩 1 个
- 目标文件不存在 → 断言 apply 能创建，uninstall 不报错

### TST-05 · `TargetConfigFileAdapter` 死锁回归（P0）

```
调用 plan(to:) → 断言在 1 秒内返回（当前实现会死锁）
```

这是 03 章 FR-TGT-01 记录的既有缺陷，必须先写测试再修。

### TST-06 · 凭据感知目录（P0，FR-CAT-01）

```
provider 有凭据 → 断言其模型在目标目录中
删除最后一个凭据 → 重建目录 → 断言其模型全部消失
provider 停用 → 断言其模型消失
模型 hidden → 断言不在目标目录，但仍在 UI 目录中
```

### TST-07 · 路由解析优先级（P0，FR-RTE-02）

```
精确 id 匹配 → 命中
别名匹配 → 命中，selectionKind == .alias
后端 ID 多条匹配 → 进打分器
完全不匹配 → 断言返回 nil 且 ledger 中有失败 trace
```

第四条是**行为变更**（现状是全目录兜底），必须有测试锁定新行为。

### TST-08 · 失败分类（P0，FR-RTE-04）

7 类失败各一例，断言：是否重试、重试次数、是否换账号、是否标记凭据失效。

**重点**：401 断言零重试；SSE 中断后断言零重试。

### TST-09 · Request profile 应用（P0，FR-PRO-05）

```
dashscope-compatible → 断言原生 thinking 字段被剥离，enable_thinking 被添加
kimi-k3 → 断言 effort 被强制为 max
未命中 profile → 断言请求体不含任何非标准字段
```

### TST-10 · 出站头白名单（P0，FR-PRO-07 / SEC-04）

```
构造含 chatgpt-account-id / openai-* / attestation 头的入站请求
→ 断言出站头集合 ⊆ 白名单
→ 断言逐个敏感头确实不在出站头中
```

### TST-11 · capability 校验（P0，FR-RUN-02）

```
无 Authorization → 401
错误 token → 401
正确 token → 通过
重新生成 token → 旧 token 失效，绑定标记为 stale
```

### TST-12 · Body 大小限制（P1，FR-PRO-04）

```
编码后 65MiB → 413，错误体指明是编码前限制
小体积但解压后 > 256MiB（解压炸弹）→ 413，错误体指明是解码后限制
```

### TST-13 · 迁移（P0，MIG-01..04）

```
全新安装 → 直接 v3，无迁移记录
v1 → v3：断言 provider 数、模型数、baseURL 逐条一致；v1 文件仍存在
v2 → v3：断言新字段填了默认值；已有配置零丢失
迁移中途注入失败 → 断言从备份还原，且运行时回落旧路径不中断
CredentialKind.oauth → 断言解码为 oauthDeviceFlow
```

### TST-14 · 布局约束（P0，IA-01/DNA-1）

```
断言 AppTab.allCases.count == 5
断言 minimumPanelWidth == defaultPanelWidth == maximumPanelWidth
断言 accountsPageTargetWidth == accountsCardWidth*2 + accountsRowSpacing + pagePadding*2
```

现有 `LayoutRulesTests` 已覆盖部分，补齐 tab 数量断言。

### TST-15 · 本地化完整性（P0）

现有 `LocalizationConsistencyTests` 扩展：断言 zh-Hans 与 en 的 key 集合完全相等，且 zh-Hans 中无残留英文导航词。

### TST-16 · 账号池零回归（P0，FR-IDT-01）

所有 `Accounts*Tests`（10 个文件）保持绿色且**断言不被修改**。CI 中对这些文件做 diff 检查——修改需要显式说明理由。

---

## 9.3 验收矩阵

P0 交付的验收条件。每条必须可被机器或人工明确判定。

| AC | 条件 | 判定方式 | 需求 |
| --- | --- | --- | --- |
| AC-101 | 打开供应商页能看到 23 家内置供应商 | 人工 + TST-01 | FR-PRV-01 |
| AC-102 | 填一次 Key 后模型自动出现在目录 | 人工 | FR-CAT-01 |
| AC-103 | 无凭据的模型不进目标应用选择器 | TST-06 | FR-CAT-01 |
| AC-104 | 从零到第一个第三方模型可用 ≤ 4 步 | 人工计步 | IA-08 |
| AC-105 | apply → uninstall 后目标配置逐字节还原 | TST-04 | FR-TGT-02 |
| AC-106 | 应用前必须看到 diff 预览 | 人工 | FR-TGT-04 |
| AC-107 | 回滚能还原到上一次配置 | 人工 + IO 测试 | FR-TGT-05 |
| AC-108 | 应用后提示用户手动重启，Copool 不代劳 | 人工 + 代码审查 | FR-TGT-08 / SEC-05 |
| AC-109 | 未知模型返回 404 而非静默路由 | TST-07 | FR-RTE-02 |
| AC-110 | 401 不重试 | TST-08 | FR-RTE-04 |
| AC-111 | 出站请求不含任何 ChatGPT 身份信息 | TST-10 | FR-PRO-07 / SEC-04 |
| AC-112 | 无 capability token 的请求被拒 | TST-11 | FR-RUN-02 / SEC-03 |
| AC-113 | 监听器只绑回环 | 代码审查 + 启动断言 | FR-RUN-01 / SEC-02 |
| AC-114 | 秘密不出现在任何落盘产物中 | TST-02 | INV-1 / SEC-01 |
| AC-115 | 改显示名不改变任何 ID | TST-03 | INV-2 |
| AC-116 | DashScope 通道剥离原生 thinking 参数 | TST-09 | FR-PRO-05 |
| AC-117 | Doctor 覆盖 7 个分类，失败项均有修复动作 | 人工核对 | FR-DOC |
| AC-118 | Doctor 自动修复覆盖率 ≥ 60% | 统计检查项 | 01 章指标 |
| AC-119 | v1/v2 数据迁移零丢失 | TST-13 | MIG-01/02 |
| AC-120 | 迁移失败可回落，功能不中断 | TST-13 | MIG-04 |
| AC-121 | 顶层导航仍为 5 tab，面板宽度仍为 532pt | TST-14 | IA-01 / DNA-1/2 |
| AC-122 | 所有二级导航用 CapsuleSubTabBar | 代码审查 | IA-02 |
| AC-123 | 账号池全部现有测试保持绿色 | CI | FR-IDT-01 |
| AC-124 | 中英文案 key 集合相等，中文无英文残留 | TST-15 | 06.6 |
| AC-125 | 读取第三方登录态前有披露确认，默认不勾选 | 人工 | FR-IDT-06 / SEC-08 |
| AC-126 | 付费冒烟测试默认关闭且需二次确认 | 人工 | FR-CAT-10 / SEC-07 |
| AC-127 | 推理档位未知的模型不发送推理参数 | TST-09 | FR-CAT-05 |
| AC-128 | 不提供限流头的 provider 显示"无配额信息"而非 0 | 人工 | FR-RUN-04 |
| AC-129 | `plan(to:)` 不死锁 | TST-05 | FR-TGT-01 |
| AC-130 | 无主对象（TaskEnvelopeDispatcher 等）已接线或已移除 | 代码审查 | FR-RUN-07 |

---

## 9.4 人工验收清单

机器测不了的部分，交付前逐条走一遍：

```
□ 冷启动 < 1 秒，面板立即可交互
□ 23 家供应商分组折叠流畅，无卡顿
□ 532pt 宽度下无任何横向溢出、无文字截断
□ 二级 tab 标签在中英文下都完整显示
□ 深色/浅色模式下所有新增组件材质正确
□ 每个空态都能引导到下一步动作
□ 每条错误提示都是"发生了什么 + 为什么 + 怎么办"三段式
□ 全流程中文无英文残留
□ 删除类操作全部有二次确认且明示影响面
□ 配置改动全部可回滚
```

---

## 9.5 CI 门禁

| 门禁 | 条件 |
| --- | --- |
| 构建 | `xcodebuild` 零警告（新增代码） |
| 单测 | 全部通过，含现有 47 个文件 |
| 种子校验 | TST-01 通过 |
| 秘密扫描 | TST-02 通过 + 源码中无硬编码 key 模式 |
| 本地化 | TST-15 通过 |
| 账号池回归 | `Accounts*Tests` 未被修改（diff 检查） |
