import Foundation

/// Publishes the active Codex provider's own model to Codex's model catalog.
///
/// Two constraints shape this file, both verified against Codex 0.155.1:
///
/// 1. The model picker lists exactly the models of the catalog named by
///    `model_catalog_json`. Pointing `model_provider` at a relay is not enough:
///    the relay's model stays invisible, and Codex warns that it found no metadata
///    for the model and runs on fallback metadata instead.
/// 2. A published entry has to carry its own system prompt — `base_instructions`
///    or `model_messages.instructions_template`. A catalog entry without one is
///    rejected outright, which makes the whole config fail to load. Inventing that
///    prompt would silently downgrade the agent, so it is copied verbatim from the
///    official catalog Codex downloaded for itself: the relay model then runs with
///    the same instructions the official models run with.
///
/// The official entries are re-published with the picker flag off. Slugs the rest
/// of the config still names — subagents, review models, auto-review — keep
/// resolving with real metadata, without inviting a choice the relay cannot serve.
enum CodexModelCatalog {
    /// Kept next to `config.toml`. Stable, because `CodexTomlEditor` recognises the
    /// app's own value by this file name when handing the catalog back.
    static let fileName = "ai-toolbox-models.json"

    /// Used when the official catalog carries no context size. Conservative on
    /// purpose: compacting too early is recoverable, compacting too late is not.
    static let defaultContextWindow = 131_072

    /// Builds the catalog body for one provider.
    ///
    /// Throws when the provider has a model but the installed Codex has no official
    /// catalog to take instructions from. Callers keep the switch working either
    /// way and report this as a caveat, because the model itself is still written
    /// to `config.toml`.
    static func make(providerName: String, model: String, officialCatalog: URL) throws -> Data {
        let slug = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else { throw LiveConfigError.missingField("模型") }
        let official = try officialEntries(at: officialCatalog)
        // A relay serving an official model under its own name is that model: it
        // takes that entry's prompt and metadata, and replaces it rather than
        // sitting next to it under the same slug.
        let sameModel = official.first { ($0["slug"] as? String) == slug }
        guard let source = sameModel ?? rankedFirst(official) else {
            throw LiveConfigError.missingModelCatalog(officialCatalog)
        }

        let name = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        var entry: [String: Any] = [
            "slug": slug,
            "display_name": slug,
            "description": "由 \(name.isEmpty ? slug : name) 提供",
            "supported_reasoning_levels": source["supported_reasoning_levels"] ?? [],
            "shell_type": source["shell_type"] ?? "unified_exec",
            "visibility": "list",
            "supported_in_api": true,
            "priority": 1,
            "support_verbosity": true,
            "truncation_policy": source["truncation_policy"] ?? ["mode": "tokens", "limit": 10_000],
            "experimental_supported_tools": [],
            "context_window": source["context_window"] ?? defaultContextWindow,
            "max_context_window": source["max_context_window"] ?? source["context_window"] ?? defaultContextWindow,
        ]
        // The one field Codex refuses to default: an entry without instructions is
        // not loaded at all, so the official prompt travels with the model.
        if let messages = source["model_messages"] {
            entry["model_messages"] = messages
        } else if let instructions = source["base_instructions"] {
            entry["base_instructions"] = instructions
        }
        if let percent = source["effective_context_window_percent"] {
            entry["effective_context_window_percent"] = percent
        }

        let hiddenOfficial = official.filter { ($0["slug"] as? String) != slug }.map { model -> [String: Any] in
            var copy = model
            copy["visibility"] = "hide"
            return copy
        }
        let root: [String: Any] = ["models": [entry] + hiddenOfficial]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static func officialEntries(at url: URL) throws -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]],
              !models.isEmpty
        else { throw LiveConfigError.missingModelCatalog(url) }
        return models
    }

    /// The visible entry the official picker ranks first. Only its prompt and
    /// metadata are reused, so which entry it is matters less than it being the
    /// same choice on every switch.
    private static func rankedFirst(_ entries: [[String: Any]]) -> [String: Any]? {
        let listed = entries.filter { ($0["visibility"] as? String) == "list" }
        let candidates = listed.isEmpty ? entries : listed
        return candidates.min { lhs, rhs in priority(lhs) < priority(rhs) }
    }

    private static func priority(_ entry: [String: Any]) -> Int {
        (entry["priority"] as? Int) ?? .max
    }
}
