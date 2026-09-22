import AppKit
import Observation

// Icons and display names for apps by bundle ID. Reads are cache-only; loading happens off the
// main actor on prefetch so views never block on Launch Services or ICNS decoding.
@Observable
final class AppIconService {
    static let shared = AppIconService()

    nonisolated struct Info: Sendable {
        let icon: NSImage
        let name: String
    }

    // Bumped when a prefetch lands so views re-read the cache.
    private(set) var version = 0

    @ObservationIgnored private var cache: [String: Info] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []

    // Never loads; the HUD body calls this.
    func cached(_ bundleID: String) -> NSImage? {
        _ = version
        return cache[bundleID]?.icon
    }

    // Always answers: cached name, then the running app's, then the bundle ID's last component.
    func name(for bundleID: String) -> String {
        _ = version
        if let name = cache[bundleID]?.name { return name }
        if let name = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })?.localizedName {
            return name
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    func prefetch(_ bundleIDs: [String]) {
        let missing = Set(bundleIDs).filter { cache[$0] == nil && !inFlight.contains($0) }
        guard !missing.isEmpty else { return }
        inFlight.formUnion(missing)

        Task {
            let loaded = await Self.load(missing)
            cache.merge(loaded) { _, new in new }
            inFlight.subtract(missing)
            version += 1
        }
    }

    @concurrent
    private nonisolated static func load(_ bundleIDs: Set<String>) async -> [String: Info] {
        var infos: [String: Info] = [:]
        for bundleID in bundleIDs {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            infos[bundleID] = Info(icon: icon, name: name)
        }
        return infos
    }
}
