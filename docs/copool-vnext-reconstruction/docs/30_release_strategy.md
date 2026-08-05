# 30. 发布策略

## Feature Flags

- `registryV2`
- `canonicalRouter`
- `targetIsolation`
- `routerHost`
- `cursorTarget`
- `opencodeTarget`
- `sessionCenter`
- `agentRouting`
- `nativeToolBridge`
- `voiceLive`
- `remoteNodeV2`

## 发布波次

1. 内部：只启用新 schema shadow read 和 Doctor。
2. Alpha：Registry v2 + Catalog + Codex TargetAdapter，旧 Router 默认。
3. Beta：Canonical Router + Target isolation，可一键回旧路径。
4. Stable P0：RouterHost 默认，旧路径保留一个版本。
5. P1 Beta：Cursor/opencode/Session/Agent。
6. P2 Beta：Voice/Realtime/Remote Node v2。

## 回滚

- App binary rollback 不应破坏 v1 snapshot。
- schema backward reader 至少维持两个版本。
- Target config receipt 与 app 版本无关，可由恢复 CLI 使用。
- 远程节点保留上一版本 slot。

## 分发注意

- 后台 helper、网络权限、Keychain access、签名、公证和 TestFlight/App Store 规则需单独验证。
- 用户说“TestFlight 审核”时按仓库现有 AGENTS 规则理解为外部测试审核，不等同 App Store 正式审核。
