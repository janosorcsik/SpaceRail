import CoreGraphics

extension CGRect {
    // AX reports geometry in points; apps sometimes settle a pixel off from what we asked for.
    nonisolated func isClose(to other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

nonisolated struct WindowSlot: Codable, Hashable, Sendable {
    var windowID: CGWindowID
    var bundleID: String
    var frame: CGRect
}

nonisolated struct Workspace: Codable, Identifiable, Sendable {
    let id: Int
    var name: String
    // Most recently focused first.
    var windows: [WindowSlot] = []

    var bundleIDs: [String] { windows.map(\.bundleID) }
}

// What to do when an app whose windows we tracked comes back after a quit or reboot.
nonisolated struct PendingApp: Codable, Sendable {
    var workspaceID: Int
    var frames: [CGRect]
}

nonisolated struct WorkspaceState: Codable, Sendable {
    static let initialCount = 3

    var workspaces: [Workspace]
    // IDs are never reused so stored shortcuts can't leak onto a later workspace.
    var nextID: Int
    var selectedID: Int
    var pendingApps: [String: PendingApp] = [:]

    init() {
        workspaces = (1...Self.initialCount).map { Workspace(id: $0, name: "\($0)") }
        nextID = Self.initialCount + 1
        selectedID = 1
    }

    var selected: Workspace? { workspace(selectedID) }

    func workspace(_ id: Int) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    func index(of id: Int) -> Int? {
        workspaces.firstIndex { $0.id == id }
    }

    mutating func update(_ id: Int, _ body: (inout Workspace) -> Void) {
        guard let index = index(of: id) else { return }
        body(&workspaces[index])
    }

    func workspaceID(containing windowID: CGWindowID) -> Int? {
        workspaces.first { $0.windows.contains { $0.windowID == windowID } }?.id
    }

    mutating func remove(windowID: CGWindowID) {
        for index in workspaces.indices {
            workspaces[index].windows.removeAll { $0.windowID == windowID }
        }
    }

    mutating func removeAll(where predicate: (WindowSlot) -> Bool) {
        for index in workspaces.indices {
            workspaces[index].windows.removeAll(where: predicate)
        }
    }
}
