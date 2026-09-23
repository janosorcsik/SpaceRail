import Foundation
import os

struct StateStore {
    let url: URL

    init(profile: AppProfile = .current) {
        url = profile.stateURL
    }

    init(url: URL) {
        self.url = url
    }

    // nil when there is nothing (valid) on disk yet. An unreadable file is moved aside rather than
    // left for the next save to overwrite, so the user's workspaces can still be recovered by hand.
    func load() -> WorkspaceState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(WorkspaceState.self, from: data)
        } catch {
            Log.store.error("Failed to decode state, starting empty: \(String(describing: error), privacy: .public)")
            moveAside()
            return nil
        }
    }

    func save(_ state: WorkspaceState) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            Log.store.error("Failed to save state: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func moveAside() {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let backup = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            Log.store.notice("kept the unreadable state at \(backup.path, privacy: .public)")
        } catch {
            Log.store.error("Failed to move unreadable state aside: \(error.localizedDescription, privacy: .public)")
        }
    }
}
