# Copool vNext 验证报告

- 时间: 2026-08-06 00:24:30 CST
- 分支: main @ 5be7125

## 1. 构建
```
Build complete! (0.11s)
```
✅ Copool 二进制存在
✅ CopoolRouterHost 二进制存在

## 2. 部署与启动
✅ 代理启动 (health 200, 1s)

## 3. 数据面回归
✅ models 目录 49 个模型
✅ gemini 端到端 (completed ×2)
✅ 浏览器 Origin 拒绝 403 (AC-009)

## 4. v2 Registry 与迁移 (AC-003/004/005)
   version=2, instances=2, credentials=2, catalog=4, secret-scan=clean
✅ v2 registry 有效且无 secret (AC-003)
✅ 迁移 journal 3 条 (AC-004)

## 5. RouterHost (Phase 6)
   UDS capabilities OK
✅ RouterHost UDS control 响应
scripts/vnext-verify.sh: line 86: 44585 Terminated: 15          .build/release/CopoolRouterHost > /tmp/host.log 2>&1
✅ kill host 后主代理不受影响 (崩溃隔离)

## 结果: 10 通过 / 0 失败
✅ 全部通过
