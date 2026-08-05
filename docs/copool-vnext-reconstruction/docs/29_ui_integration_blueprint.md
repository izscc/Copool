# 29. UI 融合蓝图

## 原则

原 UI 不是“皮肤”，而是容量和交互约束。当前顶层胶囊切换器最大宽度约 260pt，固定面板以账号卡片两列宽度为基准，因此新能力不能继续增加同级 Tab。

## 顶层映射

| 现有 | vNext | 说明 |
|---|---|---|
| Accounts | Accounts | 原样保留并新增 credential identity 入口 |
| Providers | Models | 页面内包含 Providers/Catalog/Routes/Usage |
| Proxy | Runtime | 扩展本地/目标/远程/公网/日志 |
| Agents | Agent | 扩展 Profiles/Sessions/Tools/Live |
| Settings | Settings | 增加 Security/Diagnostics/Advanced |

## 关键页面布局

### Models

- 顶部二级 segmented。
- Provider 卡片：logo 占位使用 SF Symbol/文字首字母，不引入第三方品牌资产；状态、credential badge、模型数、usage 摘要。
- 点击进入 detail sheet，使用 Overview/Credentials/Models/Usage/Routing。
- Catalog 采用紧凑列表/卡片切换，能力 chip 最多两行，更多折叠。

### Runtime

- Hero 卡片继续沿用现有 Proxy 状态和端口控件。
- 下方摘要：Targets、Remote Nodes、Public Access、Recent Error。
- 高级 target 配置进入 detail，配置 diff 使用全宽 sheet/独立窗口，不塞入主面板。

### Agent

- Profiles 卡片展示能力和默认 RoutePolicy。
- Sessions 采用按日期分组列表。
- Tools 展示 MCP server 与工具权限。
- Live 是功能标志；未启用显示简洁说明，不显示空 Dashboard。

## 交互细节

- 所有危险操作先显示依赖影响。
- 测试模型按钮使用 secondary action；付费测试二次确认。
- 连接成功后 NoticeBanner，不弹阻塞 modal。
- 长日志/JSON/diff 在独立可复制 viewer 中，不破坏主面板滚动。
- Expert Mode 是全局偏好，也允许页内临时展开。
