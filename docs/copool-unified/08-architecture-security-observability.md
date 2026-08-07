# 08 · 系统架构、安全、可观测与合规

> 编号规则：`ARC-<序号>` 架构，`SEC-<序号>` 安全，`OBS-<序号>` 可观测，`CMP-LEG-<序号>` 合规。
> 本章的 SEC 条目是**红线**：任何实现与它冲突，改实现，不改红线。

---

## 8.1 分层架构

```
┌─ Features（SwiftUI 视图 + PageModel）────────────────┐
│  AccountsPage · ProxyPage · ProviderPage ·          │
│  AgentPage · SettingsPage                           │
├─ Behavior（协调器，@MainActor）──────────────────────┤
│  ProxyCoordinator · TargetConfigCoordinator ·       │
│  CredentialCoordinator（新增）                       │
├─ Domain（纯值类型 + 纯函数，无 IO）──────────────────┤
│  VNextRegistry · RoutePolicy/RoutePlanner ·         │
│  TargetModels · ProviderModels · CatalogBuilder     │
├─ Infrastructure（IO、进程、网络、Keychain）───────────┤
│  SwiftNativeProxyRuntimeService · V2RouteResolver · │
│  ProviderFileRepository · KeychainSecretStore ·     │
│  TargetConfigFileAdapter · RouteDecisionLedger ·    │
│  ProviderRegistrySeedLoader（新增）                  │
├─ Router Host（独立进程）────────────────────────────┤
│  CopoolRouterHost                                   │
└─────────────────────────────────────────────────────┘
```

**ARC-01 · 依赖方向单向**

`Features → Behavior → Domain ← Infrastructure`。Domain **不得** import 任何 Infrastructure 类型，也不做任何 IO。`RoutePlanner` 已是正确范例——它接收 `credentials: [String: Bool]`，从不接触 Keychain。

**ARC-02 · 并发模型**

- `Domain` 全部 `Sendable` 值类型，纯函数。
- `Behavior` 层协调器 `@MainActor`。
- `Infrastructure` 的有状态服务用 `actor`，或 `final class + NSLock` 并标 `@unchecked Sendable`（现有 `TargetConfigFileAdapter` 采用后者）。
- **锁的重入问题必须在设计时排除**：见 03 章 FR-TGT-01 记录的 `plan(to:)` 死锁。规则——**持锁方法不得调用另一个持锁方法**；需要复用时抽出 `xxxLocked()` 私有方法。

**ARC-03 · 种子加载**

`ProviderRegistrySeedLoader` 从 Bundle 读 `provider-registry-seed.json`，解码为 `[ProviderDefinition]` + `[ModelCatalogEntry]` + `[String: RequestProfile]`。

- 解码失败 = **构建期错误**，通过单测拦截，不允许运行时降级为空注册表。
- 种子加载结果缓存在内存，进程生命周期内只解码一次。

**ARC-04 · 目标适配器注册**

三个适配器（codex / cursor / opencode）通过统一协议注册到 `TargetConfigCoordinator`。新增目标只需实现协议 + 注册，不改协调器。

**ARC-05 · 请求处理管线**

按 03 章数据流实现为可测试的中间件链：`鉴权 → 解压 → 限流检查 → 路由 → profile 应用 → 协议转换 → 转发 → 响应处理（SSE/限流头/记账）`。每一环独立可测，不允许把逻辑糊在一个大函数里。

---

## 8.2 安全红线

**SEC-01 · 秘密只进 Keychain**

落盘的只有 `SecureReference`。禁止：明文写文件、写 UserDefaults、写日志、进支持包、进崩溃报告。

Keychain 写入失败 → **报错中止**，不降级。

**SEC-02 · 仅回环监听**

所有监听器绑定 `127.0.0.1`。启动时断言，非回环地址拒绝启动。

**SEC-03 · caller capability 强制校验**

回环不等于安全（本机任意进程、浏览器页面都能访问 localhost）。每个请求校验 `Authorization: Bearer <callerCapability>`，不匹配 401。见 FR-RUN-02。

**SEC-04 · 身份信息隔离**

发往第三方的请求头走**白名单**。必须剥离 ChatGPT/Codex 的 account id、session id、installation id、device id、attestation 头、`originator`、以及所有 `chatgpt-*` / `openai-*` 头。见 FR-PRO-07。

**SEC-05 · 不静默重启目标应用**

Copool 绝不结束/重启目标应用进程。见 FR-TGT-08。

**SEC-06 · 不删除用户数据**

- 目标配置改动全部可逆：托管块 + 备份 + 回滚。
- 不删除第三方 CLI/客户端的原始登录态。
- 删除操作一律二次确认并明示影响面。

**SEC-07 · 付费操作显式同意**

兼容性冒烟测试默认关闭，开启后每次执行仍需二次确认并明示会产生费用。见 FR-CAT-10。

**SEC-08 · 第三方登录态复用需披露与授权**

首次读取前必须走 `DisclosureConsentSheet`，默认不勾选，无"不再提示"。确认记录写 `consent-log.jsonl`。见 FR-IDT-06。

**SEC-09 · 不自建 Computer Use 执行器**

外部模型不得直接获得系统控制权。若无法通过目标应用原生执行器实现，放弃该能力。见 FR-AGT-06。

**SEC-10 · 麦克风状态必须可见**

活跃采集时菜单栏图标持续指示，提供全局停止。不实现唤醒词常驻监听。见 FR-VOI-03。

**SEC-11 · 解压炸弹防护**

编码前 64 MiB、解码后 256 MiB 两道独立限制。见 FR-PRO-04。

**SEC-12 · 公网隧道需显式警告**

Cloudflared 是 SEC-02 的唯一例外，开启需醒目警告 + 强制 capability 校验。

---

## 8.3 Clean-room 合规

**CMP-LEG-01 · 不复制 P2/P3 的代码、文案、品牌、UI 布局**

本次整合借用的是**产品语义与工程约束**：哪些 provider 值得内置、端点是什么、哪个上游需要特殊请求处理、托管块该怎么标记。Swift 侧全部原创实现。

具体边界：

| 可以借用 | 不可复制 |
| --- | --- |
| provider 的 id 命名、baseURL、环境变量名（这些是与外部服务对接的事实） | P3 的 TypeScript/JS 源码结构与函数实现 |
| 模型的上下文窗口、推理档位（客观事实） | P2 的 UI 布局、组件层级、CSS |
| 托管块的标记格式（互操作需要一致） | P2/P3 的产品文案与品牌名 |
| Doctor 的检查项分类（工程共识） | 二者的错误提示原文 |

**CMP-LEG-02 · 第三方服务条款**

复用第三方 CLI/客户端登录态的能力，其合规性取决于对应服务的条款。实现前需逐个确认，条款禁止的通道**不提供**。这是产品决策，不是技术问题——文档只记录约束，实际取舍由项目所有者判断。

**CMP-LEG-03 · 依赖与许可**

不引入 Node.js / Python / Electron 运行时依赖（01 章 OUT）。新增 Swift 依赖需固定版本，记入关于页的第三方声明。

---

## 8.4 可观测性

**OBS-01 · 三条日志流**

| 流 | 文件 | 内容 | 保留 |
| --- | --- | --- | --- |
| 路由决策 | `route-decisions.jsonl` | 完整 trace（候选、得分、淘汰原因、失败链） | 10MB 轮转，1 份历史 |
| 用量事件 | `usage-events.jsonl` | provider/model/tokens/耗时/结果 | 同上 |
| 披露审计 | `consent-log.jsonl` | 时间、来源、版本 | 不轮转（量极小） |

**OBS-02 · 日志脱敏**

写入前统一过滤：API key 片段、Bearer token、邮箱（保留首字符 + 域名）、绝对路径中的用户名。脱敏是**写入时**做，不是导出时做——否则磁盘上已经泄露了。

**OBS-03 · 支持包**

包含：应用版本、系统版本、注册表结构（**去凭据引用的 name 字段**）、目标绑定状态、Doctor 最近结果、三条日志的尾部各 500 行。

导出前展示清单与"已脱敏哪些字段"，用户确认后生成。

**OBS-04 · 可解释性要求**

用户能被回答的三个问题：

1. **"为什么这个模型没出现在选择器里？"** → 目录页显示缺失原因（凭据未就绪 / 已隐藏 / 供应商停用）。
2. **"为什么请求走了别的 provider？"** → 路由 tab 的 trace，含淘汰原因。
3. **"为什么请求失败了？"** → 错误三段式 + Doctor 对应检查项。

任何一个问题答不上来，就是可观测性缺陷。

---

## 8.5 性能约束

| 项 | 目标 | 理由 |
| --- | --- | --- |
| 冷启动到面板可交互 | < 800ms | 菜单栏应用，用户期望即时 |
| 种子解码 | < 50ms | 23 provider + 48 model，一次性 |
| 目录重建 | < 100ms | 纯内存计算 |
| 首字节延迟额外开销 | < 30ms | 路由 + profile + 协议转换的总开销 |
| 常驻内存 | < 150MB | 菜单栏常驻进程 |
| 目录折叠态渲染 | 不渲染子项 | 23 张卡片常驻会拖慢滚动 |

流式转发**不做缓冲聚合**——收到 chunk 立即转发，否则会破坏用户感知的响应速度。

---

## 8.6 回溯

| ID | 对应需求 |
| --- | --- |
| ARC-01..05 | 全章实现约束 |
| SEC-01 | FR-IDT-02, INV-1 |
| SEC-02 | FR-RUN-01（AC-009） |
| SEC-03 | FR-RUN-02 |
| SEC-04 | FR-PRO-07 |
| SEC-05 | FR-TGT-08 |
| SEC-06 | FR-TGT-02/05, FR-IDT-08 |
| SEC-07 | FR-CAT-10 |
| SEC-08 | FR-IDT-06 |
| SEC-09 | FR-AGT-06 |
| SEC-10 | FR-VOI-03 |
| SEC-11 | FR-PRO-04 |
| SEC-12 | FR-RUN-01 |
| CMP-LEG-01..03 | 01 章 clean-room 约束 |
| OBS-01..04 | FR-RTE-05, CAP-OPS-02 |
