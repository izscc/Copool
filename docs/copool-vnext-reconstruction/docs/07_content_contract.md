# 07. 内容与文案契约

## 状态文案

- `Ready`：凭据、模型目录、目标绑定与最近验证均满足。
- `Configured`：配置存在但未验证，不能与 Ready 混用。
- `Observed usage`：仅来自路由流量，不代表供应商余额。
- `Vendor quota`：来自供应商公开接口或响应头，显示采集时间。
- `Estimated cost`：基于价格快照估算，显示价格版本。
- `Managed by Copool`：只用于带可识别标记、可回滚的配置块。
- `Drift detected`：外部修改导致当前配置与安装清单不一致。

## 安全文案

- 绝不要求“粘贴密钥到日志/聊天”。
- 完整 caller URL 视为敏感；复制操作默认只复制脱敏 URL。
- Public Access 开启前明确说明回环安全模型不等于公网认证。
- Live test 显示“可能产生费用”，并列出 provider/model。

## 错误结构

每条用户可见错误包含：

1. 简短标题。
2. 发生在哪个 Target/Provider/Model。
3. 可执行的下一步。
4. “查看技术详情”折叠区，内容已脱敏。
5. 关联 ID，便于日志定位。
