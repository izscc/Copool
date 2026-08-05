# 23. 变体与实验

## V1 导航方案

- **推荐**：5 主 Tab + 页面内二级 segmented。
- 备选：More Tab 聚合高级页。仅在固定宽度下二级导航仍拥挤时试验。

## V2 RouterHost 进程模型

- **推荐**：单 per-user host，多 TargetBinding 独立 listener/state。
- 备选：每 target 独立进程。隔离更强，但服务和升级复杂度更高。
- 通过故障域、内存和升级测试决定，不凭偏好。

## V3 Catalog 更新

- **推荐**：内置版本 + 签名增量 + live discovery + 用户覆盖。
- 备选：完全远程 registry。因离线和供应链风险暂不推荐。

## V4 Auto Route 权重

初始建议：用户优先级 25%、健康 20%、剩余额度 20%、延迟 15%、成本 10%、会话亲和 10%。

实验要求：只在用户开启 Auto 时生效；每个结果必须可解释；收集本地匿名关闭的质量指标，不上传 prompt。
