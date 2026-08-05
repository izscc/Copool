# Phase 02 — Registry v2 与秘密治理

目标：完成 ProviderDefinition/Instance/CredentialIdentity/ModelEntry 和 v1 迁移。

- 禁止 secret value Codable/Equatable/description。
- Provider route ID 使用稳定不可变 ID。
- 构建内置 registry + 用户覆盖层。
- API key/refresh token 安全迁移，配置只留 CredentialRef。
- migration journal、shadow write、verify、rollback。
- 删除/禁用前依赖影响图。

验收：AC-003/004/005；secret scan 通过；重复迁移幂等。
