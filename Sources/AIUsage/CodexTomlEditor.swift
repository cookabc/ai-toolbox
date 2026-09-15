import Foundation

enum CodexTomlEditor {
    static let builtInOpenAI = CodexProviderRecord(
        id: "openai",
        name: "官方 OpenAI",
        baseURL: "",
        hasAPIKey: false,
        maskedAPIKey: "使用 auth.json / 官方登录",
        isBuiltIn: true
    )

    static func load(_ text: String) -> CodexLiveSettings {
        let current = rootString(text, key: "model_provider") ?? "openai"
        let model = rootString(text, key: "model") ?? ""
        let custom = providerIDs(in: text).map { id in
            let fields = providerFields(in: text, id: id)
            let secret = firstNonEmpty(fields["experimental_bearer_token"], fields["api_key"]) ?? ""
            return CodexProviderRecord(
                id: id,
                name: fields["name"] ?? id,
                baseURL: fields["base_url"] ?? "",
                hasAPIKey: !secret.isEmpty || !(fields["env_key"] ?? "").isEmpty,
                maskedAPIKey: !secret.isEmpty ? SecretDisplay.mask(secret) : (fields["env_key"].map { "环境变量 \($0)" } ?? "未设置"),
                isBuiltIn: false
            )
        }
        return CodexLiveSettings(
            model: model,
            currentProviderID: current,
            providers: [builtInOpenAI] + custom
        )
    }

    static func secret(in text: String, id: String) -> String {
        let fields = providerFields(in: text, id: id)
        return firstNonEmpty(fields["experimental_bearer_token"], fields["api_key"]) ?? ""
    }

    static func switchProvider(_ text: String, to id: String, model: String?) -> String {
        var next = setRootString(text, key: "model_provider", value: id)
        if let model {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                next = setRootString(next, key: "model", value: trimmed)
            }
        }
        return next
    }

    static func upsertProvider(
        _ text: String,
        id: String,
        name: String,
        baseURL: String,
        apiKey: String?,
        makeCurrent: Bool,
        model: String?
    ) throws -> String {
        guard ProviderIDRules.isValid(id) else { throw LiveConfigError.invalidProviderID }
        guard !ProviderIDRules.reservedCodexIDs.contains(id) else { throw LiveConfigError.reservedProviderID }
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { throw LiveConfigError.missingField("Base URL") }
        var fields: [String: String?] = [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? id : name.trimmingCharacters(in: .whitespacesAndNewlines),
            "base_url": trimmedURL,
            "wire_api": "responses",
        ]
        if let apiKey {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                fields["experimental_bearer_token"] = trimmed
                fields["env_key"] = nil
                fields["api_key"] = nil
            }
        }
        var next = upsertTable(text, id: id, fields: fields)
        if makeCurrent {
            next = switchProvider(next, to: id, model: model)
        } else if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            next = setRootString(next, key: "model", value: model.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return next
    }

    static func removeProvider(_ text: String, id: String) throws -> String {
        guard !ProviderIDRules.reservedCodexIDs.contains(id) else { throw LiveConfigError.reservedProviderID }
        var next = removeTables(text, id: id)
        if (rootString(next, key: "model_provider") ?? "openai") == id {
            next = setRootString(next, key: "model_provider", value: "openai")
        }
        return next
    }

    static func rootString(_ text: String, key: String) -> String? {
        var table: String?
        for line in lines(of: text) {
            if let header = tableHeader(line) {
                table = header
                continue
            }
            guard table == nil, let assignment = assignment(line), assignment.key == key else { continue }
            return unquote(assignment.value)
        }
        return nil
    }

    static func setRootString(_ text: String, key: String, value: String) -> String {
        var result = lines(of: text)
        var table: String?
        for index in result.indices {
            let line = result[index]
            if let header = tableHeader(line) {
                table = header
                continue
            }
            guard table == nil, let assignment = assignment(line), assignment.key == key else { continue }
            result[index] = "\(key) = \(quote(value))"
            return join(result, originally: text)
        }
        let insertion = "\(key) = \(quote(value))"
        if let modelIndex = rootIndex(result, key: "model") {
            result.insert(insertion, at: modelIndex + 1)
        } else {
            var index = 0
            while index < result.count && (result[index].trimmingCharacters(in: .whitespaces).hasPrefix("#") || result[index].trimmingCharacters(in: .whitespaces).isEmpty) {
                index += 1
            }
            result.insert(insertion, at: index)
        }
        return join(result, originally: text)
    }

    static func providerIDs(in text: String) -> [String] {
        var ids: [String] = []
        for line in lines(of: text) {
            guard let header = tableHeader(line),
                  header.hasPrefix("model_providers."),
                  !header.dropFirst("model_providers.".count).contains("."),
                  let id = providerID(from: header),
                  !ids.contains(id) else { continue }
            ids.append(id)
        }
        return ids
    }

    static func providerFields(in text: String, id: String) -> [String: String] {
        guard let body = tableBody(in: text, id: id) else { return [:] }
        var fields: [String: String] = [:]
        var nested = false
        for line in body {
            if tableHeader(line) != nil {
                nested = true
                continue
            }
            if nested { continue }
            if let assignment = assignment(line) {
                fields[assignment.key] = unquote(assignment.value)
            }
        }
        return fields
    }

    private static func upsertTable(_ text: String, id: String, fields: [String: String?]) -> String {
        var result = lines(of: text)
        if let range = tableRange(in: result, id: id) {
            var body = Array(result[range])
            let header = body.removeFirst()
            var nested: [String] = []
            var top: [String] = []
            var inNested = false
            for line in body {
                if tableHeader(line) != nil { inNested = true }
                if inNested { nested.append(line) } else { top.append(line) }
            }
            var map = Dictionary(uniqueKeysWithValues: top.compactMap { line -> (String, String)? in
                assignment(line).map { ($0.key, line) }
            })
            for (key, value) in fields {
                if let value {
                    map[key] = "\(key) = \(quote(value))"
                } else {
                    map.removeValue(forKey: key)
                }
            }
            let orderedKeys = ["name", "base_url", "wire_api", "experimental_bearer_token", "env_key"]
            var rewritten = [header]
            var seen: Set<String> = []
            for key in orderedKeys {
                if let line = map[key] {
                    rewritten.append(line)
                    seen.insert(key)
                }
            }
            for line in top {
                guard let key = assignment(line)?.key, !seen.contains(key), map[key] != nil else { continue }
                rewritten.append(map[key]!)
                seen.insert(key)
            }
            rewritten.append(contentsOf: nested)
            result.replaceSubrange(range, with: rewritten)
            return join(result, originally: text)
        }
        var block = ["", "[model_providers.\(id)]"]
        let ordered = ["name", "base_url", "wire_api", "experimental_bearer_token", "env_key"]
        for key in ordered {
            if let value = fields[key], let value {
                block.append("\(key) = \(quote(value))")
            }
        }
        result.append(contentsOf: block)
        return join(result, originally: text)
    }

    private static func removeTables(_ text: String, id: String) -> String {
        var kept: [String] = []
        var skip = false
        for line in lines(of: text) {
            if let header = tableHeader(line) {
                skip = belongs(header, to: id)
            }
            if skip { continue }
            kept.append(line)
        }
        return join(kept, originally: text)
    }

    private static func tableBody(in text: String, id: String) -> [String]? {
        let all = lines(of: text)
        guard let range = tableRange(in: all, id: id) else { return nil }
        return Array(all[range].dropFirst())
    }

    private static func tableRange(in lines: [String], id: String) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { tableHeader($0) == "model_providers.\(id)" }) else { return nil }
        var end = lines.count
        for index in (start + 1)..<lines.count {
            if let header = tableHeader(lines[index]), !belongs(header, to: id) {
                end = index
                break
            }
        }
        return start..<end
    }

    private static func belongs(_ header: String, to id: String) -> Bool {
        header == "model_providers.\(id)" || header.hasPrefix("model_providers.\(id).")
    }

    private static func providerID(from header: String) -> String? {
        guard header.hasPrefix("model_providers.") else { return nil }
        let rest = String(header.dropFirst("model_providers.".count))
        let id = rest.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rest
        return id.isEmpty ? nil : id
    }

    private static func tableHeader(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), !trimmed.hasPrefix("[[") else { return nil }
        return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    private static func assignment(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.hasPrefix("[") else { return nil }
        return (String(key), String(value))
    }

    private static func rootIndex(_ lines: [String], key: String) -> Int? {
        var table: String?
        for (index, line) in lines.enumerated() {
            if let header = tableHeader(line) {
                table = header
                continue
            }
            if table == nil, assignment(line)?.key == key { return index }
        }
        return nil
    }

    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func unquote(_ value: String) -> String {
        var result = value
        if let comment = result.firstIndex(of: "#"), !(result.contains("\"") && result.firstIndex(of: "\"")! < comment) {
            // keep quoted strings intact; strip trailing comments on bare values
        }
        result = result.trimmingCharacters(in: .whitespaces)
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count >= 2 {
            return String(result.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if result.hasPrefix("'") && result.hasSuffix("'") && result.count >= 2 {
            return String(result.dropFirst().dropLast())
        }
        if let hash = result.firstIndex(of: "#") {
            result = result[..<hash].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private static func lines(of text: String) -> [String] {
        if text.isEmpty { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func join(_ lines: [String], originally text: String) -> String {
        let joined = lines.joined(separator: "\n")
        if text.hasSuffix("\n") && !joined.hasSuffix("\n") { return joined + "\n" }
        return joined
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

enum CodexLiveSettingsStore {
    static func load(from url: URL) throws -> (settings: CodexLiveSettings, text: String) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LiveConfigError.missingFile(url)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return (CodexTomlEditor.load(text), text)
    }

    static func write(_ text: String, to url: URL) throws {
        guard let data = text.data(using: .utf8) else {
            throw LiveConfigError.writeFailed("无法将 Codex 配置编码为 UTF-8。")
        }
        try AtomicFileWriter.write(data, to: url)
    }
}
