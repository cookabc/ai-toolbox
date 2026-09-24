import Foundation

/// Reads the usage Codex and Claude Code record in their own session transcripts.
///
/// The transcripts are append-only JSONL files that can grow to gigabytes, and the
/// panel re-reads them every 30 seconds. So each file's parsed state is kept, and a
/// file that only grew is read **from where the last read stopped**: a refresh costs
/// one `lstat` per file plus the bytes appended since. A file that shrank, was
/// replaced, or whose bytes before the resume point changed is read again in full.
///
/// Only IDs, timestamps, model names and counters are kept. Message bodies and tool
/// arguments pass through the decoder and are dropped with the line.
final class TranscriptUsageProvider: UsageProvider, @unchecked Sendable {
    let id: UsageProviderID
    let rootURL: URL
    private let now: @Sendable () -> Date
    private let calendar: @Sendable () -> Calendar

    /// Guards everything below and serialises whole loads: two overlapping reads
    /// would otherwise resume the same file from the same offset twice.
    private let lock = NSLock()
    private var files: [String: TranscriptFile] = [:]
    private var aggregate: (day: Date, snapshot: UsageSnapshot)?

    init(
        _ id: UsageProviderID,
        rootURL: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: @escaping @Sendable () -> Calendar = { Calendar.current }
    ) {
        self.id = id
        self.rootURL = rootURL ?? id.directory
        self.now = now
        self.calendar = calendar
    }

    func load() throws -> UsageSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard FileStat.of(rootURL.path)?.isDirectory == true else {
            files = [:]
            aggregate = nil
            throw ProviderReadError.missing(id)
        }

        var changed = false
        var next: [String: TranscriptFile] = [:]
        for path in TranscriptLayout.files(for: id, root: rootURL.path) {
            guard let stat = FileStat.of(path), stat.isRegular else { continue }
            if let known = files[path], known.stat == stat {
                next[path] = known
                continue
            }
            changed = true
            next[path] = TranscriptFile.read(path: path, stat: stat, format: id, resuming: files[path])
        }
        if next.count != files.count { changed = true }
        files = next

        let instant = now()
        let calendar = calendar()
        let day = calendar.startOfDay(for: instant)
        if !changed, let aggregate, aggregate.day == day {
            var snapshot = aggregate.snapshot
            snapshot.refreshedAt = instant
            return snapshot
        }
        var snapshot = try TranscriptAggregator.snapshot(
            of: files, provider: id, calendar: calendar
        )
        snapshot.refreshedAt = instant
        aggregate = (day, snapshot)
        return snapshot
    }
}

// MARK: - File layout

enum TranscriptLayout {
    /// Codex: every `.jsonl` below `sessions/` and `archived_sessions/`.
    /// Claude Code: `<project>/<session>.jsonl` and
    /// `<project>/<session>/subagents/<agent>.jsonl`, nothing deeper.
    ///
    /// Symbolic links are never followed, so a link cannot pull files from outside
    /// the tool's own directory into the totals. Sorted, so duplicate records across
    /// files resolve the same way on every read.
    static func files(for id: UsageProviderID, root: String) -> [String] {
        var result: [String] = []
        switch id {
        case .codex:
            var pending = ["sessions", "archived_sessions"].map { root + "/" + $0 }
            while let directory = pending.popLast() {
                for entry in children(directory) {
                    guard let stat = FileStat.of(entry) else { continue }
                    if stat.isDirectory { pending.append(entry) }
                    else if stat.isRegular, entry.hasSuffix(".jsonl") { result.append(entry) }
                }
            }
        case .claude:
            for project in children(root) where FileStat.of(project)?.isDirectory == true {
                for entry in children(project) {
                    guard let stat = FileStat.of(entry) else { continue }
                    if stat.isRegular, entry.hasSuffix(".jsonl") {
                        result.append(entry)
                    } else if stat.isDirectory {
                        let subagents = entry + "/subagents"
                        guard FileStat.of(subagents)?.isDirectory == true else { continue }
                        for agent in children(subagents) where agent.hasSuffix(".jsonl")
                            && FileStat.of(agent)?.isRegular == true {
                            result.append(agent)
                        }
                    }
                }
            }
        }
        return result.sorted()
    }

    private static func children(_ directory: String) -> [String] {
        guard FileStat.of(directory)?.isDirectory == true,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory)
        else { return [] }
        return names.map { directory + "/" + $0 }
    }
}

/// `lstat`, so a symbolic link reports itself rather than its target.
struct FileStat: Equatable, Sendable {
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let isRegular: Bool
    let isDirectory: Bool

    static func of(_ path: String) -> FileStat? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let type = info.st_mode & S_IFMT
        return FileStat(
            device: Int64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec,
            isRegular: type == S_IFREG,
            isDirectory: type == S_IFDIR
        )
    }

    func isSameFile(as other: FileStat) -> Bool {
        device == other.device && inode == other.inode
    }

    /// Matches no real file, so a file stored with it is always read again.
    static let unreadable = FileStat(device: -1, inode: 0, size: -1, modifiedSeconds: 0,
                                     modifiedNanoseconds: 0, isRegular: false, isDirectory: false)
}

// MARK: - One file

struct TranscriptFile: Sendable {
    var stat: FileStat
    /// Byte offset just past the last complete line read.
    var offset: Int64
    /// The first and last bytes of what was read. A resume only happens when both are
    /// unchanged, which catches a file rewritten in place to the same or larger size:
    /// a different session starts with a different header, and an edited tail ends
    /// differently.
    var fingerprint: Data
    var records = TranscriptRecords()

    static func read(path: String, stat: FileStat, format: UsageProviderID,
                     resuming previous: TranscriptFile?) -> TranscriptFile {
        var file: TranscriptFile
        if let previous, previous.stat.isSameFile(as: stat), stat.size >= previous.offset,
           TranscriptJSONL.fingerprint(of: path, upTo: previous.offset) == previous.fingerprint {
            file = previous
            file.stat = stat
        } else {
            file = TranscriptFile(stat: stat, offset: 0, fingerprint: Data())
        }
        var parser = TranscriptLineParser(format: format)
        var records = file.records
        let result = TranscriptJSONL.read(
            path: path,
            from: file.offset,
            mayMatter: { TranscriptLineParser.mayMatter($0, format: format) },
            mentionsUsage: { TranscriptLineParser.mentionsUsage($0, format: format) },
            consume: { try parser.consume($0, into: &records) }
        )
        guard let result else {
            // Unreadable right now (permissions, a file being replaced). Keep what was
            // read before so a transient error does not erase history, and forget the
            // stat so the next refresh tries again instead of trusting this one.
            file.stat = FileStat.unreadable
            if previous == nil { file.records.skipped = 1 }
            return file
        }
        records.skipped += result.skipped
        file.records = records
        file.offset = result.endOffset
        file.fingerprint = result.fingerprint
        return file
    }
}

/// What one file contributed. Every collection is keyed by an ID the tool assigned,
/// so reading a line twice — a resumed tail, or the same record copied into a
/// forked or resumed session — can never count it twice.
struct TranscriptRecords: Sendable {
    var samples: [TranscriptKey: TranscriptSample] = [:]
    var turns: [String: Date?] = [:]
    var tools: [String: Date?] = [:]
    /// Codex only: which model served each turn.
    var turnModels: [String: String] = [:]
    var skipped = 0
}

struct TranscriptKey: Hashable, Sendable {
    let message: String
    let request: String?
}

struct TranscriptSample: Sendable {
    var tokens: TranscriptTokens
    var model: String?
    var turnID: String?
    var date: Date?

    /// Streaming and copying write the same response more than once. The copy with
    /// the latest timestamp is the complete one; on a tie, or without timestamps,
    /// the one read last wins.
    func shouldReplace(_ existing: TranscriptSample) -> Bool {
        guard let date, let old = existing.date else { return true }
        return date >= old
    }
}

// MARK: - Aggregation

enum TranscriptAggregator {
    static func snapshot(of files: [String: TranscriptFile], provider: UsageProviderID,
                         calendar: Calendar) throws -> UsageSnapshot {
        var samples: [TranscriptKey: TranscriptSample] = [:]
        var turns: [String: Date?] = [:]
        var tools: [String: Date?] = [:]
        var turnModels: [String: String] = [:]
        var skipped = 0
        for path in files.keys.sorted() {
            let records = files[path]!.records
            skipped += records.skipped
            for (key, sample) in records.samples {
                if let existing = samples[key], !sample.shouldReplace(existing) { continue }
                samples[key] = sample
            }
            turns.merge(records.turns) { earliest($0, $1) }
            tools.merge(records.tools) { earliest($0, $1) }
            turnModels.merge(records.turnModels) { current, _ in current }
        }
        guard !samples.isEmpty else {
            throw skipped > 0 ? ProviderReadError.incompatible(provider) : ProviderReadError.noRecords(provider)
        }

        var totals = UsageTotals()
        var days: [Date: UsageTotals] = [:]
        var models: [String: (requests: Int64, input: Int64, output: Int64)] = [:]
        var reported: Set<UsageMetric> = []
        var undated = 0
        var dayCache: [Int: Date] = [:]
        func dayStart(_ date: Date) -> Date {
            // Most records share a handful of days; skip the calendar for repeats. The
            // bucket is 15 minutes because every time zone offset is a multiple of it,
            // so no bucket straddles a local midnight.
            let bucket = Int((date.timeIntervalSinceReferenceDate / 900).rounded(.down))
            if let cached = dayCache[bucket] { return cached }
            let start = calendar.startOfDay(for: date)
            dayCache[bucket] = start
            return start
        }

        for sample in samples.values {
            let tokens = sample.tokens
            reported.formUnion(tokens.reported)
            totals.add(tokens)
            if let date = sample.date { days[dayStart(date), default: UsageTotals()].add(tokens) }
            else { undated += 1 }
            let model = sample.model ?? sample.turnID.flatMap { turnModels[$0] } ?? "unknown"
            var entry = models[model] ?? (0, 0, 0)
            entry.requests = saturating(entry.requests, 1)
            entry.input = saturating(entry.input, tokens.input)
            entry.output = saturating(entry.output, tokens.output)
            models[model] = entry
        }
        for date in turns.values {
            totals.turns = saturating(totals.turns, 1)
            if let date { days[dayStart(date), default: UsageTotals()].turns += 1 }
        }
        for date in tools.values {
            totals.toolCalls = saturating(totals.toolCalls, 1)
            if let date { days[dayStart(date), default: UsageTotals()].toolCalls += 1 }
        }

        let ranked = models.map { ModelUsage(modelID: $0.key, requests: $0.value.requests,
                                             inputTokens: $0.value.input, outputTokens: $0.value.output) }
            .sorted { $0.outputTokens != $1.outputTokens ? $0.outputTokens > $1.outputTokens : $0.modelID < $1.modelID }
        return UsageSnapshot(
            refreshedAt: Date(),
            totals: totals,
            daily: days.keys.sorted().map { DailyUsage(date: $0, totals: days[$0]!) },
            models: ranked,
            coverage: UsageCoverage(fileCount: files.count, skippedRecords: skipped,
                                    undatedRecords: undated, reported: reported)
        )
    }

    private static func earliest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return min(lhs, rhs)
    }
}

func saturating(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int64.max : sum
}

extension UsageTotals {
    mutating func add(_ tokens: TranscriptTokens) {
        requests = saturating(requests, 1)
        inputTokens = saturating(inputTokens, tokens.input)
        cacheReadTokens = saturating(cacheReadTokens, tokens.cacheRead)
        cacheWriteTokens = saturating(cacheWriteTokens, tokens.cacheWrite)
        outputTokens = saturating(outputTokens, tokens.output)
        reasoningTokens = saturating(reasoningTokens, tokens.reasoning)
    }
}
