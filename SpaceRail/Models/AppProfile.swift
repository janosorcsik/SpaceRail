import Foundation

// Keeps the dev build's state out of the release build's directory.
nonisolated struct AppProfile: Sendable {
    static let debug = AppProfile(dataDirectoryName: "SpaceRail Dev")
    static let release = AppProfile(dataDirectoryName: "SpaceRail")

    static var current: AppProfile {
        #if DEBUG
        debug
        #else
        release
        #endif
    }

    let dataDirectoryName: String

    var dataDirectoryURL: URL {
        URL.applicationSupportDirectory.appending(path: dataDirectoryName, directoryHint: .isDirectory)
    }

    var stateURL: URL {
        dataDirectoryURL.appending(path: "state.json")
    }
}
