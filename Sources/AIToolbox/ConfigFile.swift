import Foundation

/// Reads and writes configuration files that other tools own.
///
/// Every write is a read-modify-write of the file **as it is on disk right now**,
/// never of a copy read earlier. Codex and Claude Code rewrite their own configs —
/// trusting a project, installing a plugin, a setting changed in the CLI — and
/// writing back an older copy would silently undo that.
///
/// The replacement is atomic: a temporary file is renamed over the target, so no
/// reader ever sees a half-written or missing file. A symbolic link, as in a
/// dotfiles setup, is written through to its target instead of being replaced by a
/// regular file.
enum ConfigFile {
    static let backupSuffix = ".ai-toolbox.bak"

    /// The file's bytes, or `nil` when it does not exist.
    static func read(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url.resolvingSymlinksInPath())
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch let error as CocoaError where (error.underlying as? POSIXError)?.code == .ENOENT {
            return nil
        }
    }

    /// Applies `transform` to the current contents and writes the result back.
    ///
    /// `transform` receives `nil` when the file does not exist and returns `nil` to
    /// leave it alone. It may run more than once: when the file changes between the
    /// read and the write, the edit is redone on the newer contents rather than
    /// written over them. Returns whether the file was written.
    @discardableResult
    static func update(_ url: URL, backup: Bool = true, _ transform: (Data?) throws -> Data?) throws -> Bool {
        let target = url.resolvingSymlinksInPath()
        for _ in 0..<3 {
            let before = try read(target)
            guard let next = try transform(before), next != before else { return false }
            guard try read(target) == before else { continue }
            if backup, let before {
                try replace(URL(fileURLWithPath: url.path + backupSuffix).resolvingSymlinksInPath(), with: before)
            }
            try replace(target, with: next)
            return true
        }
        throw LiveConfigError.writeFailed("\(url.lastPathComponent) 正在被其他程序频繁修改，请稍后重试。")
    }

    /// Writes a file this app owns outright.
    static func write(_ data: Data, to url: URL) throws {
        try replace(url.resolvingSymlinksInPath(), with: data)
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Owner-only, because most of these files hold API keys.
    private static func replace(_ target: URL, with data: Data) throws {
        let directory = target.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw LiveConfigError.writeFailed("无法创建目录 \(directory.path)。")
        }
        let temp = directory.appending(path: ".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure(errno, target) }
        var renamed = false
        defer { if !renamed { unlink(temp.path) } }

        let written = data.withUnsafeBytes { bytes -> Int32 in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += count
            }
            return fsync(descriptor) == 0 ? 0 : errno
        }
        close(descriptor)
        guard written == 0 else { throw failure(written, target) }
        guard rename(temp.path, target.path) == 0 else { throw failure(errno, target) }
        renamed = true
    }

    private static func failure(_ code: Int32, _ url: URL) -> LiveConfigError {
        switch code {
        case EACCES, EPERM: .writeFailed("没有写入 \(url.path) 的权限。")
        case ENOSPC, EDQUOT: .writeFailed("磁盘空间不足，\(url.lastPathComponent) 未写入。")
        case EROFS: .writeFailed("\(url.path) 所在的卷是只读的。")
        default: .writeFailed("\(url.lastPathComponent)：\(String(cString: strerror(code)))")
        }
    }
}
