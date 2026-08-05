# 04. 用户流程

## F1 添加第三方供应商

1. 进入“模型服务 > Providers”。
2. 选择供应商预设或自定义。
3. 选择认证方式；API Key 直接进入系统安全输入，不写入表单模型。
4. Copool 创建 CredentialIdentity 和 ProviderInstance。
5. 只做免费/只读的 endpoint 与 catalog 探测。
6. 用户从发现目录中策展模型。
7. 显示兼容性、能力来源和目标可用性。
8. 用户选择绑定 Codex/Cursor/opencode；先查看配置 diff，再 Apply。

## F2 自动路由 coding 任务

1. 用户在目标应用选择 `copool/auto-coding`。
2. Router 读取 target、session、工具/图像需求和预算。
3. 硬过滤无凭据、无工具、上下文不足或目标不兼容模型。
4. 按策略评分并选中模型实例和 credential identity。
5. 记录 decision trace；会话保持 affinity。
6. 429/5xx 根据策略失败转移；工具副作用请求不盲目重放。
7. UI 在“Routes > Recent Decisions”展示原因。

## F3 登录无关模式

1. 用户进入 Runtime > Targets > Codex。
2. 开启“外部模型模式”，系统检查至少一个 ready 的外部 ProviderInstance。
3. 预览将写入的托管块和模型别名。
4. Apply 后验证目录与服务；提示用户重启 Codex。
5. 关闭时精确恢复原 model/model_provider，并保留 ChatGPT 凭据未触碰。

## F4 导入外部 Agent 会话

1. Agent > Sessions > Import。
2. 扫描支持的来源并展示路径、数量和更新时间。
3. 用户预览单个会话的可映射字段和缺失字段。
4. 导入索引与引用；默认不复制原始附件。
5. 去重后加入统一搜索；打开详情可继续/导出。

## F5 Voice 委派任务

1. Agent > Live 开始实时对话。
2. VAD/STT 生成对话事件；用户提出 coding 任务。
3. Realtime 模型生成 `TaskEnvelope`，用户确认后委派。
4. Route Engine 为任务选择 coding model/Agent Profile。
5. 任务执行进度回传 Voice UI；语音会话与执行会话保持独立 ID 和权限。

## F6 Doctor 与回滚

1. Settings > Diagnostics > Run Doctor。
2. 分层检查文件、权限、服务、端口、配置、目录和路由。
3. 可安全自动修复项提供一键修复；危险项只给说明。
4. 若目标配置失败，选择 Restore Previous Snapshot。
5. 回滚后重新 verify，并生成脱敏报告。
