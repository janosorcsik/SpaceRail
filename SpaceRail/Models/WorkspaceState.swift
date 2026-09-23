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

    init(id: Int, name: String, windows: [WindowSlot] = []) {
        self.id = id
        self.name = name
        self.windows = windows
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "\(id)"
        windows = try container.decodeIfPresent([WindowSlot].self, forKey: .windows) ?? []
    }
}

// What to do when an app whose windows we tracked comes back after a quit or reboot.
nonisolated struct PendingApp: Codable, Sendable {
    var workspaceID: Int
    var frames: [CGRect]
}

nonisolated struct WorkspaceState: Codable, Sendable {
    static let initialCount = 3
    // Bump when the meaning of a stored field changes; new fields just need a fallback in init(from:).
    static let currentVersion = 1

    var version = Self.currentVersion
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

    // Synthesized decoding requires every key, even ones with a default value, so a file written
    // before a field existed would fail to load and be replaced. Everything but the workspace list
    // falls back instead.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Files without a version are version 1 (the format has not changed meaning yet); a future
        // migration reads `.version` here before anything else.
        workspaces = try container.decode([Workspace].self, forKey: .workspaces)
        if workspaces.isEmpty { workspaces = WorkspaceState().workspaces }
        let highestID = workspaces.map(\.id).max() ?? 0
        nextID = max(try container.decodeIfPresent(Int.self, forKey: .nextID) ?? 0, highestID + 1)
        selectedID = try container.decodeIfPresent(Int.self, forKey: .selectedID) ?? workspaces[0].id
        pendingApps = try container.decodeIfPresent([String: PendingApp].self, forKey: .pendingApps) ?? [:]
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
