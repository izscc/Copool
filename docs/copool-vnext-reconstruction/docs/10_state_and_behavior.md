# 10. 状态与行为

## ProviderInstance 状态机

```text
Draft -> CredentialMissing -> Configured -> Verifying -> Ready
                                      |          |
                                      v          v
                                   Invalid    Degraded
Ready -> CredentialExpired -> Verifying
Ready -> Disabled
```

## TargetBinding 状态机

```text
Unmanaged -> Planned -> Applying -> Managed -> Verifying -> Ready
                                  |                         |
                                  v                         v
                               Failed                    Drifted
Managed/Drifted -> RollingBack -> Restored
```

## RouterService 状态机

```text
Stopped -> Starting -> Running -> Draining -> Stopped
              |          |
              v          v
            Failed     Degraded
```

## 行为规则

- 所有写操作必须可重入；重复 Apply 不制造重复托管块。
- UI optimistic update 仅用于无风险偏好；凭据、目标配置和服务状态必须等待验证。
- 模型目录刷新使用 stale-while-revalidate；旧目录可读但显示时间。
- 路由配置编辑使用 draft，Validate 成功后才 Activate。
- 删除 ProviderInstance 先计算依赖图，提供 Cancel/Disable/Rebind/Delete。
- 远程节点离线不自动删除；路由按策略排除。
