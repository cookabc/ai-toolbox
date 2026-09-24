import Foundation

/// A TOML file as a sequence of statements with their exact byte ranges, so a
/// value can be replaced or a table removed while every other byte — comments,
/// spacing, key order, quoting — stays exactly as the user or Codex wrote it.
///
/// It parses the full TOML grammar for *structure* (strings of all four kinds,
/// multi-line arrays, inline tables, comments, `[[…]]`), but only decodes values
/// as strings. Anything it cannot parse makes `init` throw, and callers treat that
/// as "do not touch this file": a config Codex can no longer load is far worse than
/// a switch that did not happen.
struct TomlDocument {
    enum Kind: Equatable {
        case trivia
        case table(path: [String], isArray: Bool)
        case pair(path: [String], value: Range<Int>)
    }

    struct Statement {
        let kind: Kind
        /// From the start of the line to just past its newline. Multi-line values
        /// make a statement span several lines.
        let range: Range<Int>
        /// The table the statement is in: `[]` for the root, `nil` inside `[[…]]`,
        /// where a path does not name one table.
        let table: [String]?
    }

    struct ParseError: Error, Equatable {
        let line: Int
    }

    private(set) var bytes: [UInt8]
    private(set) var statements: [Statement] = []
    /// `\r\n` when the file already uses it, so inserted lines match.
    let newline: [UInt8]

    var text: String { String(decoding: bytes, as: UTF8.self) }

    init(_ text: String) throws {
        bytes = Array(text.utf8)
        newline = text.contains("\r\n") ? [13, 10] : [10]
        statements = try Self.parse(bytes)
    }

    // MARK: - Reading

    func pair(_ path: [String], in table: [String]) -> Statement? {
        statements.first { statement in
            guard statement.table == table, case .pair(let key, _) = statement.kind else { return false }
            return key == path
        }
    }

    /// The value of `key` in `table` if it is a string of any of the four kinds.
    func string(_ key: String, in table: [String] = []) -> String? {
        guard let statement = pair([key], in: table), case .pair(_, let value) = statement.kind else { return nil }
        return Self.decodeString(Array(bytes[value]))
    }

    func hasTable(_ path: [String]) -> Bool {
        statements.contains { $0.kind == .table(path: path, isArray: false) }
    }

    /// Tables whose path is `prefix` plus exactly one more key, in file order.
    func childTables(of prefix: [String]) -> [String] {
        var seen: [String] = []
        for statement in statements {
            guard case .table(let path, false) = statement.kind, path.count == prefix.count + 1,
                  Array(path.prefix(prefix.count)) == prefix, !seen.contains(path.last!) else { continue }
            seen.append(path.last!)
        }
        return seen
    }

    /// String values directly in `table`, not in its sub-tables.
    func strings(in table: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for statement in statements where statement.table == table {
            guard case .pair(let path, let value) = statement.kind, path.count == 1,
                  let string = Self.decodeString(Array(bytes[value])) else { continue }
            result[path[0]] = string
        }
        return result
    }

    /// Whether anything outside a `[path]` header defines keys under `path`: dotted
    /// keys (`a.b.c = …`), an inline table (`b = { … }`) or an array of tables.
    /// Adding a `[path]` header next to one of those is a redefinition, which makes
    /// the whole file invalid.
    func isDefinedOutsideItsTable(_ path: [String]) -> Bool {
        for statement in statements {
            switch statement.kind {
            case .table(let tablePath, let isArray):
                if isArray && tablePath.starts(with: path.prefix(tablePath.count)) { return true }
            case .pair(let key, _):
                guard let table = statement.table else { continue }
                let full = table + key
                // A pair inside the table itself, or inside one of its sub-tables, is fine.
                if table.count >= path.count, Array(table.prefix(path.count)) == path { continue }
                if full.count >= path.count ? Array(full.prefix(path.count)) == path
                                            : Array(path.prefix(full.count)) == full {
                    return true
                }
            case .trivia:
                continue
            }
        }
        return false
    }

    // MARK: - Editing

    /// Sets a string value, keeping the key's own spelling and any trailing comment.
    /// A new key is inserted after `after` when that key exists in the same table,
    /// otherwise after the table's last key.
    mutating func setString(_ key: String, _ value: String, in table: [String] = [], after: String? = nil) throws {
        let literal = Array(Self.quote(value).utf8)
        if let statement = pair([key], in: table), case .pair(_, let range) = statement.kind {
            try replace(range, with: literal)
            return
        }
        let line = Array(Self.bareOrQuotedKey(key).utf8) + Array(" = ".utf8) + literal + newline
        try insert(line, at: insertionPoint(in: table, after: after))
    }

    mutating func remove(_ key: String, in table: [String] = []) throws {
        guard let statement = pair([key], in: table) else { return }
        try replace(statement.range, with: [])
    }

    /// Appends `[path]` with the given string values at the end of the file,
    /// separated from what precedes it by one blank line.
    mutating func appendTable(_ path: [String], values: [(String, String)]) throws {
        var block: [UInt8] = []
        if !bytes.isEmpty {
            if bytes.last != 10 { block += newline }
            if !endsWithBlankLine { block += newline }
        }
        block += Array("[\(path.map(Self.bareOrQuotedKey).joined(separator: "."))]".utf8) + newline
        for (key, value) in values {
            block += Array("\(Self.bareOrQuotedKey(key)) = \(Self.quote(value))".utf8) + newline
        }
        try replace(bytes.count..<bytes.count, with: block)
    }

    /// Removes `[path]` and every `[path.…]` sub-table: the header, its keys, and
    /// the blank lines after them. A comment after the last key stays, because it
    /// most likely introduces what follows.
    mutating func removeTable(_ path: [String]) throws {
        var ranges: [Range<Int>] = []
        var index = 0
        while index < statements.count {
            guard case .table(let tablePath, _) = statements[index].kind, tablePath.starts(with: path) else {
                index += 1
                continue
            }
            var end = statements[index].range.upperBound
            var cursor = index + 1
            var lastMember = index
            while cursor < statements.count {
                if case .table = statements[cursor].kind { break }
                if case .pair = statements[cursor].kind { lastMember = cursor }
                cursor += 1
            }
            end = statements[lastMember].range.upperBound
            var trailing = lastMember + 1
            while trailing < cursor, isBlank(statements[trailing]) {
                end = statements[trailing].range.upperBound
                trailing += 1
            }
            ranges.append(statements[index].range.lowerBound..<end)
            index = cursor
        }
        guard !ranges.isEmpty else { return }
        var next = bytes
        for range in ranges.reversed() { next.removeSubrange(range) }
        // What was removed may have been the end of the file; do not leave the blank
        // separator that used to precede it dangling there.
        while next.count >= 2, next.last == 10, next[next.count - 2] == 10 { next.removeLast() }
        while next.count >= 4, next.suffix(4).elementsEqual([13, 10, 13, 10]) { next.removeLast(2) }
        statements = try Self.parse(next)
        bytes = next
    }

    // MARK: - Private editing helpers

    private var endsWithBlankLine: Bool {
        guard let last = statements.last else { return true }
        return isBlank(last)
    }

    private func isBlank(_ statement: Statement) -> Bool {
        statement.kind == .trivia && bytes[statement.range].allSatisfy { $0 == 32 || $0 == 9 || $0 == 10 || $0 == 13 }
    }

    private func insertionPoint(in table: [String], after: String?) -> Int {
        if let after, let anchor = pair([after], in: table) { return anchor.range.upperBound }
        let members = statements.filter { $0.table == table }
        if let lastPair = members.last(where: { if case .pair = $0.kind { true } else { false } }) {
            return lastPair.range.upperBound
        }
        if table.isEmpty {
            // No root keys yet: go above the first table, and above the comment block
            // that sits directly on top of it, so that comment keeps describing it.
            guard let firstTable = statements.firstIndex(where: { if case .table = $0.kind { true } else { false } })
            else { return bytes.count }
            var index = firstTable
            while index > 0, isComment(statements[index - 1]) { index -= 1 }
            return statements[index].range.lowerBound
        }
        return statements.first { $0.kind == .table(path: table, isArray: false) }?.range.upperBound ?? bytes.count
    }

    private func isComment(_ statement: Statement) -> Bool {
        guard statement.kind == .trivia else { return false }
        return bytes[statement.range].first { $0 != 32 && $0 != 9 } == 35
    }

    private mutating func insert(_ line: [UInt8], at offset: Int) throws {
        var line = line
        // Never glue a new line onto an unterminated last line.
        if offset == bytes.count, offset > 0, bytes.last != 10 { line = newline + line }
        try replace(offset..<offset, with: line)
    }

    private mutating func replace(_ range: Range<Int>, with replacement: [UInt8]) throws {
        var next = bytes
        next.replaceSubrange(range, with: replacement)
        statements = try Self.parse(next)
        bytes = next
    }

    // MARK: - Writing values

    /// A TOML basic string. Control characters are escaped, so a value can never
    /// break out of its line.
    static func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    static func bareOrQuotedKey(_ key: String) -> String {
        let isBare = !key.isEmpty && key.utf8.allSatisfy(isBareKeyByte)
        return isBare ? key : quote(key)
    }

    // MARK: - Parsing

    private static func parse(_ bytes: [UInt8]) throws -> [Statement] {
        var scanner = Scanner(bytes: bytes)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { scanner.index = 3 }
        var statements: [Statement] = []
        var table: [String]? = []
        while !scanner.atEnd {
            // A byte-order mark belongs to the first statement, so no edit can split it.
            let start = statements.isEmpty ? 0 : scanner.index
            do {
                scanner.skipSpaces()
                let kind: Kind
                if scanner.atLineEnd || scanner.peek == 35 {
                    scanner.skipComment()
                    kind = .trivia
                } else if scanner.peek == 91 {
                    scanner.index += 1
                    let isArray = scanner.peek == 91
                    if isArray { scanner.index += 1 }
                    let path = try scanner.key()
                    try scanner.expect(93)
                    if isArray { try scanner.expect(93) }
                    scanner.skipSpaces()
                    scanner.skipComment()
                    kind = .table(path: path, isArray: isArray)
                    table = isArray ? nil : path
                } else {
                    let path = try scanner.key()
                    try scanner.expect(61)
                    scanner.skipSpaces()
                    let valueStart = scanner.index
                    try scanner.value()
                    let value = valueStart..<scanner.index
                    scanner.skipSpaces()
                    scanner.skipComment()
                    kind = .pair(path: path, value: value)
                }
                try scanner.endLine()
                statements.append(Statement(kind: kind, range: start..<scanner.index, table: table))
            } catch {
                throw ParseError(line: bytes[..<min(scanner.index, bytes.count)].filter { $0 == 10 }.count + 1)
            }
        }
        return statements
    }

    fileprivate static func isBareKeyByte(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 95 || byte == 45
    }

    /// Decodes a value span if it is a string; `nil` for any other type.
    static func decodeString(_ value: [UInt8]) -> String? {
        var scanner = Scanner(bytes: value)
        guard let first = scanner.peek, first == 34 || first == 39 else { return nil }
        return try? scanner.string()
    }
}

private struct Scanner {
    let bytes: [UInt8]
    var index = 0

    struct Failure: Error {}

    var atEnd: Bool { index >= bytes.count }
    var peek: UInt8? { index < bytes.count ? bytes[index] : nil }
    var atLineEnd: Bool {
        guard let byte = peek else { return true }
        return byte == 10 || (byte == 13 && index + 1 < bytes.count && bytes[index + 1] == 10)
    }

    mutating func skipSpaces() {
        while let byte = peek, byte == 32 || byte == 9 { index += 1 }
    }

    mutating func skipComment() {
        guard peek == 35 else { return }
        while !atLineEnd { index += 1 }
    }

    /// Spaces, newlines and comments, as allowed between array elements.
    mutating func skipBlank() {
        while true {
            skipSpaces()
            if peek == 35 { skipComment() }
            if peek == 10 { index += 1; continue }
            if peek == 13, index + 1 < bytes.count, bytes[index + 1] == 10 { index += 2; continue }
            return
        }
    }

    mutating func endLine() throws {
        guard let byte = peek else { return }
        if byte == 10 { index += 1; return }
        if byte == 13, index + 1 < bytes.count, bytes[index + 1] == 10 { index += 2; return }
        throw Failure()
    }

    mutating func expect(_ byte: UInt8) throws {
        skipSpaces()
        guard peek == byte else { throw Failure() }
        index += 1
    }

    mutating func key() throws -> [String] {
        var path: [String] = []
        while true {
            skipSpaces()
            guard let byte = peek else { throw Failure() }
            if byte == 34 || byte == 39 {
                guard !starts(with: byte == 34 ? "\"\"\"" : "'''") else { throw Failure() }
                path.append(try string())
            } else {
                let start = index
                while let byte = peek, TomlDocument.isBareKeyByte(byte) { index += 1 }
                guard index > start else { throw Failure() }
                path.append(String(decoding: bytes[start..<index], as: UTF8.self))
            }
            skipSpaces()
            guard peek == 46 else { return path }
            index += 1
        }
    }

    mutating func value() throws {
        guard let byte = peek else { throw Failure() }
        switch byte {
        case 34, 39:
            _ = try string()
        case 91:
            index += 1
            while true {
                skipBlank()
                if peek == 93 { index += 1; return }
                try value()
                skipBlank()
                if peek == 44 { index += 1; continue }
                if peek == 93 { index += 1; return }
                throw Failure()
            }
        case 123:
            index += 1
            skipBlank()
            if peek == 125 { index += 1; return }
            while true {
                skipBlank()
                _ = try key()
                try expect(61)
                skipSpaces()
                try value()
                skipBlank()
                if peek == 44 {
                    index += 1
                    skipBlank()
                    if peek == 125 { index += 1; return }
                    continue
                }
                if peek == 125 { index += 1; return }
                throw Failure()
            }
        default:
            // Numbers, booleans, dates and times. A date may be followed by a space
            // and a time, which is still one value.
            let start = index
            while let byte = peek, !Self.endsBareValue(byte) { index += 1 }
            guard index > start else { throw Failure() }
            if index - start == 10, peek == 32, index + 1 < bytes.count, (48...57).contains(bytes[index + 1]),
               bytes[start + 4] == 45 {
                index += 1
                while let byte = peek, !Self.endsBareValue(byte) { index += 1 }
            }
        }
    }

    private static func endsBareValue(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 44 || byte == 93 || byte == 125 || byte == 35
    }

    func starts(with prefix: String) -> Bool {
        let prefix = Array(prefix.utf8)
        return index + prefix.count <= bytes.count && Array(bytes[index..<(index + prefix.count)]) == prefix
    }

    /// Parses and decodes a string of any of the four kinds.
    mutating func string() throws -> String {
        let quote = bytes[index]
        let multiline = starts(with: quote == 34 ? "\"\"\"" : "'''")
        index += multiline ? 3 : 1
        if multiline {
            // A newline right after the opening delimiter is not part of the value.
            if peek == 10 { index += 1 } else if starts(with: "\r\n") { index += 2 }
        }
        var decoded: [UInt8] = []
        while true {
            guard let byte = peek else { throw Failure() }
            if byte == quote {
                if !multiline { index += 1; return String(decoding: decoded, as: UTF8.self) }
                if starts(with: quote == 34 ? "\"\"\"" : "'''") {
                    index += 3
                    // Up to two quotes may directly precede the closing delimiter.
                    var extra = 0
                    while extra < 2, peek == quote { decoded.append(quote); index += 1; extra += 1 }
                    return String(decoding: decoded, as: UTF8.self)
                }
                decoded.append(byte)
                index += 1
                continue
            }
            if byte == 10 && !multiline { throw Failure() }
            if byte == 92 && quote == 34 {
                index += 1
                guard let escaped = peek else { throw Failure() }
                switch escaped {
                case 98: decoded.append(8); index += 1
                case 116: decoded.append(9); index += 1
                case 110: decoded.append(10); index += 1
                case 102: decoded.append(12); index += 1
                case 114: decoded.append(13); index += 1
                case 101: decoded.append(27); index += 1
                case 34, 92: decoded.append(escaped); index += 1
                case 117, 85, 120:
                    let length = escaped == 117 ? 4 : escaped == 85 ? 8 : 2
                    index += 1
                    guard index + length <= bytes.count,
                          let value = UInt32(String(decoding: bytes[index..<(index + length)], as: UTF8.self), radix: 16),
                          let scalar = Unicode.Scalar(value) else { throw Failure() }
                    decoded += Array(String(scalar).utf8)
                    index += length
                case 32, 9, 10, 13:
                    // Line-ending backslash: drop the newline and the whitespace after it.
                    guard multiline else { throw Failure() }
                    while let next = peek, next == 32 || next == 9 || next == 10 || next == 13 { index += 1 }
                default:
                    throw Failure()
                }
                continue
            }
            decoded.append(byte)
            index += 1
        }
    }
}
