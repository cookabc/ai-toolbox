import Foundation

/// Every string the app shows, in the interface language: Simplified Chinese.
///
/// The interface has one language, chosen by the project rather than by the system:
/// the app was designed and written in Chinese, and `Info.plist` declares zh-Hans as
/// its only localization so the system pieces inside the panel — text-field menus,
/// Foundation's own error messages — come out in the same language instead of
/// following an English-first system list. Keeping the copy here, rather than at each
/// call site, is what keeps the views free of literals and makes a second language a
/// translation job instead of a hunt through the code.
///
/// What stays untranslated is what the user types or reads elsewhere verbatim:
/// product names (Codex, Claude Code, OpenAI), file names and paths, environment
/// variable and header names, HTTP status codes and units such as `ms`.
///
/// Typography follows the punctuation: a sentence — anything with a 。 — is running
/// text and is set in the system font; everything else is a label, set in the pixel
/// font, whose glyphs must cover it completely (`PixelDesignTests` checks).
enum L10n {
  /// Formatting locale for numbers, dates and times. It follows the interface
  /// language, not the system region: "Aug 4, 2026" in the middle of Chinese text
  /// reads as a bug.
  static let locale = Locale(identifier: "zh_Hans_CN")

  enum Common {
    static let expanded = "已展开"
    static let collapsed = "已收起"
    static let selected = "已选中"
    static let busy = "正在处理"
  }

  enum App {
    static let title = "AI 工具台"
    /// The bundle display name (`Info.plist`); Finder and the login items list show it.
    static let displayName = "AI Toolbox"

    /// What the menu-bar item says to VoiceOver.
    static func menuBarStatus(tool: String, todayOutput: String?) -> String {
      guard let todayOutput else { return "\(tool) 今日输出暂无" }
      return "\(tool) 今日输出 \(todayOutput)"
    }
  }

  enum Header {
    static func updated(_ time: String) -> String { "\(time) 更新" }
    static let reading = "正在读取…"
    static let readFailed = "读取失败"
    static let refreshUsage = "刷新用量（⌘R）"
    static let reloadConfig = "重新读取配置（⌘R）"
    static let openDataDirectory = "打开数据目录"
    static let quit = "退出 \(App.title)（⌘Q）"
    static let toolPicker = "选择工具"
    static let modePicker = "选择视图"
  }

  enum Mode {
    static let usage = "用量"
    static let config = "配置"
    static let usageHelp = "查看本机用量"
    static let configHelp = "管理供应商配置"
  }

  enum Usage {
    static let todayOutput = "今日输出"
    static let input = "输入"
    static let output = "输出"
    static let requests = "请求"
    static let turns = "回合"
    static let toolCalls = "工具调用"
    static let cacheRead = "缓存读"
    static let cacheWrite = "缓存写"
    static let uncached = "未缓存"
    static let reasoning = "推理"
    static let unknown = "—"

    static func todayOutputAccessibility(_ exact: String?) -> String {
      guard let exact else { return "今日输出暂无记录" }
      return "今日输出 \(exact) token"
    }

    static let composition = "输入构成"
    static func cacheHitRate(_ percent: String) -> String { "缓存命中 \(percent)" }
    static let noInputToday = "今日暂无输入"
    static func compositionAccessibility(read: String, write: String?, fresh: String) -> String {
      if let write { return "输入构成：缓存读 \(read)，缓存写 \(write)，未缓存 \(fresh)" }
      return "输入构成：缓存读 \(read)，未缓存 \(fresh)"
    }

    static let trend = "近 7 天输出"
    static func trendTotal(_ value: String) -> String { "合计 \(value)" }
    static let today = "今天"
    static func dayDetail(date: String, output: String, requests: String) -> String {
      "\(date) · 输出 \(output) token · \(requests) 次请求"
    }
    static func dayAccessibility(date: String, output: String) -> String { "\(date)，输出 \(output)" }

    static let lifetime = "累计用量"
    static func since(_ date: String) -> String { "自 \(date)" }
    static func activity(requests: String, turns: String, toolCalls: String) -> String {
      "\(requests) 次请求 · \(turns) 个回合 · \(toolCalls) 次工具调用"
    }

    static let models = "模型"
    static let byOutput = "按输出排序"
    static func topModels(_ shown: Int, of total: Int) -> String { "按输出 · 前 \(shown) / \(total)" }
    static func modelRequests(_ count: String) -> String { "\(count) 次请求" }
    static func modelAccessibility(id: String, output: String, requests: String) -> String {
      "\(id)，输出 \(output)，\(requests) 次请求"
    }

    static func exactTokens(_ exact: String) -> String { "\(exact) token" }
    static let footnote = "本机日志中记录的用量，不是账单或订阅额度。"
    static let retry = "重试"

    static let collapse = "收起"
    static let expand = "展开"
    static func toggleSection(_ title: String, expanded: Bool) -> String {
      expanded ? "收起\(title)" : "展开\(title)"
    }

    static let loadingTitle = "正在读取本地记录"
    static let loadingMessage = "第一次读取需要扫描全部历史记录，之后只读新增部分。"
    static let emptyTitle = "还没有用量数据"
    static func emptyMessage(_ tool: String) -> String { "等 \(tool) 写入用量记录后，这里会自动更新。" }
    static func unreadableTitle(_ tool: String) -> String { "暂时读不到 \(tool) 的记录" }
    static let reload = "重新读取"
    static let openRecords = "打开记录目录"

    static let staleAfterFailure = "刷新失败，显示的是上次成功读取的数据。"
    static let notReadToday = "今天还没有读取成功，今日数据暂缺。"
    static func skippedRecords(_ count: Int) -> String { "有 \(count) 条用量记录无法解析，统计可能偏少。" }
    static func undatedRecords(_ count: Int) -> String { "有 \(count) 条记录缺少时间，只计入累计。" }

    static func missingDirectory(_ tool: String) -> String {
      "未找到 \(tool) 的本地记录目录。用它完成一次对话后，这里就会有数据。"
    }
    static func noRecords(_ tool: String) -> String { "\(tool) 的记录目录存在，但还没有可识别的用量记录。" }
    static func incompatible(_ tool: String) -> String { "\(tool) 的记录无法解析，可能是日志格式有变化。" }
  }

  enum Config {
    static let noCodexHome = "没有找到 ~/.codex，Codex 可能还没在这台 Mac 上运行过。可以先保存供应商，运行一次 Codex 后再切换。"
    static let noCodexConfig = "还没有 ~/.codex/config.toml。切换到自定义供应商时会自动创建。"
    static let unmanagedCodex = "config.toml 中有未保存到供应商库的供应商。"
    static let unmanagedClaude = "当前生效的配置还没有保存为供应商。"
    static let importAction = "导入"

    static let officialOpenAI = "官方 OpenAI"
    static let officialOpenAIDetail = "ChatGPT 账号或 auth.json 登录"
    static let officialAnthropic = "官方 Anthropic"
    static let officialAnthropicDetail = "Claude 订阅或 Console 账号登录"
    static let officialCodexKey = "使用 auth.json / 官方登录"

    static let noCustomProviders = "还没有保存自定义供应商。"
    static let noProviders = "还没有保存的供应商。"
    static let addProvider = "新增供应商"
    static let noModel = "未指定模型"
    static let notSet = "未设置"
    static func environmentKey(_ name: String) -> String { "环境变量 \(name)" }

    static let active = "使用中"
    static let activeAccessibility = "正在使用"
    static let switchAction = "切换"
    static let switchHelp = "切换到这个供应商"
    static let switchToOfficialHelp = "切换回官方登录"
    static let test = "测试端点"
    static let edit = "编辑"
    static let delete = "删除"

    static let createTitle = "新增供应商"
    static let editTitle = "编辑供应商"
    static let name = "名称"
    static let namePlaceholder = "例如 公司网关"
    static let providerID = "供应商 ID"
    static let providerIDLockedNote = "config.toml 中的段名，保存后不可修改"
    static let providerIDNote = "config.toml 中的段名，可留空自动生成"
    static let providerIDPlaceholder = "例如 company-gateway"
    static let baseURL = "接口地址"
    static let baseURLPlaceholder = "https://…/v1"
    static let model = "模型"
    static let modelPlaceholder = "留空则不修改模型"
    static let apiKey = "API 密钥"
    static let apiKeyPlaceholder = "sk-…"
    static let keepKeyPlaceholder = "留空则保留现有密钥"
    static let hideKey = "隐藏密钥"
    static let revealKey = "显示已输入内容"
    static let credential = "认证方式"
    static let credentialAPIKey = "API 密钥"
    static let credentialAuthToken = "认证令牌"
    static let credentialAPIKeyHelp = "写入 ANTHROPIC_API_KEY，以 x-api-key 请求头发送；官方 API 用这种方式。"
    static let credentialAuthTokenHelp = "写入 ANTHROPIC_AUTH_TOKEN，以 Authorization: Bearer 请求头发送；多数中转站用这种方式。"
    static let advanced = "高级配置（Claude Code 环境变量）"
    static let advancedHelp = "留空表示这个供应商不接管该变量，切换时会交还给声明它的供应商。列表以外的环境变量始终原样保留。"
    static let notOwned = "未接管"
    static let fillAliases = "模型别名 = 上方模型"
    static let fillAliasesHelp = "把上面填写的模型写入全部 Claude Code 模型别名。只服务单一模型的中转站通常需要这样设置。"
    static let clearAll = "全部清空"
    static let save = "保存"
    static let saveAndSwitch = "保存并切换"
    static let cancel = "取消"

    static func deleteTitle(_ name: String) -> String { "删除供应商「\(name)」？" }
    static let deleteCodexMessage = "会从供应商库和 ~/.codex/config.toml 一并移除；如果它正在使用，Codex 会切回官方 OpenAI。"
    static let deleteClaudeMessage = "只从供应商库移除，Claude Code 当前生效的配置保持不变。"
    static let clearClaudeTitle = "切换回 Claude Code 官方登录？"
    static let clearClaudeMessage = "将从 ~/.claude/settings.json 移除接口地址、模型、API 密钥、模型别名，以及已保存供应商接管的密钥，让 Claude Code 回到它自己的登录。其余环境变量保留，供应商库不受影响。"
    static let clearClaudeConfirm = "清除并切换"

    static func savedAndSwitched(_ name: String) -> String { "已保存并切换到「\(name)」" }
    static func savedLiveUpdated(_ name: String) -> String { "已保存「\(name)」，当前生效的配置已同步更新" }
    static func savedLiveUnchanged(_ name: String) -> String { "已保存「\(name)」，当前生效的配置没有改变" }
    static func switched(_ name: String) -> String { "已切换到「\(name)」" }
    static let switchedToOfficialOpenAI = "已切换到官方 OpenAI"
    static func deleted(_ name: String) -> String { "已删除「\(name)」" }
    static func imported(_ count: Int) -> String { "已导入 \(count) 个现有配置" }
    static let nothingToImport = "没有需要导入的配置"
    static let clearedClaude = "已清除 Claude Code 的 API 覆盖项，恢复使用它自己的登录"
    static let importedClaudeName = "当前 Claude 配置"
    /// Joins a status line and the caveat it has to carry.
    static func withNote(_ text: String, _ note: String) -> String { "\(text)。\(note)" }
    static let keptHandWrittenCatalog = "保留了你手动设置的 model_catalog_json，所以没有把模型发布到 Codex 的模型列表"
    /// The description a published provider model carries in Codex's own model picker.
    static func catalogDescription(_ provider: String) -> String { "由 \(provider) 提供" }

    static func libraryUnreadable(path: String, reason: String) -> String { "无法读取供应商库（\(path)）：\(reason)" }
    static func claudeUnreadable(_ reason: String) -> String { "无法读取 ~/.claude/settings.json：\(reason)" }
    static let editedProviderGone = "要编辑的供应商已不在供应商库中。"
    static let fieldBaseURLScheme = "以 http:// 或 https:// 开头的接口地址"
    static let fieldProvider = "供应商信息"
  }

  enum Probe {
    static let running = "正在测试…"
    static let healthy = "可用"
    static let needsAuth = "凭据被拒"
    static let badRoute = "路由不存在"
    static let unsupported = "协议不支持"
    static let rejected = "请求被拒"
    static let unreachable = "无法连接"
    static func latency(_ milliseconds: Int) -> String { "\(milliseconds) ms" }
    static func status(_ code: Int) -> String { "HTTP \(code)" }

    static let unusableURL = "接口地址无法解析为可请求的 http/https 地址。"
    static let notHTTP = "响应不是 HTTP 响应。"
    static let healthyDetail = "端点可达，路由与凭据都正常。"
    static let needsAuthDetail = "路由存在，但凭据被拒绝——检查 API 密钥。"
    static let badRouteClaude = "Claude Code 会把这个 404 报成「模型不可用」。确认接口地址末尾没有多余的 /v1。"
    static let badRouteCodex = "Codex 按 wire_api = \"responses\" 请求 <接口地址>/responses，网关需要提供这个路径。"
    static func unsupportedDetail(_ tool: String) -> String { "网关不接受这个协议的请求，该供应商无法用于 \(tool)。" }
    static let rejectedDetail = "网关拒绝了请求。"
    static let unreachableDetail = "无法连接。"
    static func withServerMessage(_ explanation: String, _ server: String) -> String { "\(explanation) 服务端：\(server)" }
    static func timedOut(_ seconds: Int) -> String { "请求超时（\(seconds) 秒内没有响应）。" }
    static let dnsFailed = "域名解析失败，检查主机名。"
    static let cannotConnect = "无法建立连接，检查地址与端口。"
    static let offline = "当前没有网络连接。"
    static let atsBlocked = "系统策略阻止了明文 HTTP 请求。"
    static let tlsFailed = "TLS 握手失败或证书不受信任。"
  }

  enum Errors {
    static let invalidProviderID = "供应商 ID 只能使用英文字母、数字、连字符和下划线，以字母开头，最长 32 个字符。"
    static let reservedProviderID = "openai、ollama、lmstudio 是 Codex 内置 ID，不能用作自定义供应商。"
    static func duplicateProviderID(_ id: String) -> String { "已存在 ID 为 \(id) 的供应商。" }
    static func missingField(_ name: String) -> String { "请填写\(name)。" }
    static let missingCodexHome = "未找到 ~/.codex 目录。请先运行一次 Codex，再回来切换供应商。"
    static func missingModelCatalog(_ path: String) -> String {
      "Codex 还没有下载官方模型目录（\(path)）。目录条目必须自带系统指令，"
        + "所以这次没有把模型发布到 Codex 的模型列表；用官方登录运行一次 Codex 后重新切换即可。"
    }
    static func unparseableCodexConfig(line: Int) -> String {
      "~/.codex/config.toml 第 \(line) 行有无法解析的内容。为避免破坏配置，没有做任何修改。"
    }
    static func unsupportedCodexLayout(_ id: String) -> String {
      "config.toml 里的 \(id) 供应商不是用独立的 [model_providers.\(id)] 表定义的"
        + "（例如写成了内联表或点号键）。为避免产生重复定义，没有修改它。"
    }
    static func notUTF8(_ name: String) -> String { "\(name) 不是 UTF-8 文本，没有做任何修改。" }
    static let libraryUnreadable = "供应商库无法读取。为避免覆盖其中的内容，暂停保存供应商。"
    static func writeFailed(_ message: String) -> String { "写入配置失败：\(message)" }

    static func fileBusy(_ name: String) -> String { "\(name) 正在被其他程序频繁修改，请稍后重试。" }
    static func cannotCreateDirectory(_ path: String) -> String { "无法创建目录 \(path)。" }
    static func noWritePermission(_ path: String) -> String { "没有写入 \(path) 的权限。" }
    static func diskFull(_ name: String) -> String { "磁盘空间不足，\(name) 未写入。" }
    static func readOnlyVolume(_ path: String) -> String { "\(path) 所在的卷是只读的。" }
    static func fileError(_ name: String, _ reason: String) -> String { "\(name)：\(reason)" }

    static let settingsNotObject = "settings.json 不是一个 JSON 对象，未做修改。"
    static let settingsEnvNotObject = "settings.json 中的 env 字段不是对象，未做修改。"
    static let settingsInvalidResult = "生成的 settings.json 无法通过校验，未做修改。"
    static let settingsNotObjectForReading = "settings.json 不是一个 JSON 对象。"
  }
}
