# Copool vNext 重构交付包

本包把三个公开项目的能力证据整理成一个可执行、clean-room 的 Copool vNext 产品与开发方案。

## 最快使用

- 产品与架构总览：`COPool_vNext_PRD.md`
- 直接交给 Codex：`CODEX_MASTER_GOAL.md`
- 完整 PRD：`docs/03_prd.md`
- UI 融合：`docs/29_ui_integration_blueprint.md`
- 数据与 API：`docs/11_data_model.md`、`docs/12_api_contracts.md`
- 供应商：`docs/26_provider_matrix.md`
- 分阶段任务：`.codex/tasks/`
- 验收：`docs/28_acceptance_matrix.md`

## 使用方式

1. 将整个目录复制到 Copool 仓库根目录的 `docs/copool-vnext/`，或让 Codex 可以读取本目录。
2. 把 `CODEX_MASTER_GOAL.md` 作为 Codex Goal。
3. Codex 必须先完成 Phase 0 基线，不允许直接大规模删改。
4. 每个阶段按 `.codex/tasks` 执行并通过验收后进入下一阶段。

## 研究限制

这是公开证据驱动的原创重构方案。P2/P3 的实现、UI 和资产不应直接复制。供应商与模型信息会变化，落地时必须重新验证。
