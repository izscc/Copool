# Phase 04 — Target 隔离、配置与 Doctor

目标：实现 TargetBinding 和 Codex TargetAdapter。

- 每 target caller/internal capability、state、listener、provider selection。
- detect/plan/diff/apply/verify/rollback/uninstall。
- 只写 marked blocks，保留原生配置。
- UDS/127.0.0.1、Origin reject、no CORS。
- Doctor P0 和脱敏支持包。

验收：AC-006/007/008/009/010/014；故障注入后可恢复。
