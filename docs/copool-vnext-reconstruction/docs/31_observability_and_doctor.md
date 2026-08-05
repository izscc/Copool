# 31. 可观测性与 Doctor

## 结构化事件

- `request.received`, `route.decided`, `provider.request`, `provider.retry`, `response.completed`, `target.config.*`, `migration.*`, `credential.verified`, `service.lifecycle`。
- 关联字段：request/session/decision/target/providerInstance/model/credential fingerprint（非值）。
- 内容字段默认不记录 prompt/response/tool arguments。

## 指标

- 请求数、成功率、首 token 延迟、总延迟、429/5xx、token、估算成本。
- target/service 健康、catalog age、credential expiry、remote node heartbeat。

## Doctor 检查层

1. App/版本/路径。
2. SecureStore 和文件权限。
3. Target detection/config drift。
4. Service/listener/capability。
5. Provider credential presence（不显示值）。
6. Catalog/alias/model binding。
7. Optional live route。
8. Remote node/tunnel。

## 支持包

默认：版本、平台、脱敏配置摘要、Doctor、文件权限、schema、服务状态、hash/diff。

可选：脱敏日志尾部、decision trace。永不自动上传。
