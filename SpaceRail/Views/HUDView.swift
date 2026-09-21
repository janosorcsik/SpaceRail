import KeyboardShortcuts
import SwiftUI

struct HUDView: View {
    let engine: WorkspaceEngine

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(engine.state.workspaces) { workspace in
                WorkspaceCard(
                    workspace: workspace,
                    pendingBundleIDs: engine.state.pendingApps.filter { $0.value.workspaceID == workspace.id }.keys.sorted(),
                    isSelected: workspace.id == engine.state.selectedID,
                    shortcut: KeyboardShortcuts.getShortcut(for: .switchTo(workspace.id))?.description
                )
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .fixedSize()
    }
}

private struct WorkspaceCard: View {
    let workspace: Workspace
    // Apps that belong here but aren't running; shown dimmed, launched on switch.
    let pendingBundleIDs: [String]
    let isSelected: Bool
    let shortcut: String?

    private static let iconSize: CGFloat = 40
    private static let columns = Array(repeating: GridItem(.fixed(iconSize), spacing: 8), count: 3)

    private struct AppEntry: Identifiable {
        let bundleID: String
        let count: Int
        let isPending: Bool
        var id: String { bundleID }
    }

    private var apps: [AppEntry] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for slot in workspace.windows {
            if counts[slot.bundleID] == nil { order.append(slot.bundleID) }
            counts[slot.bundleID, default: 0] += 1
        }
        return order.map { AppEntry(bundleID: $0, count: counts[$0] ?? 0, isPending: false) }
            + pendingBundleIDs.map { AppEntry(bundleID: $0, count: 0, isPending: true) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(workspace.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if apps.isEmpty {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.tertiary)
                    .frame(height: Self.iconSize)
                    .overlay {
                        Text("No windows")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
            } else {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 8) {
                    ForEach(apps) { app in
                        AppIcon(bundleID: app.bundleID, count: app.count, size: Self.iconSize)
                            .opacity(app.isPending ? 0.35 : 1)
                            .help(app.isPending ? "\(app.bundleID) — not running, launches on switch" : app.bundleID)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 168, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

private struct AppIcon: View {
    let bundleID: String
    let count: Int
    let size: CGFloat

    private let icons = AppIconService.shared

    var body: some View {
        Group {
            if let icon = icons.cached(bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(6)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if count > 1 {
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
                    .offset(x: 4, y: 4)
            }
        }
        .help(bundleID)
    }
}
