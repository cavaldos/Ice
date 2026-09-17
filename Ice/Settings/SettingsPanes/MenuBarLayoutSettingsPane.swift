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
    /// Chặn Refresh chồng nhau: quét AX + CGS dồn lại là nguyên nhân giật.
    @State private var isRefreshing = false
    /// Chặn kéo-thả chồng nhau: hai cú Command-drag cùng lúc giành chuột.
    @State private var isMoving = false
    /// ID các icon đang được di chuyển nền: UI cập nhật lạc quan ngay, badge
    /// nhỏ trên từng icon cho biết đang đồng bộ, khỏi đơ cả danh sách.
    @State private var pendingMoves = Set<String>()
    /// Icon đang được hover khi kéo: viền xanh cho biết thả vào đây sẽ chèn
    /// vào trước nó. Đồng thời để section biết drop này đã có item nhận
    /// (tránh cả item lẫn section cùng xử lý một cú thả).
    @State private var dropTargetID: String?
    /// Quét nền đối chiếu vị trí thật, không hiện spinner chung.
    @State private var isReconciling = false

    private var totalCount: Int {
        sections.values.reduce(0) { $0 + $1.count }
    }

    /// Các nhóm được hiển thị: tắt "Enable always-hidden section" trong
    /// Advanced thì ẩn luôn nhóm Always Hidden ở đây.
    private var visibleMetas: [SectionMeta] {
        if appState.settingsManager.advancedSettingsManager.enableAlwaysHiddenSection {
            SectionMeta.all
        } else {
            SectionMeta.all.filter { $0.kind != .alwaysHidden }
        }
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
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(IceButtonStyle())
                .disabled(isRefreshing)
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
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(visibleMetas, id: \.kind) { meta in
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
            // Vẽ ngay từ cache có sẵn (timer 5s nền vẫn bơm itemCache),
            // rồi mới quét nền đối chiếu — mở tab là thấy icon, khỏi bấm Refresh.
            applySnapshotFromCache()
            await refresh()
        }
        .onReceive(appState.itemManager.$itemCache) { _ in
            // Cache đổi (timer nền, app mới mở, kéo-thả xong) thì UI theo luôn.
            // Đang kéo thì giữ UI lạc quan, đợi reconcile ghi đè.
            guard !isMoving else {
                return
            }
            applySnapshotFromCache()
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
                // Ô "New" nét đứt đầu nhóm Visible: chỗ icon mới xuất hiện,
                // giống ảnh mẫu (canh phải nên nó nằm trái nhất).
                if meta.kind == .visible {
                    newItemPlaceholder
                }
                if items.isEmpty {
                    Text(meta.emptyHint)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(items) { item in
                        itemView(item, pending: pendingMoves.contains(item.id), isDropTarget: dropTargetID == item.id)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onDrop(of: [.text], isTargeted: .constant(false), perform: { providers in
                // Đang hover trên một icon thì để item đó nhận (chèn theo vị
                // trí), section chỉ nhận khi thả vào khoảng trống (về cuối nhóm).
                guard dropTargetID == nil, !isMoving, let provider = providers.first else {
                    return false
                }
                _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                    guard let id = string as? String else {
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

    private func itemView(_ item: RowItem, pending: Bool, isDropTarget: Bool) -> some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let systemName = item.systemImage {
                        Image(systemName: systemName)
                            .font(.system(size: 17))
                            .frame(width: 40, height: 30)
                    } else if let icon = item.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 26, height: 26)
                            .frame(width: 40, height: 30)
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.quaternary)
                            .frame(width: 40, height: 30)
                    }
                }
                // Icon hệ thống (bundle com.apple.*) gắn thêm logo Apple
                // góc trên-phải để phân biệt như ảnh mẫu.
                if item.isSystem {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 14, height: 14)
                        .background(.regularMaterial, in: Circle())
                        .offset(x: 5, y: -5)
                }
            }
            Text(item.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 68)
        }
        .frame(width: 68)
        .help(pending ? "\(item.subtitle ?? item.title) — đang di chuyển…" : (item.subtitle ?? item.title))
        .opacity(pending ? 0.7 : 1)
        .overlay {
            // Viền xanh khi kéo hover lên: thả ra sẽ chèn vào trước icon này.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isDropTarget ? .blue : .clear, lineWidth: 2)
                .frame(width: 52, height: 56)
        }
        .overlay(alignment: .topTrailing) {
            if pending {
                ProgressView()
                    .controlSize(.mini)
                    .padding(4)
                    .background(.regularMaterial, in: Circle())
                    .offset(x: 6, y: -6)
            }
        }
        .onDrag {
            NSItemProvider(object: item.id as NSString)
        }
        .onDrop(
            of: [.text],
            isTargeted: dropTargetBinding(for: item.id),
            perform: { providers in
                guard !isMoving, let provider = providers.first else {
                    return false
                }
                _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                    guard let id = string as? String else {
                        return
                    }
                    Task { @MainActor in
                        await drop(itemID: id, onto: item.id)
                    }
                }
                return true
            }
        )
    }

    /// Binding hover cho một icon: kéo tới thì viền xanh, section nhường
    /// drop này cho item (chèn theo vị trí thay vì về cuối nhóm).
    private func dropTargetBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { dropTargetID == id },
            set: { targeted in
                if targeted {
                    dropTargetID = id
                } else if dropTargetID == id {
                    dropTargetID = nil
                }
            }
        )
    }

    /// Ô "New" nét đứt ở đầu nhóm Visible: vị trí icon mới xuất hiện.
    private var newItemPlaceholder: some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .frame(width: 40, height: 30)
                .overlay {
                    Image(systemName: "sparkle")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
            Text("New")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 68)
        }
        .frame(width: 68)
        .help("New menu bar items appear here")
    }

    /// Thả item vào nhóm mới theo kiểu eventual consistency: UI nhảy ngay
    /// (kèm badge "đang di chuyển" trên đúng icon đó), cú Command-drag và
    /// quét đối chiếu chạy nền; vị trí thật về sau sẽ tự khớp lên UI.
    /// Khung `isMoving` chặn cú kéo thứ hai giành chuột.
    private func drop(itemID: String, to kind: MenuBarItemAXDiscovery.SectionKind) async {
        guard !isMoving else {
            return
        }
        guard let (item, fromKind) = removeItem(id: itemID) else {
            return
        }
        guard fromKind != kind else {
            // Thả về đúng nhóm cũ thì trả lại chỗ cũ.
            sections[kind, default: []].append(item)
            return
        }
        guard
            let destination = destinationPoint(for: kind),
            let sourceFrame = item.quartzFrame
        else {
            // Không biết thả đâu → quét lại vị trí thật.
            await refresh()
            return
        }
        isMoving = true
        pendingMoves.insert(item.id)
        defer {
            pendingMoves.remove(item.id)
            isMoving = false
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            sections[kind, default: []].append(item)
        }
        await MenuBarItemAXMover.commandDrag(
            from: CGPoint(x: sourceFrame.midX, y: sourceFrame.midY),
            to: destination
        )
        // Đối chiếu nền: icon qua đúng nhóm thì xong, chưa thì đợi thêm
        // chút rồi quét lại (tối đa 3 lần). Quét lặng, không giật UI.
        for attempt in 0..<3 {
            await reconcile()
            if sections[kind]?.contains(where: { $0.id == item.id }) == true {
                return
            }
            if attempt < 2 {
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    /// Gỡ item khỏi nhóm hiện tại, trả về item và nhóm cũ.
    private func removeItem(id: String) -> (RowItem, MenuBarItemAXDiscovery.SectionKind)? {
        guard let found = findItem(id: id) else {
            return nil
        }
        var updated = sections[found.kind] ?? []
        updated.remove(at: found.index)
        sections[found.kind] = updated
        return (found.item, found.kind)
    }

    /// Tìm item theo ID ổn định, trả về item + nhóm + vị trí trong nhóm
    /// (nhóm đã xếp trái→phải như trên menubar).
    private func findItem(id: String) -> (item: RowItem, kind: MenuBarItemAXDiscovery.SectionKind, index: Int)? {
        for (kind, items) in sections {
            if let index = items.firstIndex(where: { $0.id == id }) {
                return (items[index], kind, index)
            }
        }
        return nil
    }

    /// Thả một icon lên một icon khác: chèn vào trước icon đích (cùng zone
    /// là sắp xếp lại thứ tự, khác zone là chuyển zone đúng vị trí).
    /// UI nhảy ngay, Command-drag chạy nền, quét đối chiếu khớp vị trí thật.
    private func drop(itemID: String, onto targetID: String) async {
        guard !isMoving else {
            return
        }
        guard itemID != targetID else {
            return
        }
        guard let (item, fromKind, fromIndex) = findItem(id: itemID) else {
            return
        }
        guard let target = findItem(id: targetID) else {
            await refresh()
            return
        }
        let toKind = target.kind
        guard let sourceFrame = item.quartzFrame else {
            await refresh()
            return
        }
        // Gỡ nguồn trước rồi tính vị trí chèn sau khi dồn (kéo xuôi thì
        // index đích lùi 1 vì mảng đã ngắn đi).
        var withoutSource = sections[fromKind] ?? []
        withoutSource.remove(at: fromIndex)
        sections[fromKind] = withoutSource
        let toItems = sections[toKind] ?? []
        let insertIndex: Int
        if fromKind == toKind, fromIndex < target.index {
            insertIndex = target.index - 1
        } else {
            insertIndex = toItems.firstIndex(where: { $0.id == targetID }) ?? toItems.count
        }
        let leftFrame = insertIndex > 0 ? toItems[max(0, insertIndex - 1)].quartzFrame : nil
        let rightFrame = insertIndex < toItems.count ? toItems[insertIndex].quartzFrame : nil

        isMoving = true
        pendingMoves.insert(item.id)
        defer {
            pendingMoves.remove(item.id)
            isMoving = false
            dropTargetID = nil
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            sections[toKind, default: []].insert(item, at: min(insertIndex, toItems.count))
        }
        guard let destination = reorderDestination(for: toKind, leftFrame: leftFrame, rightFrame: rightFrame) else {
            await refresh()
            return
        }
        await MenuBarItemAXMover.commandDrag(
            from: CGPoint(x: sourceFrame.midX, y: sourceFrame.midY),
            to: destination
        )
        if fromKind == toKind {
            // Cùng zone: phân loại không đổi nên chỉ cần quét lại cho order
            // thật đè lên order lạc quan (2 lần cách nhau để hệ thống commit).
            await reconcile()
            try? await Task.sleep(for: .milliseconds(400))
            await reconcile()
            return
        }
        // Khác zone: icon qua đúng nhóm thì xong, chưa thì đợi thêm chút
        // rồi quét lại (tối đa 3 lần). Quét lặng, không giật UI.
        for attempt in 0..<3 {
            await reconcile()
            if sections[toKind]?.contains(where: { $0.id == item.id }) == true {
                return
            }
            if attempt < 2 {
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    /// Điểm thả Command-drag để chèn vào khe giữa hai frame kề (tọa độ
    /// Quartz): giữa khe nếu có cả hai, lệch 12pt từ mép nếu ở đầu/cuối.
    /// Kẹp trong biên zone khi biết vạch chia để không rơi sang zone khác.
    private func reorderDestination(
        for kind: MenuBarItemAXDiscovery.SectionKind,
        leftFrame: CGRect?,
        rightFrame: CGRect?
    ) -> CGPoint? {
        let y = anchorY == 0 ? 8 : anchorY
        if let left = leftFrame, let right = rightFrame {
            if left.maxX < right.minX {
                return CGPoint(x: (left.maxX + right.minX) / 2, y: y)
            }
            return CGPoint(x: (left.midX + right.midX) / 2, y: y)
        }
        if let right = rightFrame {
            var x = right.minX - 12
            if let bound = leftBound(for: kind), x < bound + 6 {
                x = bound + 10
            }
            return CGPoint(x: x, y: y)
        }
        if let left = leftFrame {
            var x = left.maxX + 12
            if let bound = rightBound(for: kind), x > bound - 6 {
                x = bound - 10
            }
            return CGPoint(x: x, y: y)
        }
        return destinationPoint(for: kind)
    }

    /// Biên trái của zone (minX vạch chia bên trái), nil khi không rõ.
    private func leftBound(for kind: MenuBarItemAXDiscovery.SectionKind) -> CGFloat? {
        switch kind {
        case .visible:
            hiddenDividerX ?? alwaysHiddenDividerX
        case .hidden:
            alwaysHiddenDividerX
        case .alwaysHidden:
            nil
        }
    }

    /// Biên phải của zone (minX vạch chia bên phải), nil khi không rõ.
    private func rightBound(for kind: MenuBarItemAXDiscovery.SectionKind) -> CGFloat? {
        switch kind {
        case .visible:
            nil
        case .hidden:
            hiddenDividerX
        case .alwaysHidden:
            alwaysHiddenDividerX ?? hiddenDividerX
        }
    }

    /// Điểm thả Command-drag cho nhóm đích (tọa độ Quartz, origin top-left,
    /// cùng hệ với `CGEvent`): trong vùng của nhóm đó, cách vạch chia một
    /// đoạn để không rơi vào hitbox của vạch. Nhóm Hidden nằm giữa hai vạch
    /// nên thả vào điểm giữa cho chắc ăn.
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
            if let ahX = alwaysHiddenDividerX, ahX < x {
                return CGPoint(x: (ahX + x) / 2, y: anchorY)
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

    /// Quét thủ công từ nút Refresh: hiện spinner, chặn bấm chồng.
    private func refresh() async {
        // Chặn quét chồng nhau khi bấm Refresh liên tục.
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
        }
        await scanAndApply()
    }

    /// Đối chiếu nền sau cú kéo: cùng một lần quét nhưng lặng lẽ, không
    /// spinner, không khóa nút — UI cứ mượt, vị trí thật về sau tự khớp.
    private func reconcile() async {
        guard !isReconciling else {
            return
        }
        isReconciling = true
        defer {
            isReconciling = false
        }
        await scanAndApply()
    }

    /// Vạch chia đọc nhanh, đồng bộ: ưu tiên AX (process của chính mình,
    /// không đi bộ cả hệ thống), fallback window.frame khi AX chưa có.
    /// Cùng cách Ice Bar dùng để không bị frame rác của spacer park offscreen.
    private func resolveDividers() -> (hiddenX: CGFloat?, alwaysHiddenX: CGFloat?) {
        let axDividers = MenuBarItemAXDiscovery.dividerFrames()
        func settledMinX(_ frame: CGRect?) -> CGFloat? {
            frame.flatMap { MenuBarItemAXDiscovery.isSettledDividerFrame($0) ? $0.minX : nil }
        }
        func saneMinX(_ value: CGFloat?) -> CGFloat? {
            value.flatMap { $0 > 0 ? $0 : nil }
        }
        let manager = appState.menuBarManager
        let hiddenX = settledMinX(axDividers.hidden)
            ?? saneMinX(manager.section(withName: .hidden)?.controlItem.window?.frame.minX)
        let alwaysHiddenX = settledMinX(axDividers.alwaysHidden)
            ?? saneMinX(manager.section(withName: .alwaysHidden)?.controlItem.window?.frame.minX)
        return (hiddenX, alwaysHiddenX)
    }

    /// Dựng sections từ cache CGS có sẵn + vạch chia hiện tại, không quét.
    /// Gọi đồng bộ khi mở tab và khi $itemCache đổi để UI hiện ngay.
    private func applySnapshotFromCache() {
        hasAccessibilityPermission = MenuBarItemAXDiscovery.isTrusted()
        let (hiddenX, alwaysHiddenX) = resolveDividers()
        hiddenDividerX = hiddenX
        alwaysHiddenDividerX = alwaysHiddenX
        let (grouped, midQuartzY) = buildSections(
            hiddenX: hiddenX,
            alwaysHiddenX: alwaysHiddenX,
            axFallback: []
        )
        // Cache còn trống (máy mới boot, timer chưa bơm) thì giữ sections cũ
        // để khỏi nháy về màn hình chờ; lần quét nền sẽ điền sau.
        if !grouped.isEmpty {
            sections = grouped
        }
        if let midQuartzY {
            anchorY = midQuartzY
        } else if anchorY == 0 {
            anchorY = 8
        }
    }

    /// Dựng nhóm icon từ cache CGS theo đúng thứ tự menubar (trái→phải theo
    /// tâm X). Trả về nhóm + tung độ giữa để làm điểm thả Command-drag.
    private func buildSections(
        hiddenX: CGFloat?,
        alwaysHiddenX: CGFloat?,
        axFallback: [MenuBarItemAXDiscovery.AXMenuBarItem]
    ) -> (grouped: [MenuBarItemAXDiscovery.SectionKind: [RowItem]], midQuartzY: CGFloat?) {
        func kind(centerX: CGFloat?) -> MenuBarItemAXDiscovery.SectionKind {
            MenuBarItemAXDiscovery.classify(centerX: centerX, hiddenDividerX: hiddenX, alwaysHiddenDividerX: alwaysHiddenX)
        }
        var idCounts = [String: Int]()
        func stableID(for base: String) -> String {
            let n = idCounts[base, default: 0]
            idCounts[base] = n + 1
            return n == 0 ? base : "\(base)#\(n)"
        }
        let ownBundleID = Bundle.main.bundleIdentifier
        var grouped = [MenuBarItemAXDiscovery.SectionKind: [RowItem]]()
        var quartzYs = [CGFloat]()
        // CGS và AX cùng xếp theo tâm X tăng dần = trái→phải trên menubar,
        // khớp thứ tự Clock nằm phải nhất như ngoài thật.
        let cached = appState.itemManager.itemCache.allItems
            .filter { $0.owningApplication?.bundleIdentifier != ownBundleID }
            .sorted { $0.frame.midX < $1.frame.midX }
        if !cached.isEmpty {
            for item in cached {
                quartzYs.append(item.frame.midY)
                let bundleID = item.owningApplication?.bundleIdentifier
                grouped[kind(centerX: item.frame.midX), default: []].append(
                    RowItem(
                        id: stableID(for: "cgs:\(item.info):\(item.ownerPID)"),
                        title: item.displayName,
                        subtitle: item.subtitle,
                        systemImage: nil,
                        appIcon: item.owningApplication?.icon,
                        isSystem: bundleID?.hasPrefix("com.apple.") == true,
                        quartzFrame: item.frame
                    )
                )
            }
        } else {
            var icons = [pid_t: NSImage]()
            for item in axFallback.sorted(by: { ($0.axFrame?.midX ?? .greatestFiniteMagnitude) < ($1.axFrame?.midX ?? .greatestFiniteMagnitude) }) {
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
                if let frame = item.axFrame {
                    quartzYs.append(frame.midY)
                }
                grouped[kind(centerX: item.axFrame?.midX), default: []].append(
                    RowItem(
                        id: stableID(for: "ax:\(item.pid):\(item.bundleID ?? ""):\(item.identifier ?? ""):\(item.title ?? "")"),
                        title: item.displayName,
                        subtitle: item.subtitle,
                        systemImage: systemImage,
                        appIcon: appIcon,
                        isSystem: item.bundleID?.hasPrefix("com.apple.") == true,
                        quartzFrame: item.axFrame
                    )
                )
            }
        }
        let midY: CGFloat? = quartzYs.isEmpty ? nil : quartzYs.sorted()[quartzYs.count / 2]
        return (grouped, midY)
    }

    /// Một lần quét thật: đọc quyền, cache CGS, phân loại theo vạch chia.
    private func scanAndApply() async {
        // Đã có quyền thì dùng cache, khỏi bắt WindowServer đi bộ lại
        // danh sách window mỗi lần Refresh.
        if !hasScreenRecordingPermission {
            hasScreenRecordingPermission = ScreenCapture.cachedCheckPermissions(reset: true)
        }
        hasAccessibilityPermission = MenuBarItemAXDiscovery.isTrusted()
        // Vẽ tạm từ cache cũ trước để không trắng màn hình trong lúc đợi.
        applySnapshotFromCache()
        if hasScreenRecordingPermission {
            await appState.itemManager.cacheItemsIfNeeded()
        }

        let manager = appState.menuBarManager
        // Vạch chia lúc mới mở máy chưa có window ngay → minX nil → mọi icon
        // bị xếp nhầm vào Visible. Ưu tiên AX nhanh, chỉ đợi tối đa ~2s khi
        // cả hai vạch đều mất thay vì bắt người dùng bấm Refresh nhiều lần.
        var (hiddenX, alwaysHiddenX) = resolveDividers()
        if hiddenX == nil, alwaysHiddenX == nil {
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                (hiddenX, alwaysHiddenX) = resolveDividers()
                if hiddenX != nil || alwaysHiddenX != nil {
                    break
                }
            }
        }
        hiddenDividerX = hiddenX
        alwaysHiddenDividerX = alwaysHiddenX

        var axFallback = [MenuBarItemAXDiscovery.AXMenuBarItem]()
        if appState.itemManager.itemCache.allItems.isEmpty, hasAccessibilityPermission {
            let apps = NSWorkspace.shared.runningApplications
            axFallback = await Task.detached(priority: .userInitiated) {
                MenuBarItemAXDiscovery.discoverItems(in: apps)
            }.value
        }
        let (grouped, midY) = buildSections(hiddenX: hiddenX, alwaysHiddenX: alwaysHiddenX, axFallback: axFallback)
        if !grouped.isEmpty {
            sections = grouped
        }
        if let midY {
            anchorY = midY
        } else if anchorY == 0 {
            anchorY = 8
        }

        // Vạch đã hiện trong Settings (isAddedToMenuBar) mà window vẫn chưa
        // kịp có thì hẹn quét lại một lần, khỏi bắt người dùng bấm tay.
        if
            hiddenX == nil, alwaysHiddenX == nil,
            !grouped.isEmpty,
            manager.section(withName: .hidden)?.controlItem.isAddedToMenuBar == true
                || manager.section(withName: .alwaysHidden)?.controlItem.isAddedToMenuBar == true
        {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if hiddenDividerX == nil, alwaysHiddenDividerX == nil {
                    await reconcile()
                }
            }
        }
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
    /// ID ổn định theo item thật (không phải UUID ngẫu nhiên mỗi lần quét)
    /// để SwiftUI diff mượt và kiểm chứng được sau khi kéo-thả.
    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String?
    let appIcon: NSImage?
    /// true khi bundle com.apple.*: gắn badge  logo Apple như ảnh mẫu.
    let isSystem: Bool
    /// Frame theo tọa độ Quartz (origin top-left, cùng hệ `CGEvent`),
    /// dùng làm điểm bắt đầu khi Command-drag.
    let quartzFrame: CGRect?
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
/// Canh phải từng hàng để giống menubar thật (icon dồn về mép phải).
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
                    at: CGPoint(x: bounds.minX + row.x[position] + row.trailingOffset, y: bounds.minY + row.y),
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
        /// Độ dời để dồn hàng về mép phải (= khoảng trống còn lại).
        var trailingOffset: CGFloat = 0
        var width: CGFloat = 0
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows = [Row]()
        var current = Row()
        var x: CGFloat = 0
        var y: CGFloat = 0
        func finishRow() {
            // Hàng chưa full thì đẩy hết về phải cho giống menubar.
            if maxWidth.isFinite {
                current.trailingOffset = max(0, maxWidth - current.width)
            }
            rows.append(current)
            y += current.height + spacing
            current = Row()
            x = 0
        }
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, x + size.width > maxWidth {
                finishRow()
            }
            current.x.append(x)
            current.indices.append(index)
            current.height = max(current.height, size.height)
            current.y = y
            x += size.width + spacing
            current.width = x - spacing
        }
        if !current.indices.isEmpty {
            finishRow()
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
