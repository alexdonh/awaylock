import Foundation
import os

nonisolated enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "nearby"
    static let bluetooth = Logger(subsystem: subsystem, category: "bluetooth")
    static let session = Logger(subsystem: subsystem, category: "session")
    static let updates = Logger(subsystem: subsystem, category: "updates")
}
