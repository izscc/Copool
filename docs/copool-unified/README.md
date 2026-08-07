# Copool 统一重构文档集

> **本目录是当前唯一的执行依据。** `docs/copool-vnext-reconstruction/` 保留作历史参考，不再更新，冲突时以本目录为准。

---

## 这是什么

把两个外部项目的能力整合进 Copool（Swift 6 + SwiftUI 的 macOS/iOS 原生菜单栏应用）的完整需求与执行文档：

- **OpenCodex** — 协议适配语义、本机订阅导入、Agent 路由、会话中心、语音
- **codex-router** — 供应商注册表、凭据隔离、目录合并、Doctor、配置回滚

整合后的定位：**macOS 上的本地模型路由控制台**——让 Codex、Cursor、opencode 等客户端在不改变自身使用方式的前提下，用上任意已授权的模型。

**Clean-room 约束**：借用产品语义与对外事实，不复制两个项目的源码、UI 布局、产品文案、品牌。

---

## 阅读顺序

| # | 文档 | 读它来回答 |
| --- | --- | --- |
| 01 | [范围与能力矩阵](./01-scope-and-capability-matrix.md) | 做什么、不做什么、优先级 |
| 02 | [身份·凭据·供应商·目录](./02-requirements-identity-provider-catalog.md) | 23 家供应商怎么内置、凭据怎么管 |
| 03 | [目标·路由·协议·运行时](./03-requirements-targets-routing-runtime.md) | 配置怎么写进 Codex、请求怎么路由 |
| 04 | [Agent·会话·语音](./04-requirements-agents-sessions-voice.md) | P1/P2 能力的边界与安全约束 |
| 05 | [信息架构与导航](./05-information-architecture.md) | **UI 硬约束**：532pt、5 个 tab |
| 06 | [逐屏 UI 规格](./06-screen-specifications.md) | 每个屏幕、每个组件长什么样 |
| 07 | [数据模型·存储·迁移](./07-domain-model-storage-migration.md) | 数据结构怎么改、老数据怎么升 |
| 08 | [架构·安全·可观测](./08-architecture-security-observability.md) | **12 条安全红线**、分层约束 |
| 09 | [测试与验收](./09-test-strategy-acceptance.md) | 怎么证明做对了（TST-\*、AC-\*） |
| 10 | [交付计划与风险](./10-delivery-plan-milestones-risks.md) | M0–M7 里程碑、10 项风险 |

**执行用**：

| 文件 | 用途 |
| --- | --- |
| [`CODEX_MASTER_GOAL.md`](./CODEX_MASTER_GOAL.md) | 交给 Codex 的总纲——身份、红线、工程约定。**每个里程碑开始前都读它** |
| [`CODEX_TASK_PROMPTS.md`](./CODEX_TASK_PROMPTS.md) | M0–M7 每个里程碑一段可直接投喂的 prompt |
| [`seed/provider-registry-seed.json`](./seed/provider-registry-seed.json) | 23 家供应商 + 48 个模型 + 11 个 request profile |

---

## 编号体系

所有需求可回溯到 01 章的能力 ID：

```
CAP-*  能力（01 章）
  ↓
FR-*   功能需求（02/03/04 章）：IDT 身份 · PRV 供应商 · CAT 目录 ·
       TGT 目标 · RTE 路由 · PRO 协议 · RUN 运行时 · DOC 诊断 ·
       AGT Agent · SES 会话 · VOI 语音
  ↓
IA-* / SCR-* / CMP-*   界面（05/06 章）
DM-* / MIG-* / INV-*   数据（07 章）
ARC-* / SEC-* / OBS-*  架构与安全（08 章）
  ↓
TST-* / AC-*   测试与验收（09 章）
MS-* / RISK-*  交付（10 章）
```

每章末尾都有回溯表。

---

## 三张速查表

### 12 条安全红线（08 章）

```
SEC-01  秘密只进 Keychain，写失败即中止，不降级明文
SEC-02  监听器只绑 127.0.0.1
SEC-03  强制 caller capability 校验（回环 ≠ 安全）
SEC-04  出站头白名单，剥离所有 ChatGPT 身份信息
SEC-05  绝不重启目标应用
SEC-06  不删用户数据，配置改动全部可逆
SEC-07  付费测试默认关闭 + 二次确认
SEC-08  读第三方登录态需披露确认，默认不勾选
SEC-09  不自建 Computer Use 执行器
SEC-10  麦克风活跃时持续指示，无唤醒词监听
SEC-11  Body 双重限制 64MiB / 256MiB（防解压炸弹）
SEC-12  公网隧道需警告 + 强制 capability 校验
```

### 5 条 UI 不可变约束（05 章）

```
DNA-1  面板宽度锁死 532pt
DNA-2  顶层导航恒 5 个 tab，扩容走二级 CapsuleSubTabBar
DNA-3  高度 520 / 620 / 760
DNA-4  间距圆角色值走 LayoutRules，不写魔法数字
DNA-5  材质走 SectionSurface 系列修饰器
```

### 3 条数据不变量（07 章）

```
INV-1  秘密不进任何 Codable、日志、支持包
INV-2  任何 ID 不从 displayName 派生
INV-3  ModelCatalogEntry.id == providerInstanceID + "/" + backendModelID
```

---

## 里程碑一览

```
M0 地基与护栏   种子加载、模型扩展、修 3 个既有缺陷
M1 供应商注册表  23 家内置 + 凭据体系 + 覆盖层
M2 模型目录     凭据感知目录 + 发现 + 策展
M3 目标绑定     六方法契约 + diff 预览 + 回滚
M4 路由与协议    解析优先级 + 失败分类 + request profile + 头白名单
M5 运行时与Doctor capability 校验 + 端口 + 限流 + 7 类诊断
M6 迁移与打磨    v2→v3 迁移 + 本地化 + 人工验收
────────────── 以上为 P0 交付 ──────────────
M7 Agent/会话/语音  P1/P2，价值验证后再启动
```

---

## 成功的定义

用户打开 Copool → 供应商页看到 23 家内置供应商 → 选 DeepSeek 填一次 Key → 模型自动出现在目录 → 运行时页预览 diff 并应用到 Codex → 重启 Codex → 在原生模型选择器里选中 DeepSeek 正常对话。

**全程 ≤ 4 步，配置全部可回滚，出问题点 Doctor 能看到具体哪项 FAIL 与怎么修。**

---

## 已知的既有缺陷（M0 修）

| # | 位置 | 问题 |
| --- | --- | --- |
| 1 | `TargetConfigFileAdapter.swift:43-52` | `plan(to:)` 持锁调用 `detect()`，`NSLock` 不可重入 → **死锁** |
| 2 | `TargetConfigFileAdapter.swift:102-107` | `verify(_:)` 全文相等比较，外部改动托管块外内容会误判失败 |
| 3 | `AppContainer.swift:113-119` | `TaskEnvelopeDispatcher` / `RemoteNodeControlService` 构造后从未被消费 |
| 4 | `ProviderPageView.swift:22-28` | 二级导航用原生 `Picker(.segmented)`，应用仓库自带的 `CapsuleSubTabBar` |
| 5 | `ProviderPageView.swift:733-736` | `discoverableModels` 恒返回 `[:]`，死代码 |
