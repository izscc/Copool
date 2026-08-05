# AGENTS.md — Copool vNext 重构规则

## 任务

在不破坏现有用户数据、账号池、代理和原 UI 的前提下，按本包 PRD 完成 Copool vNext 分阶段重构。

## Clean-room 规则

- P2/P3 仅为公开行为和架构证据。
- 不复制其代码、测试、UI、图标、截图、文案、品牌或未明确许可的资产。
- 任何外部代码复用必须先核验许可证、记录来源和保留声明。

## 读取顺序

1. 目标仓库现有 AGENTS/README/Package.swift。
2. 本文件。
3. `docs/00_source_graph.md`、`01_evidence_log.md`。
4. `docs/03_prd.md`、`13_architecture_hypothesis.md`。
5. `docs/16_build_plan.md`、`28_acceptance_matrix.md`。
6. 当前 `.codex/tasks/phase-*.md`。

## 工作规则

- Phase 0 先基线、fixture、截图和当前状态清单。
- 先测试后迁移；采用 façade/strangler，不做无保护大爆炸重写。
- 不在领域模型或日志中保存 secret value。
- 不覆盖未标记用户配置；所有写入可 plan/diff/verify/rollback。
- 默认不执行付费 live test、不重启目标应用、不暴露公网端口。
- 顶层保持 5 个 Tab 和现有设计 token。
- 每阶段更新 decision log、migration log、tests 和 rollback 说明。
- 验证失败时停止进入下一阶段，但继续修复当前阶段，不把失败状态合入默认分支。

## 完成标准

以 `docs/28_acceptance_matrix.md` 为准。
