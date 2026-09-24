# 数据来源与统计口径

AI 工具台（AI Toolbox）从本机 Codex 与 Claude Code 日志读取用量，并在配置面板写入对应的供应商设置。

## 用量

| 来源 | 默认路径 | 统计方式 |
| --- | --- | --- |
| Codex | `~/.codex/sessions`、`~/.codex/archived_sessions` | 读取 `token_usage_record.payload.usage`，按响应 ID 去重；模型通过回合 ID 关联 `turn_context` |
| Claude Code | `~/.claude/projects` | 读取主会话和 subagents 的 assistant usage，按消息 ID 与请求 ID 去重 |

这些数字是本机已记录用量，不是厂商账单或订阅额度。日志格式不兼容时可能无法读取；自动测试使用合成记录，不能证明所有工具版本均兼容。

### 各项指标

| 指标 | 含义 |
| --- | --- |
| 输入 | 整段提示的 token，包含命中缓存的部分。Codex 的 `input_tokens` 已包含 `cached_input_tokens`；Claude Code 的 `input_tokens` 只是缓存之外的部分，应用会加上 `cache_read_input_tokens` 与 `cache_creation_input_tokens` |
| 缓存读 / 缓存写 | 命中缓存与写入缓存的输入 token，都是「输入」的一部分。「未缓存」是输入减去这两项 |
| 输出 | 模型生成的 token |
| 推理 | 输出中的推理（thinking）部分，包含在「输出」之内 |
| 请求 | 去重后的模型响应数 |
| 回合 | Codex：不同的回合 ID。Claude Code：用户输入的一条提示，或模型被要求处理的一条通知；工具结果、元信息、本地斜杠命令和 subagent 收到的任务说明不算 |
| 工具调用 | Codex：`response_item` 中类型以 `_call` 结尾的条目，按调用 ID 去重。Claude Code：assistant 消息里的 `tool_use` 块，按块 ID 去重 |

Claude Code 为错误和中断自行写入的 `<synthetic>` 消息没有请求到达模型，不计入请求。

「今日」与「近 7 天」按 macOS 本地日期计算，依据每条记录自己的时间。没有有效时间的记录只计入累计，面板会提示条数。某项指标如果没有任何记录提供，显示「—」；显式的零值显示 `0`。界面最多展示四个模型。

### 读取方式

日志按行读取，不保留会话正文或工具参数，不跟随符号链接。单行上限 64 MiB；超长或无法解析的行如果是用量记录，会计入「无法解析」并在面板提示，其他类型的行直接跳过。

第一次读取会扫描全部历史记录。之后每个文件都从上次读到的位置继续：文件只追加时，一次刷新只读新增的字节。文件变小、被替换，或开头与已读部分末尾的字节发生变化时，重新完整读取该文件。最后一行还没写完换行时会先计入，写完后按 ID 替换，不会重复计数。跨过本地午夜时重新按日期汇总。

## 供应商配置

供应商库保存在 `~/Library/Application Support/AIToolbox/providers.json`。面板切换供应商时，会更新下方「当前生效文件」中的对应项。

| 工具 | 当前生效文件 | 写入范围 |
| --- | --- | --- |
| Claude Code | `~/.claude/settings.json` | `env` 中的 `ANTHROPIC_BASE_URL`、`ANTHROPIC_MODEL`、`ANTHROPIC_API_KEY` 或 `ANTHROPIC_AUTH_TOKEN`，以及该供应商在「高级配置」中声明接管的 Key。列表以外的 env 项一律原样保留 |
| Codex | `~/.codex/config.toml` | 根级 `model`、`model_provider`、`model_catalog_json`，以及 `[model_providers.<id>]` 的 `name`、`base_url`、`wire_api`、`experimental_bearer_token`。其它段落原样保留。内置 `openai` 只能切换，不能删除 |

### 写入方式

- 每次写入前重新读取文件的最新内容，只修改上表中的键，然后写入临时文件并以原子重命名替换原文件。如果读取与写入之间文件被其他程序改动，会基于新内容重做这次修改，不会覆盖对方的改动。
- `settings.json` 只替换 `env` 对象；其他键的顺序、格式和值保持原样，未改动的 env 项保留原来的写法和类型。
- `config.toml` 保留注释、空行、键的写法和顺序。文件中有无法解析的内容时，面板指出行号，不做任何修改。某个供应商如果写成了内联表或点号键，而不是独立的 `[model_providers.<id>]` 表，面板不会修改它，以免产生重复定义。
- 目标文件是符号链接时，写入链接指向的文件，链接本身保留。
- 每次成功写入会在同目录覆盖 `.ai-toolbox.bak`，保存写入前的内容。
- 写入的文件权限为 `0600`，因为其中包含 API Key。

### Claude Code

写入 `ANTHROPIC_BASE_URL` 时会去掉供应商 URL 末尾的 `/v1`（连同末尾斜杠）。Claude Code 会自行在 Base URL 后拼接 `/v1/messages`，若保留 `/v1` 就会请求到 `/v1/v1/messages` 并返回 404，而 Claude Code 把这个错误报告成「模型可能不存在或无权访问」，容易误判成模型问题。供应商库中仍按原样保存 URL，因为 Codex 需要 `/v1`。

每个供应商可以选择认证方式：

| 认证方式 | 写入的变量 | Claude Code 发送的请求头 |
| --- | --- | --- |
| API Key | `ANTHROPIC_API_KEY` | `x-api-key` |
| Auth Token | `ANTHROPIC_AUTH_TOKEN` | `Authorization: Bearer` |

两个变量互斥，切换时只保留一个。没有填写 Key 的供应商会移除现有的 Key，避免把上一个供应商的 Key 发给新的地址。「导入当前配置」会按 `settings.json` 中实际存在的变量记录认证方式。

每个供应商还可以额外声明自己接管的 env Key（编辑供应商 → 「高级配置」），可选范围为：

```
ANTHROPIC_DEFAULT_OPUS_MODEL      ANTHROPIC_DEFAULT_SONNET_MODEL
ANTHROPIC_DEFAULT_HAIKU_MODEL     ANTHROPIC_DEFAULT_FABLE_MODEL
CLAUDE_CODE_SUBAGENT_MODEL        CLAUDE_CODE_MAX_CONTEXT_TOKENS
CLAUDE_CODE_AUTO_COMPACT_WINDOW   CLAUDE_CODE_EFFORT_LEVEL
```

规则：

- 切换供应商时，只写入该供应商声明接管的 Key，不会把供应商的单个模型广播到已有的 `ANTHROPIC_DEFAULT_*` / `CLAUDE_CODE_SUBAGENT_MODEL` 上。
- 留空表示不接管。若某个 Key 被 A 供应商声明、B 供应商未声明，切到 B 时会删除该 Key，避免 A 的模型名残留在 B 上。
- 名单以外的 env 项，以及没有任何供应商声明的 Key，任何情况下都不会被改写或删除。
- 只服务单一模型的中转站，可以用「模型别名 = 上方模型」一键把 5 个模型别名都指向该供应商的模型。
- 「导入当前配置」会把 `settings.json` 中现有的上述 Key 一并记录到新供应商里，因此导入一份可用配置不会丢掉一半设置。

「清除 API 覆盖项」会删除 Base URL、模型、两个认证变量、全部模型别名，以及任一已保存供应商声明接管的 Key，让 Claude Code 回到它自己的登录。没有供应商声明的 Key 保留。

### Codex

- 自定义供应商的 ID 就是 `config.toml` 中的段名。新增时可以留空自动生成：非拉丁字符会转写成拉丁字母（例如「智谱」生成 `zhi-pu`），并避开已保存的供应商和 `config.toml` 中已有的段，以免意外接管手写的配置。ID 保存后不能修改。不能使用保留 ID：`openai`、`ollama`、`lmstudio`。
- Key 写入 `experimental_bearer_token`，同时移除该段的 `env_key`，确保面板显示的 Key 就是 Codex 实际发送的 Key。编辑时留空 Key 表示保留原有凭据。
- `wire_api` 只在新建段落时写入 `"responses"`；已有的值不会被改写。
- 保存时如果这个供应商正在使用，当前生效的配置会一并更新。没有在使用、但 `config.toml` 中已有对应段落的供应商，只同步该段落，不切换。
- `~/.codex` 存在但没有 `config.toml` 时，第一次切换会创建它。`~/.codex` 不存在时，面板提示先运行一次 Codex。

切回内置 `openai` 时（点击「官方 OpenAI」，或删除当前生效的供应商），会恢复第一次切离官方登录前使用的 `model`；没有记录时移除 `model`，让 Codex 使用自身默认模型。内置供应商使用 ChatGPT 账号登录，只接受 OpenAI 的模型 ID，若保留中转供应商的模型，每次请求都会返回 400。

### 端点测试

供应商卡片上的闪电按钮会向该供应商实际生效的地址发一次请求，显示真实 HTTP 状态与耗时。

| 工具 | 请求地址 | 依据 |
| --- | --- | --- |
| Claude Code | Base URL 去掉 `/v1` 后 + `/v1/messages` | 与 Claude Code 自身的拼接规则一致；按认证方式发送 `x-api-key` 或 `Authorization: Bearer` |
| Codex | Base URL + `/responses` | 与写入的 `wire_api = "responses"` 一致 |

请求体只索取极少的 token，足以确认路由与凭据，费用可忽略。判定口径：

| 状态 | 含义 |
| --- | --- |
| 2xx | 端点可达，路由与凭据正常 |
| 401 / 403 | 路由存在，API Key 不对 |
| 404 | 路由不存在。Claude Code 会把这个 404 报成「模型不可用」，容易误判 |
| 405 / 501 | 网关不支持该协议，这个供应商无法用于该工具 |
| 其它 4xx / 5xx | 网关拒绝；界面会附带服务端返回的错误信息 |
| 连接失败 | 区分超时、DNS、端口、明文 HTTP 被系统策略阻止、TLS 失败 |

测试不写入任何配置文件，也不复用用量读取的缓存，只发一次真实网络请求。

中转供应商常是局域网或内网明文 HTTP 地址，因此 `Info.plist` 中开启了 `NSAppTransportSecurity` → `NSAllowsArbitraryLoads`。仅设置 `NSAllowsLocalNetworking` 不够：它只覆盖 `.local` 名称与链路本地地址，不覆盖 `192.168.x.x` / `10.x.x.x`。这是为端点测试做的取舍；若只使用 HTTPS 供应商，可以移除该键。
