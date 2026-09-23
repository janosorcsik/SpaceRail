import CoreGraphics
import Foundation
import Testing

private let rect = CGRect(x: 10, y: 20, width: 300, height: 200)

private func slot(_ id: CGWindowID, _ bundleID: String, frame: CGRect = rect) -> WindowSlot {
    WindowSlot(windowID: id, bundleID: bundleID, frame: frame)
}

private func state(_ windows: [Int: [WindowSlot]]) -> WorkspaceState {
    var state = WorkspaceState()
    for (id, slots) in windows {
        state.update(id) { $0.windows = slots }
    }
    return state
}

// owners: window ID → (pid, bundle ID)
private func list(_ owners: [CGWindowID: (pid_t, String)]) -> WindowList {
    WindowList(
        owners: owners.mapValues(\.0),
        bundleIDs: Dictionary(owners.values.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
    )
}

@Suite struct Decoding {
    @Test func fileFromBeforeVersioningLoads() throws {
        let json = #"""
        {"nextID":4,"selectedID":2,"pendingApps":{"com.a":{"workspaceID":3,"frames":[[[1,2],[3,4]]]}},
         "workspaces":[{"id":1,"name":"One","windows":[{"windowID":7,"bundleID":"com.b","frame":[[0,0],[10,10]]}]},
                       {"id":2,"name":"Two","windows":[]},{"id":3,"name":"Three","windows":[]}]}
        """#
        let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(json.utf8))
        #expect(state.version == WorkspaceState.currentVersion)
        #expect(state.workspaces.map(\.name) == ["One", "Two", "Three"])
        #expect(state.selectedID == 2)
        #expect(state.pendingApps["com.a"]?.slots == [PendingApp.Slot(workspaceID: 3, frame: CGRect(x: 1, y: 2, width: 3, height: 4))])
    }

    @Test func missingFieldsFallBack() throws {
        let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(#"{"workspaces":[{"id":7}]}"#.utf8))
        #expect(state.workspaces.first?.name == "7")
        #expect(state.nextID == 8)
        #expect(state.selectedID == 7)
        #expect(state.pendingApps.isEmpty)
    }

    @Test func emptyPendingEntriesAreDropped() throws {
        let json = #"{"workspaces":[{"id":1}],"pendingApps":{"com.a":{"workspaceID":1,"frames":[]}}}"#
        let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(json.utf8))
        #expect(state.pendingApps.isEmpty)
    }

    @Test func roundTrip() throws {
        var original = state([1: [slot(5, "com.a")]])
        original.pendingApps["com.b"] = PendingApp(slots: [.init(workspaceID: 2, frame: rect)])
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(original))
        #expect(decoded.workspaces.first?.windows == [slot(5, "com.a")])
        #expect(decoded.pendingApps["com.b"]?.slots == original.pendingApps["com.b"]?.slots)
    }

    @Test func unreadableFileIsKept() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "state.json")
        try Data("not json".utf8).write(to: url)

        #expect(StateStore(url: url).load() == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!files.contains("state.json"))
        #expect(files.contains { $0.hasPrefix("state.unreadable-") })
    }
}

@Suite struct Retiring {
    @Test func reusedIDOfAnotherAppIsNotAlive() {
        var state = state([1: [slot(100, "com.safari")]])
        // After a restart window 100 belongs to someone else, and Safari isn't running.
        state.retireDeadWindows(in: list([100: (9, "com.other")]), atLaunch: true)
        #expect(state.workspaces[0].windows.isEmpty)
        #expect(state.pendingApps["com.safari"]?.slots.map(\.workspaceID) == [1])
    }

    @Test func runningAppWithNoSurvivingWindowsIsPendingAtLaunch() {
        var state = state([1: [slot(100, "com.notes")]])
        state.retireDeadWindows(in: list([555: (4, "com.notes")]), atLaunch: true)
        #expect(state.pendingApps["com.notes"] != nil)
    }

    @Test func closedWindowOfRunningAppIsJustDroppedLater() {
        var state = state([1: [slot(100, "com.notes")]])
        let removed = state.retireDeadWindows(in: list([555: (4, "com.notes")]), atLaunch: false)
        #expect(removed == 1)
        #expect(state.pendingApps.isEmpty)
    }

    @Test func oneSurvivingWindowMeansTheOthersWereClosed() {
        var state = state([1: [slot(100, "com.notes"), slot(101, "com.notes")]])
        state.retireDeadWindows(in: list([101: (4, "com.notes")]), atLaunch: true)
        #expect(state.workspaces[0].windows.map(\.windowID) == [101])
        #expect(state.pendingApps.isEmpty)
    }

    @Test func appInSeveralWorkspacesRemembersEach() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 50, y: 50, width: 200, height: 200)
        var state = state([1: [slot(1, "com.term", frame: a)], 3: [slot(2, "com.term", frame: b)]])
        state.makePending("com.term")
        #expect(state.pendingApps["com.term"]?.slots == [.init(workspaceID: 1, frame: a), .init(workspaceID: 3, frame: b)])
        #expect(state.workspaces.allSatisfy { $0.windows.isEmpty })
        #expect(state.pendingBundleIDs(in: 3) == ["com.term"])
        #expect(state.pendingBundleIDs(in: 2).isEmpty)
    }
}

@Suite struct Workspaces {
    @Test func removingAWorkspaceDropsItsPendingSlots() {
        var state = WorkspaceState()
        state.pendingApps["com.a"] = PendingApp(slots: [.init(workspaceID: 2, frame: rect), .init(workspaceID: 3, frame: rect)])
        state.pendingApps["com.b"] = PendingApp(slots: [.init(workspaceID: 2, frame: rect)])
        state.selectedID = 2
        state.removeWorkspace(2)
        #expect(state.workspaces.map(\.id) == [1, 3])
        #expect(state.pendingApps["com.a"]?.workspaceIDs == [3])
        #expect(state.pendingApps["com.b"] == nil)
        #expect(state.selectedID == 1)
    }

    @Test func lastWorkspaceCannotBeRemoved() {
        var state = WorkspaceState()
        state.removeWorkspace(1)
        state.removeWorkspace(2)
        state.removeWorkspace(3)
        #expect(state.workspaces.map(\.id) == [3])
    }
}
