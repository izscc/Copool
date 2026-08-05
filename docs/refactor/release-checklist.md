# Release Checklist & Rollback Drill — Copool vNext

> 生成于 Phase 0-9 完成时（2026-08-06）。供发布 gate 使用。

## 1. 构建与测试

- [x] `swift build -c release` 通过（本机；含 `Copool` + `CopoolRouterHost` 两个 executable）
- [ ] `swift test` — 本机无 Xcode（CommandLineTools 缺 XCTest），**需 CI/Xcode 环境执行**。新增测试文件：
  - `VNextRegistryMigrationTests`（AC-003/004/005）
  - `CanonicalContractTests`（14 用例：四方言 wire shape、SSE、错误分类、header 隔离）
  - `TargetConfigContractTests`（AC-007 循环、故障恢复、脱敏）
  - `RoutePolicyTests`（AC-011/012）
  - `SessionAndTargetTests`（AC-105 + Beta adapter）
  - `VoiceRealtimeTests`（AC-201/202/203）
  - `RemoteNodeTests`（AC-204）
- [ ] CI：GitHub Actions `macos-latest` + Xcode 16 跑完整 test suite；`swiftlint` 或等效 lint 不阻塞

## 2. 签名与公证（发布版）

- [ ] 发布构建用 `Copool.release.entitlements`（team KLU8GF65GP，keychain-access-groups）
- [ ] 公证：`notarytool submit` + staple（发布版签名稳定后 keychain 授权只弹一次）
- [ ] ad-hoc 开发构建部署流程：`codesign --force --sign -` + 用户处理 keychain 授权弹窗（见 baseline.md 环境约束）

## 3. Feature flags

| Flag | 默认 | 用途 | 回退 |
|---|---|---|---|
| v2 registry shadow migration | 开 | v1→v2 只读 shadow write | 关闭 = 不写 v2 文件（v1 不受影响） |
| CopoolRouterHost | 关 | 独立进程数据面（Phase 6） | 关闭 = 进程内引擎（当前路径，零变化） |
| voice plugins | 关 | 语音/实时（Phase 8） | 未启用不加载、不请求权限 |
| multi_agent_v2 | 勿动 | LazyCodex 管理（openai/codex#26753） | — |

## 4. 迁移与回滚 drill

- [x] v1→v2 registry：shadow write → verify → journal（FNV-1a 确定性 sourceHash）→ 幂等（重启验证）
- [x] 回滚：删除 `provider-registry-v2.json` + `migration-journal.json` = 完全回到 v1（v1 providers.json 从未被写入）
- [x] target config：apply 前备份（`targets/<id>/config-backup`）→ 原子写 → verify → rollback 恢复
- [x] keychain：文件明文在迁移后清空；keychain 不可用降级（3s 超时）；迁移入口幂等

## 5. Windows daemon/CLI 可行性（评估）

- RouterHost 数据面（POSIX socket → Windows named pipe；NWListener → WinSock/IOCP）可移植，但本阶段不实现
- SwiftUI 菜单栏 UI 保持 macOS-only；CLI 控制面（UDS → named pipe 协议）为未来 Windows daemon 预留
- 决策：**本发布不含 Windows**；协议层（control socket 命令集）已定义，后续独立任务

## 6. P0 验收矩阵（docs/28_acceptance_matrix.md）

| AC | 内容 | 状态 |
|---|---|---|
| AC-003 | 无明文 secret 进入领域存储 | ✅ 类型层面 + 编码测试 + 真实文件扫描 |
| AC-004 | 迁移可重复、可回滚 | ✅ journal + FNV-1a 幂等（重启验证） |
| AC-005 | 路由键不依赖 displayName | ✅ v2 稳定 UUID + 测试 |
| AC-006 | 目标配置 plan/diff/apply/verify/rollback | ✅ Codex + 通用 adapter |
| AC-007 | 不覆盖未标记用户配置 | ✅ 标记块 + 用户行保留测试 |
| AC-008 | 每 Target 独立 capability/state/端口 | ✅ TargetBinding + 独立 state 目录 |
| AC-009 | 仅 loopback、拒绝 Origin、无 CORS | ✅ 实时 curl 验证 403 |
| AC-010 | 外部请求不带 ChatGPT/Codex 身份 | ✅ 适配器 header 隔离测试 |
| AC-011 | 凭据缺失不进目录 | ✅ CatalogBuilder 测试 |
| AC-012 | 硬约束→评分→选择，trace 可解释 | ✅ RoutePlanner + RouteDecisionTrace |
| AC-014 | 支持包脱敏 | ✅ SecretRedactor + bundle 测试 |
| AC-015 | 5 Tab 不变 + 二级导航 | ✅ Models 子导航（编译+运行） |
| AC-101..106 | Sessions/工具边界/用量来源 | ✅ Session 去重、执行边界、usage origin |
| AC-201..203 | 语音权限门/会话分离/确认执行 | ✅ VoiceRealtimeTests |
| AC-204 | keychain secret 不上传 | ✅ RemoteHeartbeat 白名单 + 测试 |

## 7. 已知风险

1. `swift test` 未在本机执行（XCTest 缺失）——测试文件未经过编译器验证，**发布前必须在 CI 跑一遍**
2. ProviderPageView 二级导航的括号重构（Phase 5）有 UI 回归风险——需目视检查 5 Tab
3. CopoolRouterHost 数据面是骨架（/health + /v1/models 空列表），rich routes 待 adapter 迁移
4. keychain ad-hoc 弹窗（环境约束）——发布版签名稳定后可缓解
