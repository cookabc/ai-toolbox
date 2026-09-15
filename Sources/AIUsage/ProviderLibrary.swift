import Foundation

/// One saved provider. Keys stay on this machine in a 0600 file next to the
/// app's own support data; the live CLI config remains the write target.
struct StoredProvider: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var app: LiveConfigApp
    var name: String
    /// Codex writes this as `[model_providers.<slug>]`. Claude keeps it only as a stable label.
    var slug: String
    var baseURL: String
    var model: String
    var apiKey: String

    init(
        id: UUID = UUID(),
        app: LiveConfigApp,
        name: String,
        slug: String,
        baseURL: String,
        model: String,
        apiKey: String
    ) {
        self.id = id
        self.app = app
        self.name = name
        self.slug = slug
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    var maskedAPIKey: String { SecretDisplay.mask(apiKey) }
}

struct ProviderLibraryStore: Sendable {
    let url: URL

    private static let supportDirectoryName = "AIToolbox"
    private static let legacySupportDirectoryName = "AIUsage"

    static var defaultURL: URL {
        migrateLegacySupportDataIfNeeded()
        return supportDirectoryURL.appending(path: "providers.json")
    }

    private static var supportDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/\(supportDirectoryName)")
    }

    private static func migrateLegacySupportDataIfNeeded() {
        let fileManager = FileManager.default
        let newDirectory = supportDirectoryURL
        let newFile = newDirectory.appending(path: "providers.json")
        guard !fileManager.fileExists(atPath: newFile.path) else { return }

        let legacyDirectory = fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/\(legacySupportDirectoryName)")
        let legacyFile = legacyDirectory.appending(path: "providers.json")
        guard fileManager.fileExists(atPath: legacyFile.path) else { return }

        try? fileManager.createDirectory(at: newDirectory, withIntermediateDirectories: true)
        try? fileManager.copyItem(at: legacyFile, to: newFile)
    }

    init(url: URL = ProviderLibraryStore.defaultURL) {
        self.url = url
    }

    func load() throws -> [StoredProvider] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }
        return try JSONDecoder().decode(LibraryFile.self, from: data).providers
    }

    func save(_ providers: [StoredProvider]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(LibraryFile(providers: providers))
        try AtomicFileWriter.write(data, to: url, backup: false)
    }

    private struct LibraryFile: Codable {
        var version = 1
        var providers: [StoredProvider]
    }
}

enum ProviderSlug {
    /// Codex table names must be valid bare keys and cannot shadow built-ins.
    static func suggest(from name: String, existing: Set<String>) -> String {
        let lowered = name.lowercased()
        var slug = ""
        for character in lowered {
            if character.isLetter || character.isNumber { slug.append(character) }
            else if !slug.hasSuffix("-") { slug.append("-") }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty || !(slug.first?.isLetter ?? false) { slug = "provider-\(slug)" }
        slug = String(slug.prefix(28))
        var candidate = slug
        var suffix = 2
        while existing.contains(candidate) || ProviderIDRules.reservedCodexIDs.contains(candidate) {
            candidate = "\(slug)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}
