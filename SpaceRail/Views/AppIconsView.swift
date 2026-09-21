import SwiftUI

struct AppIconsView: View {
    let windows: [WindowSlot]
    private let icons = AppIconService.shared

    var body: some View {
        HStack(spacing: 6) {
            ForEach(windows, id: \.windowID) { slot in
                Group {
                    if let icon = icons.cached(slot.bundleID) {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "app.dashed")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 32, height: 32)
            }
        }
    }
}
