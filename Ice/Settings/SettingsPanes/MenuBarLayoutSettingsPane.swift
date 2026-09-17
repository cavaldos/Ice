//
//  MenuBarLayoutSettingsPane.swift
//  Ice
//

import Cocoa
import SwiftUI
import UniformTypeIdentifiers

struct MenuBarLayoutSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openURL) private var openURL

    @State private var hasScreenRecordingPermission = ScreenCapture.cachedCheckPermissions()
    @State private var hasAccessibilityPermission = MenuBarItemAXDiscovery.isTrusted()
    @State private var sections = [MenuBarItemAXDiscovery.SectionKind: [RowItem]]()
    @State private var hiddenDividerX: CGFloat?
    @State private var alwaysHiddenDividerX: CGFloat?
    @State private var anchorY: CGFloat = 0

    private var totalCount: Int {
        sections.values.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Menu Bar Icons")
                    .font(.title)
                Text("\(totalCount)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: Capsule())

                Spacer()

                Button {
                    Task {
                        await refresh()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(IceButtonStyle())
            }

            if sections.isEmpty {
                if !hasAccessibilityPermission {
                    accessibilityPrompt
                } else if !hasScreenRecordingPermission {
                    permissionPrompt
                } else if appState.itemManager.isItemDiscoveryUnavailable {
                    discoveryUnavailable
                } else {
                    ContentUnavailableView(
                        "No menu bar items",
                        systemImage: "rectangle.topthird.inset.filled",
                        description: Text("Waiting for menu bar items to appear…")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {                        ForEach(SectionMeta.all, id: \.kind) { meta in
                            sectionView(meta: meta, items: sections[meta.kind] ?? [])
                        }
                        if hiddenDividerX == nil, alwaysHiddenDividerX == nil {
                            Text("Can't find Ice's section dividers — make sure the Hidden sections are enabled, then press Refresh.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(20)
        .task {
            await refresh()
        }
    }

    private func sectionView(meta: SectionMeta, items: [RowItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: meta.icon)
                Text(meta.title)
                    .font(.headline)
                Text(meta.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 8) {
                if items.isEmpty {
                    Text(meta.emptyHint)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(items) { item in
                        itemView(item)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onDrop(of: [.text], isTargeted: .constant(false), perform: { providers in
                guard let provider = providers.first else {
                    return false
                }
                _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                    guard
                        let idString = string as? String,
                        let id = UUID(uuidString: idString)
                    else {
                        return
                    }
                    Task { @MainActor in
                        await drop(itemID: id, to: meta.kind)
                    }
                }
                return true
            })
        }
    }

    private func itemView(_ item: RowItem) -> some View {
        VStack(spacing: 4) {
            if let systemName = item.systemImage {
                Image(systemName: systemName)
                    .font(.system(size: 22))
                    .frame(width: 44, height: 38)
            } else if let icon = item.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 38)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 44, height: 38)
            }
            Text(item.title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 76)
        }
        .frame(width: 76)
        .help(item.subtitle ?? item.title)
        .onDrag {
            NSItemProvider(object: item.id.uuidString as NSString)
        }
    }

    /// Thả item vào nhóm mới: chuyển UI ngay, Command-drag icon thật trên
    /// menubar tới sát vạch chia đích, rồi quét lại vị trí thật.
    private func drop(itemID: UUID, to kind: MenuBarItemAXDiscovery.SectionKind) async {
        guard let (item, fromKind) = removeItem(id: itemID) else {
            return
        }
        guard fromKind != kind else {
            // Thả về đúng nhóm cũ thì trả lại chỗ cũ.
            sections[kind, default: []].append(item)
            return
        }
        sections[kind, default: []].append(item)
        guard
            let destination = destinationPoint(for: kind),
            let frame = item.cocoaFrame
        else {
            // Không biết thả đâu → quét lại vị trí thật.
            await refresh()
            return
        }
        await MenuBarItemAXMover.commandDrag(
            from: CGPoint(x: frame.midX, y: frame.midY),
            to: destination
        )
        try? await Task.sleep(for: .seconds(1))
        await refresh()
    }

    /// Gỡ item khỏi nhóm hiện tại, trả về item và nhóm cũ.
    private func removeItem(id: UUID) -> (RowItem, MenuBarItemAXDiscovery.SectionKind)? {
        for (kind, items) in sections {
            if let index = items.firstIndex(where: { $0.id == id }) {
                var updated = items
                let item = updated.remove(at: index)
                sections[kind] = updated
                return (item, kind)
            }
        }
        return nil
    }

    /// Điểm thả Command-drag cho nhóm đích: trong vùng của nhóm đó,
    /// cách vạch chia một đoạn để không rơi vào hitbox của vạch.
    private func destinationPoint(for kind: MenuBarItemAXDiscovery.SectionKind) -> CGPoint? {
        switch kind {
        case .visible:
            guard let x = hiddenDividerX ?? alwaysHiddenDividerX else {
                return nil
            }
            return CGPoint(x: x + 40, y: anchorY)
        case .hidden:
            guard let x = hiddenDividerX else {
                return nil
            }
            return CGPoint(x: x - 24, y: anchorY)
        case .alwaysHidden:
            guard let x = alwaysHiddenDividerX else {
                return nil
            }
            return CGPoint(x: x - 24, y: anchorY)
        }
    }

    private var accessibilityPrompt: some View {
        VStack(spacing: 12) {
            Text("Menu bar layout requires accessibility permission")
                .font(.title2)
            Text("Grant Accessibility access so Ice can list the icons in your menu bar.")
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button("Open System Settings") {
                    openURL(Self.accessibilitySettingsURL)
                }
                Button("Check Again") {
                    Task {
                        await refresh()
                    }
                }
            }
            .buttonStyle(IceButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permissionPrompt: some View {
        VStack(spacing: 12) {
            Text("Menu bar layout requires screen recording permission")
                .font(.title2)
            Text("Grant Screen Recording access so Ice can see the icons in your menu bar.")
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button("Open System Settings") {
                    openURL(Self.screenRecordingSettingsURL)
                }
                Button("Check Again") {
                    Task {
                        await refresh()
                    }
                }
            }
            .buttonStyle(IceButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var discoveryUnavailable: some View {
        VStack(spacing: 12) {
            Text("Menu Bar Layout isn't available on this macOS version")
                .font(.title2)
            Text("This version of macOS no longer exposes individual menu bar items to Ice.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refresh() async {
        hasScreenRecordingPermission = ScreenCapture.cachedCheckPermissions(reset: true)
        hasAccessibilityPermission = MenuBarItemAXDiscovery.isTrusted()
        if hasScreenRecordingPermission {
            await appState.itemManager.cacheItemsIfNeeded()
        }

        let manager = appState.menuBarManager
        let hiddenX = manager.section(withName: .hidden)?.controlItem.window?.frame.minX
        let alwaysHiddenX = manager.section(withName: .alwaysHidden)?.controlItem.window?.frame.minX
        hiddenDividerX = hiddenX
        alwaysHiddenDividerX = alwaysHiddenX
        // Tung độ thả chuột: giữa vạch chia, fallback giữa menubar.
        anchorY = manager.section(withName: .hidden)?.controlItem.window?.frame.midY
            ?? manager.section(withName: .alwaysHidden)?.controlItem.window?.frame.midY
            ?? (NSScreen.main.map { $0.frame.maxY - 12 } ?? 0)
        func kind(centerX: CGFloat?) -> MenuBarItemAXDiscovery.SectionKind {
            MenuBarItemAXDiscovery.classify(centerX: centerX, hiddenDividerX: hiddenX, alwaysHiddenDividerX: alwaysHiddenX)
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        var grouped = [MenuBarItemAXDiscovery.SectionKind: [RowItem]]()
        let cached = appState.itemManager.itemCache.allItems
        if !cached.isEmpty {
            for item in cached.sorted(by: { $0.frame.minX < $1.frame.minX }) {
                // Bỏ icon của chính Ice (các vạch chia) khỏi danh sách.
                guard item.owningApplication?.bundleIdentifier != ownBundleID else {
                    continue
                }
                grouped[kind(centerX: item.frame.midX), default: []].append(
                    RowItem(title: item.displayName, subtitle: item.subtitle, systemImage: nil, appIcon: item.owningApplication?.icon, cocoaFrame: item.frame)
                )
            }
        } else if hasAccessibilityPermission {
            let apps = NSWorkspace.shared.runningApplications
            let found = await Task.detached(priority: .userInitiated) {
                MenuBarItemAXDiscovery.discoverItems(in: apps)
            }.value
            // AX origin top-left → Cocoa origin bottom-left (trục X giữ nguyên).
            let screenHeight = NSScreen.main?.frame.height ?? 0
            var icons = [pid_t: NSImage]()
            for item in found.sorted(by: { ($0.axFrame?.midX ?? .greatestFiniteMagnitude) < ($1.axFrame?.midX ?? .greatestFiniteMagnitude) }) {
                let systemImage = MenuBarItemAXDiscovery.systemImageName(forIdentifier: item.identifier)
                var appIcon: NSImage?
                if systemImage == nil, icons[item.pid] == nil {
                    if item.bundleID == "com.apple.TextInputMenuAgent" {
                        icons[item.pid] = MenuBarItemAXDiscovery.inputSourceIcon()
                    } else {
                        icons[item.pid] = NSRunningApplication(processIdentifier: item.pid)?.icon
                    }
                }
                appIcon = icons[item.pid]
                let cocoaFrame = item.axFrame.map { frame in
                    CGRect(
                        x: frame.minX,
                        y: screenHeight - frame.maxY,
                        width: frame.width,
                        height: frame.height
                    )
                }
                grouped[kind(centerX: item.axFrame?.midX), default: []].append(
                    RowItem(title: item.displayName, subtitle: item.subtitle, systemImage: systemImage, appIcon: appIcon, cocoaFrame: cocoaFrame)
                )
            }
        }
        sections = grouped
    }

    private static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!
    private static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!
}

// MARK: - Row

private struct RowItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let systemImage: String?
    let appIcon: NSImage?
    /// Frame theo tọa độ Cocoa, dùng làm điểm bắt đầu khi Command-drag.
    let cocoaFrame: CGRect?
}

private struct SectionMeta {
    typealias Kind = MenuBarItemAXDiscovery.SectionKind

    let kind: Kind
    let title: String
    let icon: String
    let subtitle: String
    let emptyHint: String

    static let all = [
        SectionMeta(kind: .visible, title: "Visible", icon: "eye", subtitle: "Always in the menu bar", emptyHint: "No visible icons"),
        SectionMeta(kind: .hidden, title: "Hidden", icon: "eye.slash", subtitle: "A hover or click away — or ⌘-drag icons left of the chevron", emptyHint: "No hidden icons — drop icons here to hide them"),
        SectionMeta(kind: .alwaysHidden, title: "Always Hidden", icon: "moon", subtitle: "Out of sight until you double-click or ⌥-click the chevron", emptyHint: "No always-hidden icons — drop icons here to hide them"),
    ]
}

// MARK: - FlowLayout

/// Xếp subviews thành nhiều hàng, tự xuống dòng khi hết chỗ.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal: proposal, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(proposal: proposal, subviews: subviews) {
            for (position, index) in row.indices.enumerated() {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + row.x[position], y: bounds.minY + row.y),
                    proposal: ProposedViewSize(size)
                )
            }
        }
    }

    private struct Row {
        var x = [CGFloat]()
        var indices = [Int]()
        var y: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows = [Row]()
        var current = Row()
        var x: CGFloat = 0
        var y: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, x + size.width > maxWidth {
                rows.append(current)
                y += current.height + spacing
                current = Row()
                x = 0
            }
            current.x.append(x)
            current.indices.append(index)
            current.height = max(current.height, size.height)
            current.y = y
            x += size.width + spacing
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

// MARK: - Subtitle

private extension MenuBarItem {
    var subtitle: String {
        if let bundleID = owningApplication?.bundleIdentifier {
            bundleID
        } else if let ownerName {
            ownerName
        } else {
            title ?? ""
        }
    }
}

private extension MenuBarItemAXDiscovery.AXMenuBarItem {
    var subtitle: String? {
        if let identifier, identifier != displayName {
            identifier
        } else {
            bundleID
        }
    }
}
