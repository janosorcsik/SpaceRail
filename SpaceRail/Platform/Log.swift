import Foundation
import os

nonisolated enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.janosorcsik.SpaceRail"

    static let engine = Logger(subsystem: subsystem, category: "engine")
    static let ax = Logger(subsystem: subsystem, category: "ax")
    static let panel = Logger(subsystem: subsystem, category: "panel")
    static let store = Logger(subsystem: subsystem, category: "store")
}
