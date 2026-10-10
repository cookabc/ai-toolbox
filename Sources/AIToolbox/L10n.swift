import Foundation

/// Every string the app shows, in the interface language: English.
///
/// The interface has one language, chosen by the project rather than by the system:
/// the app ships in English, and `Info.plist` declares `en` as its only localization
/// so the system pieces inside the panel — text-field menus, Foundation's own error
/// messages — come out in the same language instead of following a non-English
/// system language list. Keeping the copy here, rather than at each call site, is
/// what keeps the views free of literals and makes a second language a translation
/// job instead of a hunt through the code.
///
/// What stays untranslated is what the user types or reads elsewhere verbatim:
/// product names (Codex, Claude Code, OpenAI), file names and paths, environment
/// variable and header names, HTTP status codes and units such as `ms`.
///
/// Running text — notices, explanations, error messages — is set in the system font,
/// which reads better than any 12-pixel face at paragraph length; titles, labels and
/// numbers are pixel type. `PixelDesignTests` proves the bundled pixel font draws
/// every literal below, labels included.
enum L10n {
  /// Formatting locale for numbers, dates and times. It follows the interface
  /// language, not the system region: a date in the middle of the panel should read
  /// the way the rest of the copy does.
  static let locale = Locale(identifier: "en_US")

  enum Common {
    static let expanded = "Expanded"
    static let collapsed = "Collapsed"
    static let selected = "Selected"
    static let busy = "Working"
  }

  enum App {
    static let title = "AI Toolbox"
    /// The bundle display name (`Info.plist`); Finder and the login items list show it.
    static let displayName = "AI Toolbox"

    /// What the menu-bar item says to VoiceOver.
    static func menuBarStatus(tool: String, todayOutput: String?) -> String {
      guard let todayOutput else { return "\(tool), no output today" }
      return "\(tool), \(todayOutput) output today"
    }
  }

  enum Header {
    static func updated(_ time: String) -> String { "Updated \(time)" }
    static let reading = "Reading…"
    static let readFailed = "Read failed"
    static let refreshUsage = "Refresh usage (⌘R)"
    static let reloadConfig = "Reload configuration (⌘R)"
    static let openDataDirectory = "Open data directory"
    static let quit = "Quit \(App.title) (⌘Q)"
    static let toolPicker = "Choose tool"
    static let modePicker = "Choose view"
  }

  enum Mode {
    static let usage = "Usage"
    static let config = "Config"
    static let usageHelp = "View local usage"
    static let configHelp = "Manage provider configuration"
  }

  enum Usage {
    static let todayOutput = "Today's output"
    static let input = "Input"
    static let output = "Output"
    static let requests = "Requests"
    static let turns = "Turns"
    static let toolCalls = "Tool calls"
    static let cacheRead = "Cache read"
    static let cacheWrite = "Cache write"
    static let uncached = "Uncached"
    static let reasoning = "Reasoning"
    static let unknown = "—"

    static func todayOutputAccessibility(_ exact: String?) -> String {
      guard let exact else { return "No output recorded today" }
      return "Today's output \(exact) tokens"
    }

    static let composition = "Input composition"
    static func cacheHitRate(_ percent: String) -> String { "Cache hit \(percent)" }
    static let noInputToday = "No input today"
    static func compositionAccessibility(read: String, write: String?, fresh: String) -> String {
      if let write { return "Input composition: cache read \(read), cache write \(write), uncached \(fresh)" }
      return "Input composition: cache read \(read), uncached \(fresh)"
    }

    static let trend = "Output, last 7 days"
    static func trendTotal(_ value: String) -> String { "Total \(value)" }
    static let today = "Today"
    static func dayDetail(date: String, output: String, requests: String) -> String {
      "\(date) · \(output) tokens output · \(requests) requests"
    }
    static func dayAccessibility(date: String, output: String) -> String { "\(date), output \(output)" }

    static let lifetime = "Lifetime usage"
    static func since(_ date: String) -> String { "Since \(date)" }
    static func activity(requests: String, turns: String, toolCalls: String) -> String {
      "\(requests) requests · \(turns) turns · \(toolCalls) tool calls"
    }

    static let models = "Models"
    static let byOutput = "Sorted by output"
    static func topModels(_ shown: Int, of total: Int) -> String { "By output · top \(shown) of \(total)" }
    static func modelRequests(_ count: String) -> String { "\(count) requests" }
    static func modelAccessibility(id: String, output: String, requests: String) -> String {
      "\(id), output \(output), \(requests) requests"
    }

    static func exactTokens(_ exact: String) -> String { "\(exact) tokens" }
    static let footnote = "Usage recorded in this Mac's logs, not a bill or subscription quota."
    static let retry = "Retry"

    static let collapse = "Collapse"
    static let expand = "Expand"
    static func toggleSection(_ title: String, expanded: Bool) -> String {
      expanded ? "Collapse \(title)" : "Expand \(title)"
    }

    static let loadingTitle = "Reading local records"
    static let loadingMessage = "The first read scans the whole history; after that only new records are read."
    static let emptyTitle = "No usage data yet"
    static func emptyMessage(_ tool: String) -> String { "Once \(tool) writes usage records, this updates on its own." }
    static func unreadableTitle(_ tool: String) -> String { "Can't read \(tool) records right now" }
    static let reload = "Read again"
    static let openRecords = "Open records folder"

    static let staleAfterFailure = "Refresh failed; showing the last successful read."
    static let notReadToday = "Nothing has been read successfully today, so today's data is missing."
    static func skippedRecords(_ count: Int) -> String { "\(count) usage records could not be parsed; totals may be understated." }
    static func undatedRecords(_ count: Int) -> String { "\(count) records have no timestamp and count only toward lifetime totals." }

    static func missingDirectory(_ tool: String) -> String {
      "No local records folder found for \(tool). Finish one conversation with it and data will appear here."
    }
    static func noRecords(_ tool: String) -> String { "The \(tool) records folder exists, but holds no recognizable usage records yet." }
    static func incompatible(_ tool: String) -> String { "\(tool) records cannot be parsed; the log format may have changed." }
  }

  enum Config {
    static let noCodexHome = "~/.codex was not found — Codex may not have run on this Mac yet. You can save a provider now and switch once Codex has run."
    static let noCodexConfig = "There is no ~/.codex/config.toml yet. It is created automatically when you switch to a custom provider."
    static let unmanagedCodex = "config.toml has providers that are not saved in the provider library."
    static let unmanagedClaude = "The configuration in effect is not saved as a provider yet."
    static let importAction = "Import"

    static let officialOpenAI = "Official OpenAI"
    static let officialOpenAIDetail = "ChatGPT account or auth.json sign-in"
    static let officialAnthropic = "Official Anthropic"
    static let officialAnthropicDetail = "Claude subscription or Console account sign-in"
    static let officialCodexKey = "Uses auth.json / official sign-in"

    static let noCustomProviders = "No custom providers saved yet."
    static let noProviders = "No saved providers yet."
    static let addProvider = "Add provider"
    static let noModel = "No model set"
    static let notSet = "Not set"
    static func environmentKey(_ name: String) -> String { "Environment variable \(name)" }

    static let active = "In use"
    static let activeAccessibility = "Currently in use"
    static let switchAction = "Switch"
    static let switchHelp = "Switch to this provider"
    static let switchToOfficialHelp = "Switch back to the official sign-in"
    static let test = "Test endpoint"
    static let edit = "Edit"
    static let delete = "Delete"

    static let createTitle = "Add provider"
    static let editTitle = "Edit provider"
    static let name = "Name"
    static let namePlaceholder = "e.g. Company gateway"
    static let providerID = "Provider ID"
    static let providerIDLockedNote = "The section name in config.toml; it cannot be changed after saving"
    static let providerIDNote = "The section name in config.toml; leave blank to generate one"
    static let providerIDPlaceholder = "e.g. company-gateway"
    static let baseURL = "Base URL"
    static let baseURLPlaceholder = "https://…/v1"
    static let model = "Model"
    static let modelPlaceholder = "Leave blank to keep the current model"
    static let apiKey = "API key"
    static let apiKeyPlaceholder = "sk-…"
    static let keepKeyPlaceholder = "Leave blank to keep the existing key"
    static let hideKey = "Hide key"
    static let revealKey = "Show what you typed"
    static let credential = "Authentication"
    static let credentialAPIKey = "API key"
    static let credentialAuthToken = "Auth token"
    static let credentialAPIKeyHelp = "Writes ANTHROPIC_API_KEY and sends it as the x-api-key header; the official API uses this."
    static let credentialAuthTokenHelp = "Writes ANTHROPIC_AUTH_TOKEN and sends it as the Authorization: Bearer header; most relays use this."
    static let advanced = "Advanced (Claude Code environment variables)"
    static let advancedHelp = "Blank means this provider does not take over that variable, and switching hands it back to the provider that declares it. Environment variables outside this list are always preserved as they are."
    static let notOwned = "Not owned"
    static let fillAliases = "Model aliases = the model above"
    static let fillAliasesHelp = "Writes the model above into every Claude Code model alias. Relays that serve a single model usually need this."
    static let clearAll = "Clear all"
    static let save = "Save"
    static let saveAndSwitch = "Save and switch"
    static let cancel = "Cancel"

    static func deleteTitle(_ name: String) -> String { "Delete provider \"\(name)\"?" }
    static let deleteCodexMessage = "This removes it from the provider library and from ~/.codex/config.toml; if it is in use, Codex switches back to official OpenAI."
    static let deleteClaudeMessage = "This removes it from the provider library only; Claude Code's configuration in effect is left unchanged."
    static let clearClaudeTitle = "Switch back to Claude Code's official sign-in?"
    static let clearClaudeMessage = "This removes the base URL, model, API key, model aliases and any keys owned by saved providers from ~/.claude/settings.json, so Claude Code returns to its own sign-in. Other environment variables are kept and the provider library is untouched."
    static let clearClaudeConfirm = "Clear and switch"

    static func savedAndSwitched(_ name: String) -> String { "Saved and switched to \"\(name)\"" }
    static func savedLiveUpdated(_ name: String) -> String { "Saved \"\(name)\"; the configuration in effect was updated too" }
    static func savedLiveUnchanged(_ name: String) -> String { "Saved \"\(name)\"; the configuration in effect is unchanged" }
    static func switched(_ name: String) -> String { "Switched to \"\(name)\"" }
    static let switchedToOfficialOpenAI = "Switched to official OpenAI"
    static func deleted(_ name: String) -> String { "Deleted \"\(name)\"" }
    static func imported(_ count: Int) -> String { "Imported \(count) existing configurations" }
    static let nothingToImport = "Nothing to import"
    static let clearedClaude = "Cleared Claude Code's API overrides; it uses its own sign-in again"
    static let importedClaudeName = "Current Claude configuration"
    /// Joins a status line and the caveat it has to carry.
    static func withNote(_ text: String, _ note: String) -> String { "\(text). \(note)" }
    static let keptHandWrittenCatalog = "Your hand-written model_catalog_json was kept, so the model was not published to Codex's model list"
    /// The description a published provider model carries in Codex's own model picker.
    static func catalogDescription(_ provider: String) -> String { "Provided by \(provider)" }

    static func libraryUnreadable(path: String, reason: String) -> String { "Cannot read the provider library (\(path)): \(reason)" }
    static func claudeUnreadable(_ reason: String) -> String { "Cannot read ~/.claude/settings.json: \(reason)" }
    static let editedProviderGone = "The provider being edited is no longer in the provider library."
    static let fieldBaseURLScheme = "a base URL beginning with http:// or https://"
    static let fieldProvider = "provider details"
  }

  enum Probe {
    static let running = "Testing…"
    static let healthy = "Working"
    static let needsAuth = "Credentials rejected"
    static let badRoute = "No such route"
    static let unsupported = "Protocol unsupported"
    static let rejected = "Request rejected"
    static let unreachable = "Unreachable"
    static func latency(_ milliseconds: Int) -> String { "\(milliseconds) ms" }
    static func status(_ code: Int) -> String { "HTTP \(code)" }

    static let unusableURL = "The base URL does not resolve to a requestable http/https address."
    static let notHTTP = "The response is not an HTTP response."
    static let healthyDetail = "The endpoint is reachable and both the route and the credentials are fine."
    static let needsAuthDetail = "The route exists but the credentials were rejected — check the API key."
    static let badRouteClaude = "Claude Code reports this 404 as \"model unavailable\". Make sure the base URL has no extra /v1 at the end."
    static let badRouteCodex = "Codex requests <base URL>/responses with wire_api = \"responses\", so the gateway has to serve that path."
    static func unsupportedDetail(_ tool: String) -> String { "The gateway does not accept this protocol, so the provider cannot be used with \(tool)." }
    static let rejectedDetail = "The gateway rejected the request."
    static let unreachableDetail = "Could not connect."
    static func withServerMessage(_ explanation: String, _ server: String) -> String { "\(explanation) Server: \(server)" }
    static func timedOut(_ seconds: Int) -> String { "The request timed out (no response within \(seconds) seconds)." }
    static let dnsFailed = "DNS lookup failed; check the host name."
    static let cannotConnect = "Could not connect; check the address and the port."
    static let offline = "There is no network connection."
    static let atsBlocked = "System policy blocked the plain-HTTP request."
    static let tlsFailed = "The TLS handshake failed or the certificate is not trusted."
  }

  enum Errors {
    static let invalidProviderID = "A provider ID may use only ASCII letters, digits, hyphens and underscores, has to start with a letter, and is at most 32 characters."
    static let reservedProviderID = "openai, ollama and lmstudio are built into Codex and cannot be used for a custom provider."
    static func duplicateProviderID(_ id: String) -> String { "A provider with the ID \(id) already exists." }
    static func missingField(_ name: String) -> String { "Enter \(name)." }
    static let missingCodexHome = "The ~/.codex directory was not found. Run Codex once, then come back and switch providers."
    static func missingModelCatalog(_ path: String) -> String {
      "Codex has not downloaded the official model catalog yet (\(path)). A catalog entry has to carry its own system instructions, "
        + "so the model was not published to Codex's model list this time; run Codex once with the official sign-in and switch again."
    }
    static func unparseableCodexConfig(line: Int) -> String {
      "Line \(line) of ~/.codex/config.toml cannot be parsed. Nothing was changed, so the configuration is left intact."
    }
    static func unsupportedCodexLayout(_ id: String) -> String {
      "The \(id) provider in config.toml is not defined with its own [model_providers.\(id)] table "
        + "(it may be an inline table or dotted keys). Nothing was changed, so no duplicate definition is created."
    }
    static func notUTF8(_ name: String) -> String { "\(name) is not UTF-8 text. Nothing was changed." }
    static let libraryUnreadable = "The provider library cannot be read. Saving is paused so its contents are not overwritten."
    static func writeFailed(_ message: String) -> String { "Could not write the configuration: \(message)" }

    static func fileBusy(_ name: String) -> String { "\(name) is being modified frequently by another program; try again shortly." }
    static func cannotCreateDirectory(_ path: String) -> String { "Could not create the directory \(path)." }
    static func noWritePermission(_ path: String) -> String { "No permission to write \(path)." }
    static func diskFull(_ name: String) -> String { "Not enough disk space, so \(name) was not written." }
    static func readOnlyVolume(_ path: String) -> String { "The volume containing \(path) is read-only." }
    static func fileError(_ name: String, _ reason: String) -> String { "\(name): \(reason)" }

    static let settingsNotObject = "settings.json is not a JSON object. Nothing was changed."
    static let settingsEnvNotObject = "The env field in settings.json is not an object. Nothing was changed."
    static let settingsInvalidResult = "The generated settings.json failed validation. Nothing was changed."
    static let settingsNotObjectForReading = "settings.json is not a JSON object."
  }
}
