//
//  IceBar.swift
//  Ice
//

import Combine
import SwiftUI

// MARK: - IceBarPanel

final class IceBarPanel: NSPanel {
    private weak var appState: AppState?

    private(set) var currentSection: MenuBarSection.Name?

    private lazy var colorManager = IceBarColorManager(iceBarPanel: self)

    private var cancellables = Set<AnyCancellable>()

    init(appState: AppState) {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        self.appState = appState
        self.title = "Ice Bar"
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.allowsToolTipsWhenApplicationIsInactive = true
        self.isFloatingPanel = true
        self.animationBehavior = .none
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .mainMenu + 1
        self.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace]
    }

    func performSetup() {
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        // Close the panel when the active space changes, or when the screen parameters change.
        Publishers.Merge(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
        )
        .sink { [weak self] _ in
            self?.close()
        }
        .store(in: &c)

        if
            let section = appState?.menuBarManager.section(withName: .hidden),
            let window = section.controlItem.window
        {
            window.publisher(for: \.frame)
                .debounce(for: 0.1, scheduler: DispatchQueue.main)
                .sink { [weak self, weak window] _ in
                    guard
                        let self,
                        let appState,
                        // Only continue if the menu bar is automatically hidden, as Ice
                        // can't currently display its menu bar items.
                        appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults,
                        // windowNumber is Int and traps on overflow with the non-failable
                        // initializer on macOS 26 (see jordanbaird/Ice#580, #977).
                        // Degrade to nil instead of crashing; call sites handle nil.
                        let info = window.map(\.windowNumber).flatMap(CGWindowID.init(exactly:)).flatMap(WindowInfo.init(windowID:)),
                        // Window being offscreen means the menu bar is currently hidden.
                        // Close the bar, as things will start to look weird if we don't.
                        !info.isOnScreen
                    else {
                        return
                    }
                    close()
                }
                .store(in: &c)
        }

        // Update the panel's origin whenever its size changes.
        publisher(for: \.frame)
            .map(\.size)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard
                    let self,
                    let screen
                else {
                    return
                }
                updateOrigin(for: screen)
            }
            .store(in: &c)

        cancellables = c
    }

    private func updateOrigin(for screen: NSScreen) {
        guard let appState else {
            return
        }

        func getOrigin(for iceBarLocation: IceBarLocation) -> CGPoint {
            let menuBarHeight = screen.getMenuBarHeight() ?? 0
            let originY = ((screen.frame.maxY - 1) - menuBarHeight) - frame.height

            var originForRightOfScreen: CGPoint {
                CGPoint(x: screen.frame.maxX - frame.width, y: originY)
            }

            switch iceBarLocation {
            case .dynamic:
                if appState.eventManager.isMouseInsideEmptyMenuBarSpace {
                    return getOrigin(for: .mousePointer)
                }
                return getOrigin(for: .iceIcon)
            case .mousePointer:
                guard let location = MouseCursor.locationAppKit else {
                    return getOrigin(for: .iceIcon)
                }

                let lowerBound = screen.frame.minX
                let upperBound = screen.frame.maxX - frame.width

                guard lowerBound <= upperBound else {
                    return originForRightOfScreen
                }

                return CGPoint(x: (location.x - frame.width / 2).clamped(to: lowerBound...upperBound), y: originY)
            case .iceIcon:
                let lowerBound = screen.frame.minX
                let upperBound = screen.frame.maxX - frame.width

                guard
                    lowerBound <= upperBound,
                    let section = appState.menuBarManager.section(withName: .visible),
                    let windowID = section.controlItem.windowID,
                    // Bridging.getWindowFrame is more reliable than ControlItem.windowFrame,
                    // i.e. if the control item is offscreen.
                    let itemFrame = Bridging.getWindowFrame(for: windowID)
                else {
                    return originForRightOfScreen
                }

                return CGPoint(x: (itemFrame.midX - frame.width / 2).clamped(to: lowerBound...upperBound), y: originY)
            }
        }

        setFrameOrigin(getOrigin(for: appState.settingsManager.generalSettingsManager.iceBarLocation))
    }

    func show(section: MenuBarSection.Name, on screen: NSScreen) async {
        guard let appState else {
            return
        }

        // Important that we set the navigation state and current section before updating the cache.
        appState.navigationState.isIceBarPresented = true
        currentSection = section

        await appState.itemManager.cacheItemsIfNeeded()

        if ScreenCapture.cachedCheckPermissions() {
            await appState.imageCache.updateCache()
        }

        // Một show() mới hơn có thể đã chiếm panel trong lúc chờ cache —
        // bỏ qua, không close (panel giờ thuộc về show đó).
        guard currentSection == section else {
            return
        }

        contentView = IceBarHostingView(appState: appState, colorManager: colorManager, screen: screen, section: section) { [weak self] in
            self?.close()
        }

        updateOrigin(for: screen)

        // Color manager must be updated after updating the panel's origin, but before it is shown.
        //
        // Color manager handles frame changes automatically, but does so on the main queue, so we
        // need to update manually once before showing the panel to prevent the color from flashing.
        colorManager.updateAllProperties(with: frame, screen: screen)

        orderFrontRegardless()
    }

    override func close() {
        super.close()
        contentView = nil
        currentSection = nil
        appState?.navigationState.isIceBarPresented = false
    }
}

// MARK: - IceBarHostingView

private final class IceBarHostingView: NSHostingView<AnyView> {
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets()
    }

    init(
        appState: AppState,
        colorManager: IceBarColorManager,
        screen: NSScreen,
        section: MenuBarSection.Name,
        closePanel: @escaping () -> Void
    ) {
        super.init(
            rootView: IceBarContentView(screen: screen, section: section, closePanel: closePanel)
                .environmentObject(appState)
                .environmentObject(appState.imageCache)
                .environmentObject(appState.itemManager)
                .environmentObject(appState.menuBarManager)
                .environmentObject(colorManager)
                .erasedToAnyView()
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @available(*, unavailable)
    required init(rootView: AnyView) {
        fatalError("init(rootView:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

// MARK: - SplitPillShape

/// Stadium pill mirroring the split-shape trailing pill geometry in
/// `shapePath` (rect body + oval/square end caps), so the Ice Bar clips and
/// borders exactly like the menu bar pill.
private struct SplitPillShape: InsettableShape {
    var leadingEndCap: MenuBarEndCap
    var trailingEndCap: MenuBarEndCap
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        var path = Path()
        guard r.height > 0, r.width > 0 else {
            return path
        }
        path.addRect(CGRect(x: r.minX + r.height / 2, y: r.minY, width: max(0, r.width - r.height), height: r.height))
        switch leadingEndCap {
        case .square:
            path.addRect(CGRect(origin: r.origin, size: CGSize(width: r.height, height: r.height)))
        case .round:
            path.addEllipse(in: CGRect(origin: r.origin, size: CGSize(width: r.height, height: r.height)))
        }
        switch trailingEndCap {
        case .square:
            path.addRect(CGRect(x: r.maxX - r.height, y: r.minY, width: r.height, height: r.height))
        case .round:
            path.addEllipse(in: CGRect(x: r.maxX - r.height, y: r.minY, width: r.height, height: r.height))
        }
        return path
    }

    func inset(by amount: CGFloat) -> SplitPillShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

// MARK: - IceBarContentView

private struct IceBarContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var colorManager: IceBarColorManager
    @EnvironmentObject var itemManager: MenuBarItemManager
    @EnvironmentObject var imageCache: MenuBarItemImageCache
    @EnvironmentObject var menuBarManager: MenuBarManager
    @State private var frame = CGRect.zero
    @State private var scrollIndicatorsFlashTrigger = 0
    @State private var axRows = [AXRowItem]()
    @State private var hasAXPermission = MenuBarItemAXDiscovery.isTrusted()
    @State private var isLoadingAXRows = false

    let screen: NSScreen
    let section: MenuBarSection.Name
    let closePanel: () -> Void

    private var items: [MenuBarItem] {
        itemManager.itemCache.managedItems(for: section)
    }

    private var configuration: MenuBarAppearanceConfigurationV2 {
        appState.appearanceManager.configuration
    }

    private var horizontalPadding: CGFloat {
        configuration.hasRoundedShape ? 7 : 5
    }

    private var verticalPadding: CGFloat {
        screen.hasNotch ? 0 : 2
    }

    private var contentHeight: CGFloat? {
        guard let menuBarHeight = imageCache.menuBarHeight ?? screen.getMenuBarHeight() else {
            return nil
        }
        if configuration.shapeKind != .none && configuration.isInset && screen.hasNotch {
            return menuBarHeight - appState.appearanceManager.menuBarInsetAmount * 2
        }
        return menuBarHeight
    }

    private var clipShape: AnyInsettableShape {
        barShape
    }

    /// Whether the bar mirrors the split-shape trailing pill (same end caps,
    /// tint opacity, inside border and shadow).
    private var isSplitPill: Bool {
        configuration.shapeKind == .split
    }

    private var barShape: AnyInsettableShape {
        // Cùng hình stadium với pill trailing của split: thân chữ nhật
        // cộng 2 đầu oval/chữ nhật theo end caps (mirror `shapePath`).
        let trailing = configuration.splitShapeInfo.trailing
        if isSplitPill {
            return AnyInsettableShape(
                SplitPillShape(
                    leadingEndCap: trailing.leadingEndCap,
                    trailingEndCap: trailing.trailingEndCap
                )
            )
        } else if configuration.hasRoundedShape {
            return AnyInsettableShape(Capsule())
        } else {
            return AnyInsettableShape(RoundedRectangle(cornerRadius: frame.height / 5, style: .continuous))
        }
    }

    /// Tint opacity của bar: khớp split, còn lại giữ 0.2 cũ.
    private var barTintOpacity: Double {
        isSplitPill ? configuration.current.tintOpacity : 0.2
    }

    @ViewBuilder
    private var splitBorderOverlay: some View {
        // Mirror MenuBarTintView HACK: stroke gấp đôi rồi cắt nửa ngoài đi
        // bằng clipShape ngay sau đó → viền nằm gọn bên trong pill.
        if isSplitPill, configuration.current.hasBorder {
            barShape.stroke(
                Color(cgColor: configuration.current.borderColor),
                lineWidth: CGFloat(configuration.current.borderWidth) * 2
            )
        }
    }

    private var barShadowColor: Color {
        if isSplitPill {
            configuration.current.hasShadow ? .black.opacity(0.5) : .clear
        } else {
            .black.opacity(shadowOpacity)
        }
    }

    private var barShadowRadius: CGFloat {
        isSplitPill ? 5 : 2.5
    }

    private var shadowOpacity: CGFloat {
        configuration.current.hasShadow ? 0.5 : 0.33
    }

    var body: some View {
        ZStack {
            content
                .frame(height: contentHeight)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .layoutBarStyle(appState: appState, averageColorInfo: colorManager.colorInfo, tintOpacity: barTintOpacity, useLiveBlur: isSplitPill)
                .foregroundStyle(colorManager.colorInfo?.color.brightness ?? 0 > 0.67 ? .black : .white)
                .overlay(splitBorderOverlay)
                .clipShape(clipShape)
                .shadow(color: barShadowColor, radius: barShadowRadius)

            if configuration.current.hasBorder, !isSplitPill {
                clipShape
                    .inset(by: configuration.current.borderWidth / 2)
                    .stroke(lineWidth: configuration.current.borderWidth)
                    .foregroundStyle(Color(cgColor: configuration.current.borderColor))
            }
        }
        .padding(5)
        .frame(maxWidth: imageCache.screen?.frame.width)
        .fixedSize()
        .onFrameChange(update: $frame)
    }

    @ViewBuilder
    private var content: some View {
        if itemManager.isItemDiscoveryUnavailable {
            // macOS 27+: CGS không còn per-item windows — hiện icon app và
            // nhấn qua Accessibility thay vì ảnh chụp window + temp-show.
            axFallbackView
                .task {
                    await loadAXRows()
                }
        } else if !ScreenCapture.cachedCheckPermissions() {
            HStack {
                Text("The Ice Bar requires screen recording permissions.")

                Button {
                    closePanel()
                    appState.navigationState.settingsNavigationIdentifier = .advanced
                    appState.appDelegate?.openSettingsWindow()
                } label: {
                    Text("Open Ice Settings")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.link)
            }
            .padding(.horizontal, 10)
        } else if menuBarManager.isMenuBarHiddenBySystemUserDefaults {
            Text("Ice cannot display menu bar items for automatically hidden menu bars")
                .padding(.horizontal, 10)
        } else if imageCache.cacheFailed(for: section) {
            Text("Unable to display menu bar items")
                .padding(.horizontal, 10)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(items, id: \.windowID) { item in
                        IceBarItemView(item: item, closePanel: closePanel)
                    }
                }
            }
            .environment(\.isScrollEnabled, frame.width == imageCache.screen?.frame.width)
            .defaultScrollAnchor(.trailing)
            .scrollIndicatorsFlash(trigger: scrollIndicatorsFlashTrigger)
            .task {
                scrollIndicatorsFlashTrigger += 1
            }
        }
    }

    // MARK: - AX fallback (macOS 27+)

    /// Hàng icon cho Ice Bar khi CGS không còn per-item windows.
    private struct AXRowItem: Identifiable {
        /// ID ổn định giữa các lần quét (không phải UUID ngẫu nhiên) để
        /// SwiftUI diff mượt.
        let id: String
        let pid: pid_t
        let identifier: String?
        let title: String?
        let displayName: String
        let systemImage: String?
        let appIcon: NSImage?
        /// Tâm X (tọa độ AX) để lọc visible, nil khi không đọc được frame.
        let midX: CGFloat?
    }

    private static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    @ViewBuilder
    private var axFallbackView: some View {
        if !hasAXPermission {
            HStack {
                Text("The Ice Bar requires accessibility permission.")

                Button {
                    NSWorkspace.shared.open(Self.accessibilitySettingsURL)
                } label: {
                    Text("Open System Settings")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.link)

                Button {
                    hasAXPermission = MenuBarItemAXDiscovery.isTrusted()
                    if hasAXPermission {
                        Task {
                            await loadAXRows()
                        }
                    }
                } label: {
                    Text("Check Again")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.link)
            }
            .padding(.horizontal, 10)
        } else if isLoadingAXRows && axRows.isEmpty {
            ProgressView()
                .padding(.horizontal, 10)
        } else if axRows.isEmpty {
            Text("Unable to display menu bar items")
                .padding(.horizontal, 10)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(axRows) { row in
                        axRowView(row)
                    }
                }
            }
            .defaultScrollAnchor(.trailing)
            .scrollIndicatorsFlash(trigger: scrollIndicatorsFlashTrigger)
            .task {
                scrollIndicatorsFlashTrigger += 1
            }
        }
    }

    @ViewBuilder
    private func axRowView(_ row: AXRowItem) -> some View {
        Button {
            press(row)
        } label: {
            if let systemName = row.systemImage {
                Image(systemName: systemName)
                    .font(.system(size: 16))
                    .frame(minWidth: 28, minHeight: 22)
            } else if let icon = row.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 22)
            } else if let title = row.title, !title.isEmpty {
                Text(title)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
            } else {
                Text(row.displayName)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(row.displayName)
        .accessibilityLabel(row.displayName)
        .accessibilityAction(named: "press") {
            press(row)
        }
    }

    /// Quét AX cho section đang mở, lọc bằng cùng cách phân loại theo vạch
    /// chia như Menu Bar Layout. Vạch chưa kịp layout (nil hết) thì hiện tất
    /// cả thay vì trả về bar rỗng.
    ///
    /// Quét tối đa 3 lần, cách nhau ~0.8s: trên macOS 27 layout menubar cần
    /// thời gian để vạch chia ổn định sau khi show section; lần quét đầu có
    /// thể gặp frame rác của spacer đang park.
    private func loadAXRows() async {
        guard !isLoadingAXRows else {
            return
        }
        isLoadingAXRows = true
        defer {
            isLoadingAXRows = false
        }

        hasAXPermission = MenuBarItemAXDiscovery.isTrusted()
        guard hasAXPermission else {
            return
        }

        for attempt in 0..<3 {
            await scanAXRowsOnce(attempt: attempt)
            if !axRows.isEmpty || Task.isCancelled {
                return
            }
            try? await Task.sleep(for: .milliseconds(800))
        }
    }

    /// Một lần quét AX: liệt kê items, lọc theo section, dựng rows.
    private func scanAXRowsOnce(attempt: Int) async {
        // NSWorkspace phải đọc trên main; discovery nặng chạy nền. Vị trí vạch
        // chia cũng tra nền qua AX (cùng hệ tọa độ với axFrame).
        let apps = NSWorkspace.shared.runningApplications
        let wantedSection = section

        let (found, axDividers) = await Task.detached(priority: .userInitiated) {
            (
                MenuBarItemAXDiscovery.discoverItems(in: apps),
                MenuBarItemAXDiscovery.dividerFrames()
            )
        }.value

        // Vạch chia ưu tiên qua AX, nhưng LOẠI frame rác của spacer đang park
        // (rộng hàng trăm pt dưới đáy màn hình) — minX của nó (vd 7.0) mà lọt
        // vào phân loại thì mọi item dạt hết về Visible và bar rỗng.
        // button.window.frame trên macOS 27 cũng trả về rect spacer (minX = 0)
        // nên chỉ dùng làm fallback khi AX thiếu và giá trị hợp lệ (minX > 0).
        func settledMinX(_ frame: CGRect?) -> CGFloat? {
            frame.flatMap { MenuBarItemAXDiscovery.isSettledDividerFrame($0) ? $0.minX : nil }
        }
        func saneMinX(_ value: CGFloat?) -> CGFloat? {
            value.flatMap { $0 > 0 ? $0 : nil }
        }
        let hiddenX = settledMinX(axDividers.hidden)
            ?? saneMinX(menuBarManager.section(withName: .hidden)?.controlItem.window?.frame.minX)
        let alwaysHiddenX = settledMinX(axDividers.alwaysHidden)
            ?? saneMinX(menuBarManager.section(withName: .alwaysHidden)?.controlItem.window?.frame.minX)

        func kind(centerX: CGFloat?) -> MenuBarItemAXDiscovery.SectionKind {
            MenuBarItemAXDiscovery.classify(centerX: centerX, hiddenDividerX: hiddenX, alwaysHiddenDividerX: alwaysHiddenX)
        }
        let dividersMissing = hiddenX == nil && alwaysHiddenX == nil

        // ID ổn định giữa các lần quét để SwiftUI không vẽ lại cả danh sách.
        var idCounts = [String: Int]()
        func stableID(for base: String) -> String {
            let n = idCounts[base, default: 0]
            idCounts[base] = n + 1
            return n == 0 ? base : "\(base)#\(n)"
        }

        // Discovery trả về theo tên; xếp lại trái→phải như trên menubar.
        let ordered = found.sorted {
            ($0.axFrame?.midX ?? .greatestFiniteMagnitude) < ($1.axFrame?.midX ?? .greatestFiniteMagnitude)
        }
        var icons = [pid_t: NSImage]()
        var rows = [AXRowItem]()
        for item in ordered {
            // Bar hiện gộp hidden + alwaysHidden (loại visible): vạch chia
            // lúc spacer nở không đủ tin để tách 2 section, và ý người dùng
            // là một bar duy nhất cho mọi app bị ẩn.
            if !dividersMissing, kind(centerX: item.axFrame?.midX) == .visible {
                continue
            }
            // Cùng cách chọn icon như Menu Bar Layout: system extras quen thuộc
            // dùng SF Symbol (icon theo PID sẽ ra icon chung của MenuBarAgent).
            let systemImage = MenuBarItemAXDiscovery.systemImageName(forIdentifier: item.identifier)
            if systemImage == nil, icons[item.pid] == nil {
                if item.bundleID == "com.apple.TextInputMenuAgent" {
                    icons[item.pid] = MenuBarItemAXDiscovery.inputSourceIcon()
                } else {
                    icons[item.pid] = NSRunningApplication(processIdentifier: item.pid)?.icon
                }
            }
            rows.append(
                AXRowItem(
                    id: stableID(for: "ax:\(item.pid):\(item.bundleID ?? ""):\(item.identifier ?? ""):\(item.title ?? "")"),
                    pid: item.pid,
                    identifier: item.identifier,
                    title: item.title,
                    displayName: item.displayName,
                    systemImage: systemImage,
                    appIcon: icons[item.pid],
                    midX: item.axFrame?.midX
                )
            )
        }
        // Spacer nở (vạch chia frame rác): loại items đã hiện sẵn trong vùng
        // pill trailing — user đang thấy chúng trên menubar. Chỉ lọc khi mất
        // cả hai vạch; vạch còn dùng được thì phân loại theo section như cũ.
        // Fullscreen bỏ qua (pill không vẽ, width cũ).
        if dividersMissing,
           !appState.isActiveSpaceFullscreen,
           let trailingWidth = MenuBarOverlayPanelContentView.currentTrailingVisibleWidth(for: screen.displayID),
           trailingWidth > 0, trailingWidth < screen.frame.width
        {
            let visibleMinX = screen.frame.maxX - trailingWidth
            rows.removeAll { ($0.midX ?? .greatestFiniteMagnitude) >= visibleMinX - 4 }
        }
        axRows = rows
        Logger.iceBar.debug("axScan done wanted=\(wantedSection) attempt=\(attempt) rows=\(rows.count)")
        // TEMP DEBUG: chẩn đoán bar thiếu app. Gỡ trước khi commit.
        Logger.iceBar.info("TEMP axScan wanted=\(wantedSection) found=\(found.count) hiddenX=\(hiddenX as Any) alwaysHiddenX=\(alwaysHiddenX as Any) dividersMissing=\(dividersMissing) rows=\(rows.count)")
        for item in found {
            Logger.iceBar.info("TEMP axItem kind=\(kind(centerX: item.axFrame?.midX)) frame=\(item.axFrame.debugDescription) name=\(item.displayName)")
        }
        for row in rows {
            Logger.iceBar.info("TEMP axRow name=\(row.displayName)")
        }
    }

    /// Đóng bar trước rồi nhấn item qua AX (mirror CGS path: close → đợi 25ms
    /// → click). Chạy nền vì mỗi app có thể block tới ~1s.
    private func press(_ row: AXRowItem) {
        closePanel()
        Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: .milliseconds(25))
            _ = MenuBarItemAXDiscovery.press(pid: row.pid, identifier: row.identifier, title: row.title)
        }
    }
}

// MARK: - IceBarItemView

private struct IceBarItemView: View {
    @EnvironmentObject var imageCache: MenuBarItemImageCache
    @EnvironmentObject var itemManager: MenuBarItemManager

    let item: MenuBarItem
    let closePanel: () -> Void

    private var leftClickAction: () -> Void {
        return { [weak itemManager] in
            guard let itemManager else {
                return
            }
            closePanel()
            Task {
                try? await Task.sleep(for: .milliseconds(25))
                itemManager.tempShowItem(item, clickWhenFinished: true, mouseButton: .left)
            }
        }
    }

    private var rightClickAction: () -> Void {
        return { [weak itemManager] in
            guard let itemManager else {
                return
            }
            closePanel()
            Task {
                try? await Task.sleep(for: .milliseconds(25))
                itemManager.tempShowItem(item, clickWhenFinished: true, mouseButton: .right)
            }
        }
    }

    private var image: NSImage? {
        guard
            let image = imageCache.images[item.info],
            let screen = imageCache.screen
        else {
            return nil
        }
        let size = CGSize(
            width: CGFloat(image.width) / screen.backingScaleFactor,
            height: CGFloat(image.height) / screen.backingScaleFactor
        )
        return NSImage(cgImage: image, size: size)
    }

    var body: some View {
        if let image {
            Image(nsImage: image)
                .contentShape(Rectangle())
                .overlay {
                    IceBarItemClickView(item: item, leftClickAction: leftClickAction, rightClickAction: rightClickAction)
                }
                .accessibilityLabel(item.displayName)
                .accessibilityAction(named: "left click", leftClickAction)
                .accessibilityAction(named: "right click", rightClickAction)
        }
    }
}

// MARK: - IceBarItemClickView

private struct IceBarItemClickView: NSViewRepresentable {
    private final class Represented: NSView {
        let item: MenuBarItem

        let leftClickAction: () -> Void
        let rightClickAction: () -> Void

        private var lastLeftMouseDownDate = Date.now
        private var lastRightMouseDownDate = Date.now

        private var lastLeftMouseDownLocation = CGPoint.zero
        private var lastRightMouseDownLocation = CGPoint.zero

        init(item: MenuBarItem, leftClickAction: @escaping () -> Void, rightClickAction: @escaping () -> Void) {
            self.item = item
            self.leftClickAction = leftClickAction
            self.rightClickAction = rightClickAction
            super.init(frame: .zero)
            self.toolTip = item.displayName
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func absoluteDistance(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
            hypot(p1.x - p2.x, p1.y - p2.y).magnitude
        }

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            lastLeftMouseDownDate = .now
            lastLeftMouseDownLocation = NSEvent.mouseLocation
        }

        override func rightMouseDown(with event: NSEvent) {
            super.rightMouseDown(with: event)
            lastRightMouseDownDate = .now
            lastRightMouseDownLocation = NSEvent.mouseLocation
        }

        override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
            guard
                Date.now.timeIntervalSince(lastLeftMouseDownDate) < 0.5,
                absoluteDistance(lastLeftMouseDownLocation, NSEvent.mouseLocation) < 5
            else {
                return
            }
            leftClickAction()
        }

        override func rightMouseUp(with event: NSEvent) {
            super.rightMouseUp(with: event)
            guard
                Date.now.timeIntervalSince(lastRightMouseDownDate) < 0.5,
                absoluteDistance(lastRightMouseDownLocation, NSEvent.mouseLocation) < 5
            else {
                return
            }
            rightClickAction()
        }
    }

    let item: MenuBarItem

    let leftClickAction: () -> Void
    let rightClickAction: () -> Void

    func makeNSView(context: Context) -> NSView {
        Represented(item: item, leftClickAction: leftClickAction, rightClickAction: rightClickAction)
    }

    func updateNSView(_ nsView: NSView, context: Context) { }
}

// MARK: - Logger

private extension Logger {
    static let iceBar = Logger(category: "IceBar")
}
