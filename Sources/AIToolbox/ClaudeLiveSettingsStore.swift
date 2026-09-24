import Foundation

enum ClaudeLiveSettingsStore {
    static let apiKey = "ANTHROPIC_API_KEY"
    static let authToken = "ANTHROPIC_AUTH_TOKEN"
    static let baseURL = "ANTHROPIC_BASE_URL"
    static let model = "ANTHROPIC_MODEL"
    static let familyModels = [
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_DEFAULT_FABLE_MODEL",
        "CLAUDE_CODE_SUBAGENT_MODEL",
    ]

    /// The keys a saved provider is allowed to own. Curated deliberately: a switch
    /// writes what the provider declares and nothing else, so it can never quietly
    /// rewrite the rest of the user's `env`. Anything outside this list is left
    /// exactly as the user wrote it.
    static let perProviderKeys = familyModels + [
        "CLAUDE_CODE_MAX_CONTEXT_TOKENS",
        "CLAUDE_CODE_AUTO_COMPACT_WINDOW",
        "CLAUDE_CODE_EFFORT_LEVEL",
    ]

    /// Claude Code's Anthropic client appends `/v1/messages` to `ANTHROPIC_BASE_URL`
    /// on its own. Providers are shared with Codex, which needs the OpenAI-style
    /// `/v1` suffix, so writing that value through unchanged makes Claude Code
    /// request `…/v1/v1/messages`. The gateway answers 404 and Claude Code reports
    /// it as "There's an issue with the selected model", blaming the model instead
    /// of the URL. Drop the trailing version segment so both tools can share one
    /// stored provider.
    static func normalizedBaseURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix("/v1") {
            value.removeLast(3)
            while value.hasSuffix("/") { value.removeLast() }
        }
        return value
    }

    static func load(from url: URL) throws -> (settings: ClaudeLiveSettings, secret: String) {
        let env = try ClaudeSettingsEditor.env(in: ConfigFile.read(url))
        let key = trimmed(env[apiKey])
        let token = trimmed(env[authToken])
        let secret = key.isEmpty ? token : key
        var extra: [String: String] = [:]
        for name in perProviderKeys {
            let value = trimmed(env[name])
            if !value.isEmpty { extra[name] = value }
        }
        return (
            ClaudeLiveSettings(
                baseURL: env[baseURL] ?? "",
                model: env[model] ?? "",
                hasAPIKey: !secret.isEmpty,
                maskedAPIKey: SecretDisplay.mask(secret),
                credential: key.isEmpty && !token.isEmpty ? .authToken : .apiKey,
                extraEnv: extra
            ),
            secret
        )
    }

    /// The `env` changes that make `settings.json` describe one provider.
    ///
    /// Earlier versions pushed the provider's single `model` onto every existing
    /// `ANTHROPIC_DEFAULT_*_MODEL` / `CLAUDE_CODE_SUBAGENT_MODEL` key. That silently
    /// rewrote values the user had set for a reason — and it could not be undone,
    /// because the overwritten value was never recorded anywhere. Now a provider
    /// owns an explicit set of keys (`extraEnv`), and only those are written.
    ///
    /// `removingKeys` carries the keys some *other* provider owns but this one does
    /// not, so switching between two relays does not leave the first relay's model
    /// aliases pointing at a model the second relay has never heard of.
    ///
    /// A provider without a key removes the key that is there. Keeping it would send
    /// the previous provider's credential to this provider's host.
    static func edit(
        baseURL: String,
        model: String,
        apiKey: String,
        credential: ClaudeCredential,
        extraEnv: [String: String] = [:],
        removingKeys: Set<String> = []
    ) -> ClaudeSettingsEditor.Edit {
        var edit = ClaudeSettingsEditor.Edit()
        func set(_ key: String, _ value: String) {
            if value.isEmpty { edit.remove.insert(key) } else { edit.set.append((key, value)) }
        }
        set(Self.baseURL, normalizedBaseURL(baseURL))
        set(Self.model, trimmed(model))
        let key = trimmed(apiKey)
        switch credential {
        case .apiKey:
            set(Self.apiKey, key)
            edit.remove.insert(authToken)
        case .authToken:
            set(authToken, key)
            edit.remove.insert(Self.apiKey)
        }
        for name in removingKeys where extraEnv[name] == nil {
            edit.remove.insert(name)
        }
        for name in perProviderKeys {
            guard let value = extraEnv[name] else { continue }
            set(name, trimmed(value))
        }
        return edit
    }

    static func save(to url: URL, _ edit: ClaudeSettingsEditor.Edit) throws {
        try ConfigFile.update(url) { data in
            try ClaudeSettingsEditor.apply(edit, to: data)
        }
    }

    /// Returns Claude Code to its own login: removes the endpoint, model and
    /// credential overrides, every model alias, and the keys saved providers own.
    /// Keys no provider declares are the user's own and stay.
    static func clearAPIOverlay(at url: URL, providerKeys: Set<String> = []) throws {
        var edit = ClaudeSettingsEditor.Edit()
        edit.remove = Set([apiKey, authToken, baseURL, model] + familyModels).union(providerKeys)
        try ConfigFile.update(url) { data in
            guard data != nil else { return nil }
            return try ClaudeSettingsEditor.apply(edit, to: data)
        }
    }

    private static func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
