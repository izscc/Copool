# Baseline — Copool vNext Phase 0

> 生成时间：2026-08-05；分支 `main` @ 828dbb6（8 个提交已推送 origin/main）

## 1. 构建基线

| 命令 | 结果 | 备注 |
|---|---|---|
| `swift build -c release` | ✅ Build complete! | 增量 0.15s；全量约 23s |
| `swift test` | ❌ 失败 | **既有环境失败**：`no such module 'XCTest'`（本机仅 CommandLineTools，无 Xcode；测试目标只能在 Xcode 环境运行） |

### 既有编译警告（非新增）

- `Sources/Copool/Features/Agents/AgentPageView.swift:195` — Sendable 转换 warning（Toggle binding）。

## 2. 运行时基线（部署验证记录）

- 部署路径：`.build/release/Copool` → `/Applications/icopool.app/Contents/MacOS/icopool`（adhoc 签名，`codesign --force --sign -`）。
- 代理端口：8787（失败回退 8788+）。
- 验证点（2026-08-05 实跑）：`/health` 200 ✅；`/v1/models` 49 模型（45 原生 + gemini×3 + grok×1）✅；gemini 端到端 SSE ✅；zstd 压缩请求体 ✅；compaction kcr1 ✅；`/v1/images/generations` 路由生效（502 账号认证错误 = 账号 token 过期状态，非路由问题）。
- 已知运行时事实：grok OAuth token 已过期（403 bad-credentials，需用户重新导入）；antigravity 凭据经 Keychain 迁移后可用。

## 3. 环境约束（必须记录）

1. **ad-hoc 签名 × keychain**：每次重建签名变化 → macOS 对新构建读 keychain 弹授权框，`SecItemCopyMatching` 可无限阻塞。已缓解：`KeychainSecretStore` 全部调用后台队列 + 3s 超时降级；迁移入口后台化。**新构建部署后如应用卡启动，先查授权弹窗**。
2. **无 Xcode**：`swift test` 不可用；测试正确性靠 review + 独立 swiftc 验证。
3. **multi_agent_v2**：用户 `~/.codex/config.toml` 由 LazyCodex 管理（openai/codex#26753 每 turn HTTP 400 被强制禁用），vNext 不得主动写该开关。

## 4. Fixtures（docs/refactor/fixtures/）

| 文件 | 内容 | 用途 |
|---|---|---|
| `v1-providers.json` | v1 ProviderStore（subscriptionImport 型，secret 已脱敏为空） | v1→v2 迁移 fixture |
| `v1-accounts.json` | 账号池（token REDACTED + 5h/1week 配额） | 回归 fixture |
| `v1-usage.json` | ThirdPartyUsageStore（provider/model 聚合） | 迁移 fixture |
| `v1-config.toml` | Codex config（opencodex provider 段） | target config diff/rollback 基线 |
| `v1-models-cache.json` | models_cache（原生 + third-party 模型） | catalog 注入回归 |

### Golden fixtures（请求/响应转换，脱敏）

> 说明：真实流式响应的 golden 记录在后续阶段随 contract tests 建立；Phase 0 先记录样例输入形态。

- 请求：`/v1/responses` body（gemini 第三方路由，含子代理标记）、`/v1/chat/completions` body、zstd 压缩体样例（level 3）。
- 响应：gemini SSE 流（`response.created` → `response.completed`）、compaction kcr1 item。

## 5. 截图基线

- 5 个 Tab（账号/模型服务/运行时/Agent/设置）截图：**未执行**（菜单栏窗口截图需要 GUI 交互；作为 Phase 5 UI 工作的验收项，届时用 `screencapture -l` 窗口捕获或 XCTest UI snapshot）。

## 6. 已知失败 / 风险登记

| 项 | 状态 | 处置 |
|---|---|---|
| `swift test` XCTest 缺失 | 环境性 | CI/Xcode 环境跑；本机用 review + swiftc 验证 |
| grok token 过期 | 用户数据 | Providers 页重新导入 |
| keychain 授权弹窗 | 环境性 | 已超时硬化；部署后提示用户处理 |
| v1 ProviderConfig 承载 secret（可编码） | 设计债 | Phase 2（Registry v2）解决：CredentialIdentity 引用 + Keychain-only |
| 路由键依赖可变 name | 设计债（AC-005） | Phase 2 引入稳定 id 键 |
