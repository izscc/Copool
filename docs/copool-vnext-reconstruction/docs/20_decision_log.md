# 20. 决策日志

## ADR-001：保留 SwiftUI 作为唯一产品控制面

- **决定**：不引入 P2 Web Dashboard 或 P3 Tauri UI。
- **原因**：用户要求保持 P1 UI；避免双 UI 栈与打包复杂度。

## ADR-002：Canonial IR 而非 provider-to-target 直接转换

- **决定**：所有请求先进入 CanonicalRequest/Event。
- **原因**：把 N 个目标 × M 个协议降为 N+M 适配面。

## ADR-003：先抽取现有 Swift Runtime，再独立进程

- **决定**：采用 façade + golden fixtures + strangler。
- **原因**：P1 已有大量适配逻辑，直接重写风险过高。

## ADR-004：ProviderFamily 与 ProviderInstance 分离

- **决定**：同一厂商的 OAuth/API/Plan/Cloud 实例并存。
- **原因**：认证、账单、限额和端点不同，不能仅按模型名合并。

## ADR-005：目标级信任根

- **决定**：每个 TargetBinding 独立 capability/state/service/port/provider selection。
- **原因**：减少跨目标泄漏和意外配置污染。

## ADR-006：固定 5 个主 Tab

- **决定**：通过二级导航承载能力。
- **原因**：P1 固定菜单栏宽度和胶囊导航容量是产品约束。

## ADR-007：Voice/Realtime 延后到 P2

- **决定**：先完成路由安全与迁移。
- **原因**：实时音频引入权限、媒体状态和网络复杂度，不应与基础重构并发上线。
