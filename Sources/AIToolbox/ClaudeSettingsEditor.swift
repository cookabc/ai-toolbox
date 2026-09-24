import Foundation

/// Rewrites the `env` object of a Claude Code `settings.json` and nothing else.
///
/// Re-serialising the whole document would sort every key in the file, reformat
/// it, escape `/` as `\/`, and turn values it never meant to touch into strings.
/// Instead the document is scanned for byte ranges, and only the `env` object is
/// replaced: members this edit does not name keep their original text and order,
/// new ones are appended, and the rest of the file is untouched.
enum ClaudeSettingsEditor {
    struct Edit: Equatable {
        /// Keys to set, in the order new ones should be appended.
        var set: [(key: String, value: String)] = []
        var remove: Set<String> = []

        static func == (lhs: Edit, rhs: Edit) -> Bool {
            lhs.set.map(\.key) == rhs.set.map(\.key) && lhs.set.map(\.value) == rhs.set.map(\.value)
                && lhs.remove == rhs.remove
        }
    }

    static func apply(_ edit: Edit, to data: Data?) throws -> Data {
        guard let data, data.contains(where: { !isWhitespace($0) }) else {
            return Data(("{\n  \"env\": " + object(edit.set.map { ($0.key, json($0.value)) }, indent: "  ", unit: "  ")
                + "\n}\n").utf8)
        }
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw LiveConfigError.writeFailed("settings.json 不是一个 JSON 对象，未做修改。")
        }
        var bytes = [UInt8](data)
        var scanner = JSONScanner(bytes: bytes)
        let root = try scanner.rootObject()
        let members = try scanner.members(of: root)

        if let env = members.first(where: { $0.key == "env" }) {
            guard bytes[env.value.lowerBound] == UInt8(ascii: "{") else {
                throw LiveConfigError.writeFailed("settings.json 中的 env 不是对象，未做修改。")
            }
            let existing = try scanner.members(of: env.value)
            var entries: [(String, String)] = []
            var pending = edit.set
            for member in existing where !edit.remove.contains(member.key) {
                if let index = pending.firstIndex(where: { $0.key == member.key }) {
                    entries.append((member.key, json(pending.remove(at: index).value)))
                } else {
                    entries.append((member.key, String(decoding: bytes[member.value], as: UTF8.self)))
                }
            }
            entries += pending.map { ($0.key, json($0.value)) }

            let outer = scanner.indentation(ofLineContaining: env.range.lowerBound)
            let unit = outer.isEmpty ? "  " : outer
            var inner = outer + unit
            if let first = existing.first,
               scanner.lineStart(of: first.range.lowerBound) != scanner.lineStart(of: env.range.lowerBound) {
                inner = scanner.indentation(ofLineContaining: first.range.lowerBound)
            }
            let replacement = object(entries, indent: outer, unit: unit, inner: inner)
            bytes.replaceSubrange(env.value, with: Array(replacement.utf8))
        } else {
            let entries = edit.set.map { ($0.key, json($0.value)) }
            guard !entries.isEmpty else { return data }
            if let first = members.first,
               scanner.lineStart(of: first.range.lowerBound) != scanner.lineStart(of: root.lowerBound) {
                let indent = scanner.indentation(ofLineContaining: first.range.lowerBound)
                let member = "\n" + indent + "\"env\": " + object(entries, indent: indent, unit: indent.isEmpty ? "  " : indent) + ","
                bytes.insert(contentsOf: Array(member.utf8), at: root.lowerBound + 1)
            } else if members.isEmpty {
                let replacement = "{\n  \"env\": " + object(entries, indent: "  ", unit: "  ") + "\n}"
                bytes.replaceSubrange(root, with: Array(replacement.utf8))
            } else {
                let member = "\"env\": " + object(entries, indent: "", unit: "  ") + ", "
                bytes.insert(contentsOf: Array(member.utf8), at: members[0].range.lowerBound)
            }
        }
        let result = Data(bytes)
        guard (try? JSONSerialization.jsonObject(with: result)) is [String: Any] else {
            throw LiveConfigError.writeFailed("生成的 settings.json 无法通过校验，未做修改。")
        }
        return result
    }

    /// The `env` values as strings, for display. Non-string values are shown the way
    /// they are written.
    static func env(in data: Data?) throws -> [String: String] {
        guard let data, data.contains(where: { !isWhitespace($0) }) else { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LiveConfigError.writeFailed("settings.json 不是一个 JSON 对象。")
        }
        guard let env = root["env"] as? [String: Any] else { return [:] }
        return env.mapValues { value in
            if let string = value as? String { return string }
            if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return "\(value)"
        }
    }

    private static func object(_ entries: [(String, String)], indent: String, unit: String, inner: String? = nil) -> String {
        guard !entries.isEmpty else { return "{}" }
        let inner = inner ?? indent + unit
        let lines = entries.map { inner + json($0.0) + ": " + $0.1 }
        return "{\n" + lines.joined(separator: ",\n") + "\n" + indent + "}"
    }

    private static func json(_ string: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    fileprivate static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13
    }
}

/// Locates members of JSON objects by byte range. It relies on the document having
/// already been validated, so it only has to find boundaries, not check grammar.
private struct JSONScanner {
    struct Member {
        let key: String
        /// From the key's opening quote to the end of its value.
        let range: Range<Int>
        let value: Range<Int>
    }

    struct Failure: Error {}

    let bytes: [UInt8]
    var index = 0

    mutating func rootObject() throws -> Range<Int> {
        index = 0
        skipWhitespace()
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3; skipWhitespace() }
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { throw Failure() }
        let start = index
        try skipValue()
        return start..<index
    }

    mutating func members(of object: Range<Int>) throws -> [Member] {
        index = object.lowerBound + 1
        var result: [Member] = []
        while true {
            skipWhitespace()
            guard index < object.upperBound else { throw Failure() }
            if bytes[index] == UInt8(ascii: "}") { return result }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            let keyStart = index
            try skipString()
            guard let key = try? JSONSerialization.jsonObject(with: Data(bytes[keyStart..<index]),
                                                              options: .fragmentsAllowed) as? String
            else { throw Failure() }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw Failure() }
            index += 1
            skipWhitespace()
            let valueStart = index
            try skipValue()
            result.append(Member(key: key, range: keyStart..<index, value: valueStart..<index))
        }
    }

    func lineStart(of offset: Int) -> Int {
        var start = offset
        while start > 0, bytes[start - 1] != 10 { start -= 1 }
        return start
    }

    func indentation(ofLineContaining offset: Int) -> String {
        var end = lineStart(of: offset)
        let start = end
        while end < bytes.count, bytes[end] == 32 || bytes[end] == 9 { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, ClaudeSettingsEditor.isWhitespace(bytes[index]) { index += 1 }
    }

    private mutating func skipString() throws {
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw Failure() }
        index += 1
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\\"): index += 2
            case UInt8(ascii: "\""): index += 1; return
            default: index += 1
            }
        }
        throw Failure()
    }

    private mutating func skipValue() throws {
        guard index < bytes.count else { throw Failure() }
        switch bytes[index] {
        case UInt8(ascii: "\""):
            try skipString()
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\""): try skipString(); continue
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { index += 1; return }
                default: break
                }
                index += 1
            }
            throw Failure()
        default:
            while index < bytes.count, !ClaudeSettingsEditor.isWhitespace(bytes[index]),
                  ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]")].contains(bytes[index]) {
                index += 1
            }
        }
    }
}
