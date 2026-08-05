# 26. 供应商与认证矩阵

> 模型名称不作为长期硬编码。以下是 ProviderDefinition/认证面的产品范围。

| Provider Family / Instance | 认证 | 主要协议 | 目录 | 首发级别 |
|---|---|---|---|---|
| OpenAI Native / ChatGPT Accounts | Codex/ChatGPT 登录 | Responses native | 原生目录合并 | P0 |
| Generic OpenAI-compatible | API key/env/secure file | Chat/Responses | `/models`/手工 | P0 |
| Anthropic | API key/可识别订阅导入 | Messages | 手工/live | P0 |
| Google Gemini | API key | Gemini native/OpenAI-compatible | live | P0 |
| DeepSeek | API key | OpenAI-compatible | live/registry | P0 |
| Kimi Platform | API key | OpenAI-compatible | live/registry | P0 |
| Kimi Code | 外部 CLI OAuth | OAuth forward | credential-aware | P1 |
| xAI Grok API | API key | OpenAI-compatible | live | P1 |
| xAI Grok OAuth | 外部 CLI OAuth | OAuth forward | credential-aware | P1 |
| Qwen/DashScope | plan/PAYG key | OpenAI-compatible | live | P0 |
| Z.ai | coding/general key | OpenAI-compatible | live | P0 |
| MiniMax | API/token plan key | OpenAI-compatible/特殊适配 | live | P0 |
| OpenRouter | API key | OpenAI-compatible | live 策展 | P0 |
| Volcengine Ark | API key | OpenAI-compatible | endpoint/手工 | P0 |
| Ollama Cloud | API key | OpenAI-compatible | live 策展 | P1 |
| Groq/Together/Fireworks/Cerebras/Mistral/NVIDIA/SiliconFlow/HF Router | API key | OpenAI-compatible | live 策展 | P1 |
| opencode Go | API key | Chat/Messages/Responses variant | live/手工 | P1 |
| Local Ollama/LM Studio | 无/本地 key | OpenAI-compatible | live | P1（通用预设） |
| Cursor/Claude/Antigravity subscription import | 外部会话引用 | 供应商特定 | 探测 | P1/实验 |

## Registry 字段

- id/displayName/owner/kind/protocols/default endpoints/base URL env override。
- credential sources（env、Keychain service、external session path、protected file）。
- discovery strategy、quota/rate-limit parser、balance URL（若存在）。
- headers allowlist、required headers、regional variants。
- compatibility notes、lastVerifiedAt、registryVersion。
