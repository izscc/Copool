# Phase 00 — 基线冻结

目标：在不改行为的情况下完成当前状态侦察和可重复基线。

必须完成：
- 读取现有架构、Provider/Proxy/Accounts/Agents/Settings、tests、resources/proxyd。
- 运行并记录 `swift build`、`swift test`；区分既有失败。
- 创建 v1 ProviderStore、账号、Proxy、Codex config、models cache fixture。
- 为现有主要请求/响应转换建立脱敏 golden fixtures。
- 建立 UI snapshot/截图基线，覆盖 5 个 Tab。
- 输出 current-state-inventory、baseline、implementation-delta。

禁止：大规模重命名、删除旧 runtime、修改用户配置。

验收：基线文档完整；fixture 可加载；现有构建状态可重复。
