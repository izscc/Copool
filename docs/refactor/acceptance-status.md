# 验收状态（2026-08-06，基于当前工作树）

对照 `docs/copool-vnext-reconstruction/docs/28_acceptance_matrix.md`。本文件只记录当前源码和本次验证实际确认的结果，不沿用旧的“10/10 全部通过”结论。

## P0

| ID | 状态 | 当前证据 / 限制 |
|---|---|---|
| AC-001 | WARN | 原有账号池代码保留；完整 XCTest 回归因本机缺 XCTest 未运行。 |
| AC-002 | WARN | 原有本地/远程代理代码保留；release build 通过，完整 integration smoke 未在本轮重跑。 |
| AC-003 | PASS/WARN | `ProviderConfig.encode(to:)` 不再编码 apiKey/refreshToken；ProviderFileRepository 在 SecureStore 写入失败时拒绝保存；v2 registry 仅保存 opaque refs。仍需 Xcode 测试和真实文件迁移回归。 |
| AC-004 | PASS/WARN | v1→v2 journal、确定性 source hash、shadow verify、rollback 保留；新增字段迁移兼容仍需 XCTest 实跑。 |
| AC-005 | PASS/WARN | 主路由前缀改用稳定 provider ID，旧 display-name 仅作为兼容 alias；rename migration 更新同一 instance。需 XCTest 实跑确认全部旧 fixture。 |
| AC-006 | WARN | Codex 原生路径仍保留；完整隔离 CODEX_HOME smoke 未在本轮执行。 |
| AC-007 | PASS/WARN | Codex marked-block adapter 支持 detect/plan/apply/verify/rollback/uninstall，原有 contract tests 保留；XCTest 未执行。 |
| AC-008 | PASS/WARN | 新增持久化 TargetBindingStore，默认 Codex/Cursor/opencode 独立 state/capability 引用；Cursor/opencode 仍是 beta config adapter，未实现独立生产 listener/process。 |
| AC-009 | PASS | RouterHost 与 in-process server 均 loopback；Host data plane 要求 caller capability，UDS control 要求 internal capability，Origin 被拒绝；RouterHost authenticated smoke 已通过。 |
| AC-010 | PASS/WARN | Provider adapter/header allowlist 和第三方请求路径不转发 ChatGPT/Codex 身份；需完整 contract XCTest 实跑。 |
| AC-011 | PASS/WARN | CatalogBuilder 做 credential-aware filtering；registry/live discovery/curation/metadata source 已接入；完整 provider 矩阵和 user-confirmed provenance 仍未完成。 |
| AC-012 | PASS/WARN | RoutePlanner 已接入真实第三方请求入口，支持 explicit/alias/auto、target/capability/region/budget hard filter、健康/配额/延迟/成本/priority/affinity 评分和 50 条 UI trace；XCTest 未执行。 |
| AC-013 | PASS/WARN | 非流式第三方请求支持可重放请求的网络/429/瞬时 5xx 重试、Retry-After、退避和 token refresh；有工具副作用且无幂等 key 时禁止重放；流式一旦打开不重放。需 fault-injection XCTest 实跑。 |
| AC-014 | PASS/WARN | Doctor/SecretRedactor/SupportBundle 已有三态和脱敏；源码 secret scan 通过，完整 snapshot 未执行。 |
| AC-015 | WARN | 5 个顶层 Tab、二级导航、Target/Routes/Usage UI 已存在并编译；固定宽度 UI snapshot/accessibility 未执行，仍有 AgentPageView Sendable warning。 |
| AC-016 | WARN | `swift build -c release` 通过；`swift test` 被环境阻塞：`no such module 'XCTest'`。 |

## P1

| ID | 状态 | 当前证据 / 限制 |
|---|---|---|
| AC-101 | WARN | Target config generic adapter 与 Cursor/opencode 入口存在；process/service/listener 完全隔离尚未完成。 |
| AC-102 | WARN | Codex session index sync/search/preview/dedupe 已有；外部 Agent import adapters、字段丢失说明、导出/恢复引用未完成。 |
| AC-103 | PASS/WARN | AgentTaskRouter 按能力/标签/策略，不按模型名称猜测；完整真实任务回归需 XCTest。 |
| AC-104 | WARN | Tools UI 明确 Codex/trusted executor 边界，CUA 默认关闭；MCP discovery/permission/compatibility workflow 尚未实现。 |
| AC-105 | PASS/WARN | login-optional marked config apply/remove 保留用户行并可恢复；完整 isolated config smoke 未执行。 |
| AC-106 | PASS/WARN | vendor/header/observed/estimated origin 已区分；完整 usage UI snapshot 未执行。 |

## P2

| ID | 状态 | 当前证据 / 限制 |
|---|---|---|
| AC-201 | PASS/WARN | VoicePluginConfig/RealtimeSessionManager 的未启用权限门和取消清理已实现并补测试；真实 STT/TTS/VAD plugin/transport 未实现。 |
| AC-202 | PASS/WARN | TaskEnvelope 用户确认后委派、查询、完成/失败/取消审计已实现；没有真实 Realtime transport 产生 envelope。 |
| AC-203 | PASS/WARN | 音频域默认不持久化、取消清空 transcript count；真实音频临时文件生命周期未实现。 |
| AC-204 | PASS/WARN | Remote handshake/heartbeat/upgrade/rollback 状态流存在；升级后必须重新 handshake 并使用真实 nodeVersion，不再写固定 `upgraded`；SSH integration 和跨平台 daemon 未完成。 |

## 本轮已验证

- `swift build -c release`：通过。
- `bash -n scripts/vnext-verify.sh`：通过。
- RouterHost：authenticated UDS、未授权 control 拒绝、caller capability data plane、registry models、authenticated shutdown smoke：通过。
- 新增资源 key 扫描：通过。
- 源码测试 secret 扫描：通过。
- `swift test`：环境阻塞，Xcode/XCTest 不可用。

## 仍然不能宣称完整实现的项目

1. 本机无法运行 XCTest；必须在 Xcode/macOS CI 执行 `xcodebuild test`。
2. UI snapshot/accessibility 基线仍未建立。
3. Voice/Realtime 只有安全域模型和权限/确认门，真实媒体/Realtime transport 未实现。
4. Cursor/opencode、外部 Session、MCP discovery 仍是 beta/骨架。
5. RouterHost 已具备安全 loopback/control 和模型目录，但 rich Canonical provider route 尚未从 in-process runtime 完整迁移；当前仍是 feature-flag 回退架构。
6. release 构建仍有 `AgentPageView.swift:379` 的 Swift 6 Sendable warning，未达到项目要求的零警告门槛；尝试用 `@MainActor @Sendable` 修复时触发当前 CommandLineTools Swift 6.3.3 编译器 SmallVector crash，已撤回该非关键改动，待 Xcode toolchain 单独处理。
