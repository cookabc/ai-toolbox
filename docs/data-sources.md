# 数据来源与统计口径

AI 工具台（AI Toolbox）从本机 Codex 与 Claude Code 日志读取用量，并在配置面板写入对应的供应商设置。

| 来源 | 默认路径 | 统计方式 |
| --- | --- | --- |
| Codex | `~/.codex/sessions`、`~/.codex/archived_sessions` | 读取 `token_usage_record.payload.usage`，按响应 ID 去重，模型通过 `turn_context` 关联 |
| Claude Code | `~/.claude/projects` | 读取主会话和 subagents 的 assistant usage，按消息 ID 与请求 ID 去重 |

这些数字是本机已记录用量，不是厂商账单或订阅额度。日志格式不兼容时可能无法读取；自动测试使用合成记录，不能证明所有工具版本均兼容。

「今日」按 macOS 本地日期计算。会话日志依据用量记录时间。无有效时间的日志记录只计入累计，并标注部分数据。缺失字段显示「—」，显式零值显示 `0`；今日与累计分别判断字段完整性。

Codex 与 Claude Code 的输入和缓存按来源字段分别显示，不推算非缓存输入，暂不提供回合及工具调用计数。界面最多展示四个模型。

日志按行读取，单行上限 1 MiB，不保留会话正文或工具参数，不跟随符号链接。已识别的超长非用量记录不会触发用量警告；无法确认类型、无法解析的用量记录仍会提示。未变化的会话文件集合复用内存快照；文件变化或跨日后重新扫描。首次扫描和活跃会话刷新耗时取决于历史记录规模。

## 供应商配置

供应商库保存在 `~/Library/Application Support/AIToolbox/providers.json`。面板切换供应商时，会更新下方「当前生效文件」中的对应项。

| 工具 | 当前生效文件 | 写入范围 |
| --- | --- | --- |
| Claude Code | `~/.claude/settings.json` | `env` 中的 `ANTHROPIC_BASE_URL`、`ANTHROPIC_MODEL`、`ANTHROPIC_API_KEY`；保存模型时若已有 `ANTHROPIC_DEFAULT_*` / `CLAUDE_CODE_SUBAGENT_MODEL` 则一并更新。清除覆盖项会删除上述 Key，其余 env 保留 |
| Codex | `~/.codex/config.toml` | 根级 `model`、`model_provider`，以及 `[model_providers.<id>]` 的 `name` / `base_url` / `wire_api` / `experimental_bearer_token`。其它段落原样保留。内置 `openai` 只能切换，不能删除 |

自定义 Codex 供应商 ID 在库内自动生成，不在列表卡片中展示。不能使用保留 ID：`openai`、`ollama`、`lmstudio`。Key 写入 `experimental_bearer_token`；不会改 `auth.json`。每次成功写入会在同路径覆盖 `.ai-toolbox.bak`。

写入 Claude Code 时，`ANTHROPIC_BASE_URL` 会去掉供应商 URL 末尾的 `/v1`（连同末尾斜杠）。Claude Code 会自行在 Base URL 后拼接 `/v1/messages`，若保留 `/v1` 就会请求到 `/v1/v1/messages` 并返回 404，而 Claude Code 把这个错误报告成「模型可能不存在或无权访问」，容易误判成模型问题。供应商库中仍按原样保存 URL，因为 Codex 需要 `/v1`。

切回内置 `openai` 时（点击「官方 OpenAI」，或删除当前生效的供应商），根级 `model` 会一并清除，让 Codex 使用自身默认模型。内置供应商使用 ChatGPT 账号登录，只接受 OpenAI 的模型 ID，若保留中转供应商的模型，每次请求都会返回 400。
