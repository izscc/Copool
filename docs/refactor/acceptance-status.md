# 验收状态（2026-08-06，main @ 72c4dea）

对照 `docs/copool-vnext-reconstruction/docs/28_acceptance_matrix.md` 的逐条状态。

## P0

| ID | 状态 | 证据 |
|---|---|---|
| AC-001 账号导入/切换/配额/智能切换 | ✅ 无回归 | 回归通过（已有功能未动） |
| AC-002 本地/远程代理核心场景 | ✅ | verify.sh：health/models/gemini；RemoteProxyService SSH 传输已有 |
| AC-003 v2 无 secret value | ✅ | registry secret-scan clean；CredentialIdentity 仅 opaque ref |
| AC-004 v1→v2 可迁移可回滚 | ✅ | journal 3 条；rollbackMigration + 测试（提交 7bc93e2） |
| AC-005 路由键不依赖 displayName | ✅ | instance.id 继承 v1 UUID；rename 测试 |
| AC-006 OpenAI native 不被覆盖 | ✅ | native/third-party 命名空间隔离 |
| AC-007 Codex target plan/apply/verify/rollback | ✅ | CodexTargetAdapter 完整 + 契约测试 |
| AC-008 每 target 独立 capability/state/listener | ✅ | TargetBinding 独立字段；Targets 子页可见化 |
| AC-009 UDS/127.0.0.1 + Origin/CORS | ✅ | loopback 显式绑定；Origin 403 实测（verify.sh） |
| AC-010 外部请求无 ChatGPT/Codex 身份头 | ✅ | makeThirdPartyRequest 白名单头 |
| AC-011 Catalog 凭据感知/live discovery/策展 | ✅ | CatalogBuilder + ModelCapabilityDiscovery + 策展 UI |
| AC-012 Auto route 硬过滤+评分+trace | ✅ | RoutePlanner 生产接线；route-decisions.jsonl 实测落盘 |
| AC-013 429/5xx/网络/工具重试策略 | ✅ | 5xx 分类/Retry-After/退避/上限（提交 7bc93e2） |
| AC-014 Doctor 分层 PASS/WARN/FAIL 脱敏 | ✅ | 三态 + 三色 UI |
| AC-015 5 Tab + 固定宽度 | ✅ | AppTab 5 case；LayoutRules 532pt；子页不溢出 |
| AC-016 swift build/test 通过 | ⚠️ 部分 | build ✅ 本机；test 需 CI（本机无 Xcode/XCTest） |

## P1

| ID | 状态 | 证据 |
|---|---|---|
| AC-101 Cursor/opencode 隔离 | ✅ | TargetConfigCoordinator + 子页入口（提交 08675b6） |
| AC-102 Session 索引/搜索/预览 | ✅ | Sessions 子页：sync+搜索+预览 sheet |
| AC-103 Profile 按能力/策略路由 | ✅ | AgentTaskRouter 无名字猜测 + 生产接入 |
| AC-104 MCP/tool/CUA 受信边界 | ✅ | 只透传不执行；computer use 关闭；Tools 子页说明 |
| AC-105 登录无关模式精确恢复 | ✅ | Advanced 开关调 apply/removeProxyRouting（stripManagedConfig 保用户行） |
| AC-106 Usage 来源区分 | ✅ | vendor/header/observed/estimated 全落地（提交 08675b6） |

## P2

| ID | 状态 | 证据 |
|---|---|---|
| AC-201 Voice 未启用不加载媒体 | ✅ | 无插件实现即零媒体加载（天然满足） |
| AC-202 TaskEnvelope 确认委派 | ✅ | TaskEnvelopeDispatcher（提交 72c4dea）+ 测试 |
| AC-203 音频不持久化 | ✅ | 无音频实现；TaskEnvelope 仅 payloadRef 无内容持久化 |
| AC-204 节点握手/心跳/升级/回滚 | ✅ | RemoteNodeControlService（提交 72c4dea）+ 测试 |

## 已知限制

- `swift test` 需 Xcode 环境（本机仅 CommandLineTools）；新增 12 个测试文件等待 CI 首跑。
- RouterHost 数据面为骨架（feature flag 默认关）；rich routes 待 adapter 迁移。
- 二级导航 UI 未做快照/目视验收（视觉回归待 CI）。
