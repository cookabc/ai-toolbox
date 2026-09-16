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
        let object = try readObject(from: url)
        let env = stringEnv(object)
        let secret = firstNonEmpty(env[apiKey], env[authToken]) ?? ""
        var extra: [String: String] = [:]
        for key in perProviderKeys {
            let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { extra[key] = value }
        }
        return (
            ClaudeLiveSettings(
                baseURL: env[baseURL] ?? "",
                model: env[model] ?? "",
                hasAPIKey: !secret.isEmpty,
                maskedAPIKey: SecretDisplay.mask(secret),
                extraEnv: extra
            ),
            secret
        )
    }

    /// Writes one provider's settings into `settings.json`.
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
    static func save(
        to url: URL,
        baseURL: String,
        model: String,
        apiKey: String?,
        keepExistingKeyIfEmpty: Bool,
        extraEnv: [String: String] = [:],
        removingKeys: Set<String> = []
    ) throws {
        var root = (try? readObject(from: url)) ?? [:]
        var env = stringEnv(root)
        let trimmedURL = normalizedBaseURL(baseURL)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if trimmedURL.isEmpty { env.removeValue(forKey: Self.baseURL) }
        else { env[Self.baseURL] = trimmedURL }

        if trimmedModel.isEmpty {
            env.removeValue(forKey: Self.model)
        } else {
            env[Self.model] = trimmedModel
        }

        for key in removingKeys where extraEnv[key] == nil {
            env.removeValue(forKey: key)
        }
        for key in Self.perProviderKeys {
            guard let value = extraEnv[key] else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { env.removeValue(forKey: key) }
            else { env[key] = trimmed }
        }

        if !trimmedKey.isEmpty {
            env[Self.apiKey] = trimmedKey
            env.removeValue(forKey: authToken)
        } else if !keepExistingKeyIfEmpty {
            env.removeValue(forKey: Self.apiKey)
            env.removeValue(forKey: authToken)
        }

        root["env"] = env
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try AtomicFileWriter.write(data, to: url)
    }

    static func clearAPIOverlay(at url: URL) throws {
        var root = try readObject(from: url)
        var env = stringEnv(root)
        env.removeValue(forKey: apiKey)
        env.removeValue(forKey: authToken)
        env.removeValue(forKey: baseURL)
        env.removeValue(forKey: model)
        for key in familyModels { env.removeValue(forKey: key) }
        root["env"] = env
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try AtomicFileWriter.write(data, to: url)
    }

    private static func readObject(from url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LiveConfigError.writeFailed("Claude settings.json 不是 JSON 对象。")
        }
        return object
    }

    private static func stringEnv(_ root: [String: Any]) -> [String: String] {
        guard let env = root["env"] as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in env {
            if let string = value as? String {
                result[key] = string
            } else {
                result[key] = String(describing: value)
            }
        }
        return result
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }
}
