# 28. 验收矩阵

## P0

| ID | 验收标准 | 验证方式 |
|---|---|---|
| AC-001 | 现有账号导入、切换、配额刷新、智能切换通过 | 回归 UI/单元/fixture |
| AC-002 | 现有本地代理和远程代理核心场景通过 | integration fixtures + smoke |
| AC-003 | ProviderConfig v2 不含可持久化 secret value | 类型/编码/secret scan |
| AC-004 | v1 provider/secret/model protocol 可迁移且可回滚 | migration fixtures |
| AC-005 | 路由键不依赖可变 displayName | rename test |
| AC-006 | OpenAI native 模型/登录/配置未被外部 provider 覆盖 | isolated CODEX_HOME test |
| AC-007 | Codex target 支持 detect/plan/diff/apply/verify/rollback | target contract test |
| AC-008 | 每 target caller/internal capability、state、listener 独立 | cross-target negative tests |
| AC-009 | Router 只绑定 UDS/127.0.0.1，Origin/CORS 安全通过 | network security tests |
| AC-010 | 外部 provider 请求无 ChatGPT/Codex 身份/attestation headers | header fixture |
| AC-011 | Catalog 凭据感知、live discovery、策展、来源优先级正确 | catalog tests |
| AC-012 | Auto route 先硬过滤后评分，并生成 decision trace | deterministic route tests |
| AC-013 | 429/5xx/网络/工具状态重试策略正确 | fault injection |
| AC-014 | Doctor 输出分层 PASS/WARN/FAIL 且已脱敏 | snapshot + secret scan |
| AC-015 | UI 维持 5 主 Tab、原 token，固定宽度无溢出 | UI snapshot/accessibility |
| AC-016 | `swift build`、`swift test` 通过 | CI |

## P1

| ID | 验收标准 |
|---|---|
| AC-101 | Cursor/opencode 配置与状态完全隔离，卸载不影响 Codex |
| AC-102 | Session Center 可索引、搜索、预览和适配器导入 |
| AC-103 | Agent Profile 以能力/策略路由，不基于名字猜测 |
| AC-104 | MCP/tool/image/CUA 保持原生受信执行边界 |
| AC-105 | 登录无关模式开启/关闭精确恢复原配置 |
| AC-106 | Usage 明确区分 vendor/header/observed/estimated |

## P2

| ID | 验收标准 |
|---|---|
| AC-201 | Voice 插件未启用时不请求麦克风或加载媒体服务 |
| AC-202 | Realtime 对话可产生经用户确认的 TaskEnvelope 并委派 |
| AC-203 | 音频默认不持久化，权限/录音状态明确 |
| AC-204 | Remote Node 版本握手、身份、升级和 rollback 可验证 |
