import os

/// Loggers for the unified log; filter with `log stream --predicate 'subsystem == "at.idling.out-of-space-swiftly"'`.
nonisolated enum Log {
    static let subsystem = "at.idling.out-of-space-swiftly"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let scan = Logger(subsystem: subsystem, category: "scan")
}
