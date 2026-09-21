import AppKit
import Observation

@Observable
final class AppIconService {
    static let shared = AppIconService()

    // Bumped when a prefetch lands so views re-read the cache.
    private(set) var version = 0

    @ObservationIgnored private var cache: [String: NSImage] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []

    // Never loads; the HUD body calls this.
    func cached(_ bundleID: String) -> NSImage? {
        _ = version
        return cache[bundleID]
    }

    func prefetch(_ bundleIDs: [String]) {
        let missing = Set(bundleIDs).filter { cache[$0] == nil && !inFlight.contains($0) }
        guard !missing.isEmpty else { return }
        inFlight.formUnion(missing)

        Task {
            let loaded = await Self.loadIcons(missing)
            cache.merge(loaded) { _, new in new }
            inFlight.subtract(missing)
            version += 1
        }
    }

    // Launch Services lookup plus ICNS decoding: off the main actor by construction.
    @concurrent
    private nonisolated static func loadIcons(_ bundleIDs: Set<String>) async -> [String: NSImage] {
        var icons: [String: NSImage] = [:]
        for bundleID in bundleIDs {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            icons[bundleID] = NSWorkspace.shared.icon(forFile: url.path)
        }
        return icons
    }
}
