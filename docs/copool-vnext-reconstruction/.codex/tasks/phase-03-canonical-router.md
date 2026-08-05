# Phase 03 — Canonical Router Core

目标：把现有协议转换拆成 CanonicalRequest/Event 与 ProviderAdapter。

- Responses/Chat/Anthropic/Gemini。
- SSE、非流式、取消、背压、压缩、大小限制。
- reasoning、tools、images、usage、structured errors。
- retry 分类和 tool side-effect 保护。
- 迁移现有 adapters，旧 façade 保持可切换。

验收：contract fixtures 全通过；lossy conversion 有 warning；无 raw auth header 泄漏。
