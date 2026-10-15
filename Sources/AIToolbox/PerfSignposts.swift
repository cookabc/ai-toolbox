import os

/// Signposts for the writes that repaint the popover.
///
/// The in-process baseline (`PanelPerformanceTests`) counts publishes with Combine; these events put
/// the same writes in the unified log and in Instruments, so the 30 s timer cadence can be read off a
/// real session instead of trusting the test's own counter. Debug-only, like `SensorHub` in 037-vitals.
///
///     /usr/bin/log show --last 5m --predicate 'subsystem == "io.github.cookabc.ai-toolbox"' --info --debug --style compact
enum PerfSignpost {
    #if DEBUG
    private static let log = OSLog(subsystem: "io.github.cookabc.ai-toolbox", category: "perf")
    private static let logger = Logger(subsystem: "io.github.cookabc.ai-toolbox", category: "perf")
    #endif

    /// One `@Published` write, i.e. one whole-tree body recompute while the panel is visible.
    static func publish(_ field: String) {
        #if DEBUG
        let id = OSSignpostID(log: log)
        os_signpost(.event, log: log, name: "publish", signpostID: id)
        logger.info("publish field=\(field, privacy: .public)")
        #endif
    }
}
