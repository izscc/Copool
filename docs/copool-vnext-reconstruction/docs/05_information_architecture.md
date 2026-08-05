# 05. 信息架构

## 顶层结构（保持 5 个主 Tab）

```text
Copool
├─ 账号 Accounts
│  ├─ 账号池
│  ├─ 配额概览
│  ├─ 导入/切换
│  └─ 账号策略
├─ 模型服务 Models
│  ├─ Providers
│  ├─ Catalog
│  ├─ Routes
│  └─ Usage
├─ 运行时 Runtime
│  ├─ Overview
│  ├─ Targets
│  ├─ Remote Nodes
│  ├─ Public Access
│  └─ Logs
├─ Agent
│  ├─ Profiles
│  ├─ Sessions
│  ├─ Tools & MCP
│  └─ Live / Voice
└─ 设置 Settings
   ├─ General
   ├─ Security
   ├─ Diagnostics
   └─ Advanced
```

## 导航规则

- 顶层继续使用 P1 胶囊图标切换器，不加文字常驻，accessibility label 保留。
- 二级导航使用紧凑 segmented control 或横向 scroll chips。
- 列表到详情使用 `NavigationStack`/sheet，不在固定宽度上并列三栏。
- 高风险操作统一在 detail sheet 中预览影响和 diff。
- 全局 Usage Summary 只显示 2–4 个最重要指标；详细图表进入 Usage。

## 搜索与命令

- Catalog、Sessions、Logs 提供局部搜索。
- P1 后续可增加 Command Palette，但不作为 P0 阻塞项。
