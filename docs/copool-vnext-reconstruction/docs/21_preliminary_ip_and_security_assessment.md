# 21. 初步知识产权与安全评估

## 知识产权

- P3 有明确 MIT License，但本项目仍不需要复制其代码；可参考公开协议和安全模式，若将来复用代码必须保留许可声明。
- P1/P2 根目录未观察到 LICENSE；在许可证明确前，不从 P2 复制源码、测试 fixture、UI、图片、文案或品牌资产。
- 本包是基于公开行为和工程约束的原创产品/架构设计，不主张参考项目的商标、品牌或未公开实现。

## 安全基线

1. Secret 不进入 Codable domain model、日志、catalog、config diff、support bundle。
2. 每目标 caller/internal capability 分离。
3. 仅 UDS/loopback，拒绝 Origin，无 CORS。
4. 外部 provider 只收到对应 provider credential；原生 OpenAI token 仅用于原生请求。
5. 端点覆盖为高信任配置，必须显示 host 和凭据将被发送的目的地。
6. 文件原子写入、当前用户权限、备份和 migration snapshot。
7. live test 显式付费确认。
8. 对同一 OS 用户恶意进程不做虚假“沙箱”承诺；真正隔离需要系统级 sandbox/独立用户，列为后续研究。

## Threat Model 摘要

| 威胁 | 控制 |
|---|---|
| 浏览器 drive-by 调回环 API | capability + Origin reject + no CORS |
| 错把 OpenAI token 发到第三方 | header allowlist + final credential replacement |
| 目标 A 使用目标 B 密钥 | target-specific key/state/listener |
| 日志泄漏 prompt/secret | structured redaction + support bundle opt-in |
| 恶意 base URL 偷取 provider key | explicit trust warning + host diff + policy |
| 配置损坏导致 Codex 不可用 | plan/diff/atomic apply/verify/rollback |
| 工具请求被重复执行 | idempotency/tool-state retry policy |
