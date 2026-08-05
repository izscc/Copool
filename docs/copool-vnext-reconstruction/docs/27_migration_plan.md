# 27. 迁移计划

## 数据迁移步骤

1. 获取全局迁移锁。
2. 备份 ProviderStore、账号存储、代理设置、Codex 配置、models cache、remote config。
3. 解析 v1；为每个 provider 生成稳定 UUID 和 definition match。
4. 将 API key/refresh token 写入 SecureStore，读回验证；仅成功后写 `credentialRef`。
5. 转换模型和 protocol binding，保留原 displayName/addedAt。
6. 生成 v2 shadow store，不覆盖 v1。
7. 运行 schema/引用/credential presence/target plan 验证。
8. 原子切换 active store；写 migration receipt。
9. 启动新路径健康检查；失败自动恢复 v1 和原配置。
10. 经过一个发布周期后才清理旧 secret 字段/备份，且用户可主动清理。

## 配置迁移原则

- 只识别 Copool 自己标记的 block；未知来源不接管。
- 保留原生 model/provider/reasoning/profiles/MCP/project trust。
- 每个 Target 独立备份和 receipt。
- WSL/多 CODEX_HOME 需要显式选择，禁止猜测。

## 兼容期

- vNext 首两个版本可读取 v1，但只写 v2。
- rollback 工具可恢复 v1 snapshot。
- 日志记录 migration ID，不记录 secret value。
