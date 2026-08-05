# 09. 组件清单

| 组件 | 责任 | 复用范围 |
|---|---|---|
| `ResourceCardShell` | 标题、状态、摘要、主/次操作、菜单 | Provider/Target/Node/Agent |
| `CredentialBadge` | 认证类型、来源、过期/验证时间 | Provider、Target |
| `ModelCapabilityChips` | tools/vision/reasoning/realtime/context | Catalog、Route、Agent |
| `MetadataSourceBadge` | provider/user/registry/fallback | Model detail |
| `TargetManagedStateView` | unmanaged/planned/managed/drifted | Targets |
| `ConfigDiffSheet` | before/after、managed block、风险、Apply | Target、Migration |
| `RoutePolicyEditor` | hard constraints、weights、failover | Routes |
| `DecisionTraceView` | filters、scores、selected、retry chain | Routes、Session |
| `DoctorSectionCard` | checks、PASS/WARN/FAIL、fix | Diagnostics |
| `SensitiveValueField` | secure input/write only、无回显 | Credentials |
| `UsageSourceLabel` | vendor/header/observed/estimated | Usage |
| `SessionSourceBadge` | Codex/Copool/external agent | Sessions |
| `LiveStatusCapsule` | mic/VAD/STT/model/delegation state | Live |
