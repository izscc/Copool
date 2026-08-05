# Phase 08 — Voice 与 Realtime

目标：插件化实现 STT/TTS/VAD、Realtime 和 TaskEnvelope 委派。

- 未启用不请求权限、不加载服务。
- 录音状态、取消、隐私、默认不持久化。
- Realtime conversation 与 coding execution 会话/权限分离。
- TaskEnvelope 必须用户确认后执行。

验收：AC-201 至 AC-203；权限/取消/网络故障/音频清理测试。
