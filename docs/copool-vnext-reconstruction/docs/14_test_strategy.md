# 14. 测试策略

## 测试金字塔

### 1. 领域单元测试

- ID 稳定性、依赖图、评分、预算、迁移、元数据优先级。
- Secret 类型不可编码/打印。

### 2. 协议 fixture/contract tests

每种协议覆盖：

- 非流式与 SSE。
- reasoning/text/tool calls/parallel tools。
- image input、structured output、usage。
- 错误、429、5xx、取消、超时、断流。
- gzip/br/zstd 与编码/解码上限。
- lossless/lossy 字段声明。

### 3. 目标配置测试

- detect/plan/apply/verify/rollback。
- 保留用户未托管字段。
- 拒绝未知 base URL/catalog。
- 原子写入、权限和损坏恢复。
- 登录无关模式开启/关闭精确恢复。

### 4. 安全测试

- 日志/Doctor/support bundle secret scanning。
- caller/internal capability 不能互换。
- 浏览器 Origin/CORS 拒绝。
- 外部请求不含 ChatGPT/Codex 身份头。
- SSRF/base URL override 风险提示和策略。
- 同一目标、跨目标、同一 OS 用户边界测试。

### 5. UI 测试

- P1 现有 Accounts/Proxy/Providers/Agents/Settings snapshot 基线。
- 新二级导航在固定面板宽度下无截断。
- Voice/permission/错误和动态字体。
- keyboard/VoiceOver。

### 6. 迁移测试

- v1 ProviderStore、明文 secret、旧 modelProtocols、旧缓存、旧 remote config fixtures。
- 中断恢复、重复迁移、回滚、部分 Keychain 失败。

### 7. Live tests

- 默认关闭，需 `--live --yes` 或 UI 二次确认。
- 不在 PR CI 注入供应商秘密。
- 记录 provider/model/estimated cost；不保存 prompt/response。

## CI 门槛

- `swift build`、`swift test`。
- lint/format（若仓库引入）。
- schema compatibility。
- fixture contract suite。
- secret scan。
- UI snapshot（macOS runner）。
- 安装/回滚 smoke test（隔离 HOME/CODEX_HOME）。
