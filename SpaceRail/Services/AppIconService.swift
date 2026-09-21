import AppKit
import Observation

@Observable
final class AppIconService {
    static let shared = AppIconService()

    // Bumped when a prefetch lands so views re-read the cache.
    private(set) var version = 0

    @ObservationIgnored private let cache = NSCache<NSString, NSImage>()
    @ObservationIgnored private var inFlight: Set<String> = []

    // Never loads; the HUD body calls this.
    func cached(_ bundleID: String) -> NSImage? {
        _ = version
        return cache.object(forKey: bundleID as NSString)
    }

    func prefetch(_ bundleIDs: [String]) {
        let missing = Set(bundleIDs).filter { cache.object(forKey: $0 as NSString) == nil && !inFlight.contains($0) }
        guard !missing.isEmpty else { return }
        inFlight.formUnion(missing)

        Task.detached(priority: .utility) { [cache] in
            var loaded: [String: NSImage] = [:]
            for bundleID in missing {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
                loaded[bundleID] = NSWorkspace.shared.icon(forFile: url.path)
            }
            for (bundleID, icon) in loaded {
                cache.setObject(icon, forKey: bundleID as NSString)
            }
            await MainActor.run {
                self.inFlight.subtract(missing)
                self.version += 1
            }
        }
    }
}
