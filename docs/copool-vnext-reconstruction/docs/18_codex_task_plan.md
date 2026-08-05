# 18. Codex 任务计划

| Task | 目标 | 依赖 | 主要验收 |
|---|---|---|---|
| T00 | 当前状态与基线 | 无 | inventory、build/test、fixtures、截图 |
| T01 | Swift 包和 façade | T00 | 无行为变化、依赖单向、现有测试通过 |
| T02 | Registry/Credential schema v2 | T01 | 无 secret Codable、v1 migration/rollback |
| T03 | Canonical Router Core | T01/T02 | 多协议 fixture、SSE/tool/reasoning/usage |
| T04 | Codex TargetAdapter 与安全边界 | T02/T03 | diff/apply/verify/rollback、capability 隔离 |
| T05 | Catalog/Routes/Usage | T02/T03/T04 | credential-aware catalog、decision trace |
| T06 | RouterHost | T03/T04 | UDS/loopback、service lifecycle、等价测试 |
| T07 | Cursor/opencode Targets | T04/T06 | Beta、独立状态/端口/配置 |
| T08 | Agent/Sessions/Tools/CUA | T03/T05 | 会话适配、原生执行边界、权限 |
| T09 | Voice/Realtime | T06/T08 | 插件化、隐私、task delegate |
| T10 | Remote/Release | 前述 | node handshake、CI、migration docs、release gate |

每个 task 的详细执行文本位于 `.codex/tasks/`。
