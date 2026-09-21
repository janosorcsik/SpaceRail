import Foundation
import os

struct StateStore {
    let url: URL

    init(profile: AppProfile = .current) {
        url = profile.stateURL
    }

    // nil when there is nothing (valid) on disk yet.
    func load() -> WorkspaceState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(WorkspaceState.self, from: data)
        } catch {
            Log.store.error("Failed to decode state, starting empty: \(error.localizedDescription, privacy: .public)")
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
}
