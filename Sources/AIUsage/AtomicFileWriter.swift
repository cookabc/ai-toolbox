import Foundation

enum AtomicFileWriter {
    static func write(_ data: Data, to url: URL, posixPermissions: Int = 0o600, backup: Bool = true) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if backup, FileManager.default.fileExists(atPath: url.path) {
            let backup = URL(fileURLWithPath: url.path + ".ai-usage.bak")
            if FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.removeItem(at: backup)
            }
            try FileManager.default.copyItem(at: url, to: backup)
            try FileManager.default.setAttributes(
                [.posixPermissions: posixPermissions],
                ofItemAtPath: backup.path
            )
        }
        let temp = try copyData(data, in: directory, permissions: posixPermissions)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: temp, to: url)
        try FileManager.default.setAttributes([.posixPermissions: posixPermissions], ofItemAtPath: url.path)
    }

    private static func copyData(_ data: Data, in directory: URL, permissions: Int) throws -> URL {
        let temp = directory.appending(path: ".\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
        return temp
    }
}
