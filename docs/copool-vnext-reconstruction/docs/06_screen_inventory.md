# 06. 屏幕清单

| 屏幕 | 主要组件 | 关键状态 | 优先级 |
|---|---|---|---|
| Accounts Pool | 账号卡片、液体进度、切换按钮 | loading/ready/limited/expired | 保留/P0 |
| Providers List | 供应商卡片、credential badge、健康、模型数 | ready/missing credential/degraded | P0 |
| Provider Detail | Overview/Credentials/Models/Usage/Routing | edit/test/discover/delete impact | P0 |
| Model Catalog | 搜索、筛选、策展、能力 badge | discovered/curated/hidden/incompatible | P0 |
| Route Policies | 策略列表、优先级、约束、failover | draft/active/invalid | P0 |
| Route Decision Detail | candidates、filter reasons、scores、retry | success/failover/rejected | P0 |
| Runtime Overview | 服务状态、端口、target 数、最近错误 | stopped/starting/running/degraded | P0 |
| Target Detail | detect/diff/apply/verify/rollback | unmanaged/planned/managed/drifted | P0 |
| Remote Nodes | 节点卡片、版本、能力、负载 | offline/outdated/healthy | P1 |
| Agent Profiles | profile 卡片、capabilities、model policy | valid/missing tool/missing model | P1 |
| Session Center | 搜索、来源、时间、模型、导入 | indexing/duplicate/missing source | P1 |
| Tools & MCP | server/tool 列表、权限、目标绑定 | available/disabled/error | P1 |
| Live | 波形/状态、会话、委派卡片 | permission/recording/thinking/executing | P2 |
| Usage | 时间范围、provider/model/target breakdown | observed/vendor/estimated | P1 |
| Diagnostics | Doctor sections、fix、support bundle | pass/warn/fail | P0 |
