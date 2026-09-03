import os

/// Unified-log entries visible with:
/// log stream --predicate 'subsystem == "com.windowtiler.app"'
enum Log {
    static let app = Logger(subsystem: "com.windowtiler.app", category: "app")
    static let tiling = Logger(subsystem: "com.windowtiler.app", category: "tiling")
}
