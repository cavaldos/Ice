//
//  IceBar.swift
//  Ice
//

import Combine
import SwiftUI

// MARK: - IceBarPanel

/// A 1×1 anchor panel just below the menu bar that presents the Ice Bar as a
/// dropdown popover (same technique as the menu bar appearance editor).
///
/// The popover lists the Hidden and Always-Hidden sections together; the menu
/// bar itself never expands while it is open.
final class IceBarPanel: NSPanel {
    private weak var appState: AppState?

    private(set) var currentSection: MenuBarSection.Name?

    private var popover: NSPopover?

    private var cancellables = Set<AnyCancellable>()

    private var axActivationTask: Task<Void, Never>?

    /// Clicks in other apps dismiss the dropdown. Our own status items are local
    /// events, so clicking the Ice icon still toggles instead of close-then-reopen.
    private lazy var mouseDownMonitor = GlobalEventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
        self?.close()
    }

    /// Automatic rehide must not collapse originals while their menu is in use.
    private(set) var isActivatingAXItem = false

    init(appState: AppState) {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        self.appState = appState
        self.title = "Ice Bar"
        self.isFloatingPanel = true
        self.animationBehavior = .none
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.level = .mainMenu + 1
        self.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace]
    }

    func performSetup() {
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        // Close the dropdown when the active space changes, or when the screen parameters change.
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
                        // Close the dropdown, as things will start to look weird if we don't.
                        !info.isOnScreen
                    else {
                        return
                    }
                    close()
                }
                .store(in: &c)
        }

        cancellables = c
    }

    /// The point the popover arrow should touch: the bottom edge of the menu
    /// bar, horizontally placed according to the Ice Bar location setting.
    private func anchorPoint(for screen: NSScreen) -> CGPoint {
        let menuBarHeight = screen.getMenuBarHeight() ?? 0
        let y = screen.frame.maxY - menuBarHeight - frame.height
        let bounds = screen.frame.minX...(screen.frame.maxX - frame.width)

        func x(for location: IceBarLocation) -> CGFloat {
            switch location {
            case .dynamic:
                if appState?.eventManager.isMouseInsideEmptyMenuBarSpace == true {
                    return x(for: .mousePointer)
                }
                return x(for: .iceIcon)
            case .mousePointer:
                guard let location = MouseCursor.locationAppKit else {
                    return x(for: .iceIcon)
                }
                return location.x
            case .iceIcon:
                guard
                    let section = appState?.menuBarManager.section(withName: .visible),
                    // Bridging.getWindowFrame is more reliable than ControlItem.windowFrame,
                    // i.e. if the control item is offscreen. Fall back to our own window's
                    // frame when the system no longer exposes a per-item window ID.
                    let itemFrame = section.controlItem.windowID.flatMap({ Bridging.getWindowFrame(for: $0) })
                        ?? section.controlItem.windowFrame
                else {
                    return screen.frame.maxX
                }
                return itemFrame.midX
            }
        }

        let location = appState?.settingsManager.generalSettingsManager.iceBarLocation ?? .iceIcon
        return CGPoint(x: x(for: location).clamped(to: bounds), y: y)
    }

    /// Reveals the hidden sections without persisting, runs `body`, then hides
    /// them again (unless a newer choice changed them meanwhile). Runs one after
    /// another; `supersede` cancels a run still waiting to start its body.
    @discardableResult
    private func runRevealed(
        supersede: Bool,
        _ body: @escaping @MainActor () async throws -> Void
    ) -> Task<Void, Never> {
        let previous = axActivationTask
        if supersede {
            previous?.cancel()
        }
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, let appState, !Task.isCancelled else {
                return
            }

            isActivatingAXItem = true
            let sections = appState.menuBarManager.sections.filter {
                $0.isEnabled && $0.controlItem.state == .hideItems
            }
            let revealed = sections.map { section in
                section.setState(.showItems, persist: false)
                return (section: section, revision: section.stateRevision)
            }
            defer {
                for entry in revealed where entry.section.stateRevision == entry.revision {
                    entry.section.setState(.hideItems, persist: false)
                }
                isActivatingAXItem = false
                for section in appState.menuBarManager.sections where !section.isHidden {
                    section.startRehideChecks()
                }
            }

            do {
                // Match the native section toggle's animation interval.
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                try await body()
            } catch {
                // Cancellation before the body restores the reveal without acting.
            }
        }
        axActivationTask = task
        return task
    }

    /// Waits for the revealed dividers to settle, learns which items sit in the
    /// hidden sections, and returns every discovered item.
    @MainActor
    private func learnRevealedItems() async throws -> [MenuBarItemAXDiscovery.AXMenuBarItem] {
        let alwaysHiddenEnabled = appState?.menuBarManager.section(withName: .alwaysHidden)?.isEnabled == true
        var found = [MenuBarItemAXDiscovery.AXMenuBarItem]()
        for attempt in 0..<8 {
            let apps = NSWorkspace.shared.runningApplications
            let scan = await Task.detached(priority: .userInitiated) {
                (
                    MenuBarItemAXDiscovery.discoverItems(in: apps),
                    MenuBarItemAXDiscovery.dividerFrames()
                )
            }.value
            found = scan.0
            let hidden = scan.1.hidden.flatMap { MenuBarItemAXDiscovery.isSettledDividerFrame($0) ? $0.minX : nil }
            let alwaysHidden = scan.1.alwaysHidden.flatMap { MenuBarItemAXDiscovery.isSettledDividerFrame($0) ? $0.minX : nil }
            // Wait for both dividers; the last attempt settles for the Hidden one.
            if let hidden, alwaysHidden != nil || !alwaysHiddenEnabled || attempt == 7 {
                IceBarItemMemory.learn(
                    from: found,
                    hiddenDividerX: hidden,
                    alwaysHiddenDividerX: alwaysHiddenEnabled ? alwaysHidden : nil
                )
                Logger.iceBar.info("learned items attempt=\(attempt) found=\(found.count) remembered=\(IceBarItemMemory.entries.count)")
                return found
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        Logger.iceBar.error("learn: dividers never settled found=\(found.count)")
        return found
    }

    /// Briefly reveals the hidden sections to learn which items they hold.
    func refreshItemMemory() async {
        await runRevealed(supersede: false) { [weak self] in
            _ = try await self?.learnRevealedItems()
        }.value
    }

    /// Reveals the hidden sections, finds the item again, and presses it via
    /// Accessibility. Parked items have no Accessibility node, and parked status
    /// items may acknowledge a press without opening anything, so the press waits
    /// for the reveal. Menus stay revealed until they close.
    func activate(_ entry: IceBarItemMemory.Entry, liveItem: MenuBarItemAXDiscovery.AXMenuBarItem?) {
        close()
        runRevealed(supersede: true) { [weak self] in
            guard let self else {
                return
            }
            let found = try await learnRevealedItems()
            try Task.checkCancellation()
            guard let item = IceBarItemMemory.match(entry, in: found) ?? liveItem else {
                Logger.iceBar.error("activate: \(entry.key) not found after reveal")
                return
            }

            // Once a press is committed, cancellation must not restore the originals
            // beneath its popup. This unstructured task owns the press and menu lifetime;
            // cancelling the outer task only supersedes a request still waiting to press.
            try await Task { @MainActor in
                let previousWindows = Set(WindowInfo.getOnScreenWindows().map(\.windowID))
                let acknowledged = await Task.detached(priority: .userInitiated) {
                    MenuBarItemAXDiscovery.press(item)
                }.value

                // AX success alone is not evidence of a menu. Conversely, a modal menu
                // can open while the request times out, so check even after an AX error.
                func hasOpenMenu() -> Bool {
                    WindowInfo.getOnScreenWindows().contains { window in
                        !previousWindows.contains(window.windowID) &&
                        !window.frame.isEmpty && !window.isMenuBarItem &&
                        window.layer >= CGWindowLevelForKey(.mainMenuWindow) &&
                        (window.ownerPID == item.pid ||
                            NSRunningApplication(processIdentifier: window.ownerPID)?.bundleIdentifier == "com.apple.controlcenter")
                    }
                }
                var observedMenu = false
                for _ in 0..<10 {
                    if hasOpenMenu() {
                        observedMenu = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard observedMenu else {
                    Logger.iceBar.error("axActivation no visible menu pid=\(item.pid) acknowledged=\(acknowledged)")
                    return
                }
                Logger.iceBar.info("axActivation observed menu pid=\(item.pid)")
                // Keep the reveal while any popup remains, including a parent whose
                // frontmost submenu closed or a replacement popup with a new window ID.
                while hasOpenMenu() {
                    try await Task.sleep(for: .milliseconds(150))
                }
            }.value
        }
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

        // A newer show() may have claimed the panel while waiting for the cache —
        // bail out without closing (the panel now belongs to that show).
        guard currentSection == section else {
            return
        }

        dismissPopover()

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        // Captured item images are drawn for the menu bar's appearance (e.g. white
        // glyphs on a dark menu bar), so match it; AX rows use template symbols
        // and app icons, which read fine with the system appearance.
        if !appState.itemManager.usesAccessibilityItemActivation {
            popover.appearance = appState.menuBarManager.section(withName: .visible)?.controlItem.window?.effectiveAppearance
        }

        let hostingView = IceBarHostingView(
            appState: appState,
            screen: screen,
            closePanel: { [weak self] in
                self?.close()
            },
            sizeDidChange: { [weak popover] size in
                guard
                    let popover,
                    size.width > 0,
                    size.height > 0,
                    popover.contentSize != size
                else {
                    return
                }
                popover.contentSize = size
            }
        )
        let viewController = NSViewController()
        viewController.view = hostingView
        popover.contentViewController = viewController
        let fittingSize = hostingView.fittingSize
        popover.contentSize = fittingSize.width > 0 && fittingSize.height > 0
            ? fittingSize
            : CGSize(width: 372, height: 140)
        self.popover = popover

        setFrameOrigin(anchorPoint(for: screen))
        orderFrontRegardless()

        guard let contentView else {
            return
        }
        popover.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
        mouseDownMonitor.start()
    }

    /// Closes the popover without routing back through the delegate.
    private func dismissPopover() {
        mouseDownMonitor.stop()
        guard let popover else {
            return
        }
        self.popover = nil
        popover.delegate = nil
        popover.close()
    }

    override func close() {
        dismissPopover()
        super.close()
        currentSection = nil
        appState?.navigationState.isIceBarPresented = false
    }
}

// MARK: IceBarPanel: NSPopoverDelegate
extension IceBarPanel: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else {
            return
        }
        close()
    }
}

// MARK: - IceBarHostingView

private final class IceBarHostingView: NSHostingView<AnyView> {
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets()
    }

    init(
        appState: AppState,
        screen: NSScreen,
        closePanel: @escaping () -> Void,
        sizeDidChange: @escaping (CGSize) -> Void
    ) {
        super.init(
            rootView: IceBarContentView(screen: screen, closePanel: closePanel, sizeDidChange: sizeDidChange)
                .environmentObject(appState)
                .environmentObject(appState.imageCache)
                .environmentObject(appState.itemManager)
                .environmentObject(appState.menuBarManager)
                .erasedToAnyView()
        )
        // The popover owns the size (driven by `sizeDidChange`); don't let the
        // hosting view's own constraints fight it.
        self.sizingOptions = []
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

// MARK: - IceBarFlowLayout

/// Lays items out left to right, wrapping onto new rows.
private struct IceBarFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = arrange(width: bounds.width, subviews: subviews).origins
        for (subview, origin) in zip(subviews, origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins = [CGPoint]()
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            maxWidth = max(maxWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, CGSize(width: maxWidth, height: y + rowHeight))
    }
}

// MARK: - IceBarCell

/// A hover-highlighted cell around a single item in the dropdown.
private struct IceBarCell<Content: View>: View {
    @State private var isHovering = false

    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(minWidth: 32, minHeight: 28)
            .padding(.horizontal, 2)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.12 : 0))
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

// MARK: - IceBarContentView

private struct IceBarContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var itemManager: MenuBarItemManager
    @EnvironmentObject var imageCache: MenuBarItemImageCache
    @EnvironmentObject var menuBarManager: MenuBarManager
    @State private var axRows = [AXRowItem]()
    @State private var hasAXPermission = MenuBarItemAXDiscovery.isTrusted()
    @State private var isLoadingAXRows = false
    @State private var hasLoadedAXRows = false

    let screen: NSScreen
    let closePanel: () -> Void
    let sizeDidChange: (CGSize) -> Void

    /// The Always-Hidden group only appears when that section is enabled.
    private var showsAlwaysHidden: Bool {
        menuBarManager.section(withName: .alwaysHidden)?.isEnabled == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
        }
        .padding(16)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .onFrameChange { frame in
            sizeDidChange(frame.size)
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("Ice Bar")
                .font(.title3.weight(.semibold))
            Spacer()
            if itemManager.usesAccessibilityItemActivation, hasAXPermission {
                Button {
                    Task {
                        await reloadAXRows(refreshingMemory: true)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isLoadingAXRows)
                .help("Reveal the hidden sections for a moment to update this list")
            }
            Button {
                closePanel()
                appState.navigationState.settingsNavigationIdentifier = .menuBarLayout
                appState.appDelegate?.openSettingsWindow()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open Menu Bar Layout settings")
        }
    }

    @ViewBuilder
    private var content: some View {
        if itemManager.usesAccessibilityItemActivation {
            // macOS 27+: CGS no longer has per-item windows — show the app icon and
            // press via Accessibility instead of window snapshots + temp-show.
            // macOS 26 uses this too: moving items there is unreliable.
            axContent
                .task {
                    await loadAXRows()
                }
        } else if !ScreenCapture.cachedCheckPermissions() {
            message("The Ice Bar requires screen recording permissions.") {
                Button("Open Ice Settings") {
                    closePanel()
                    appState.navigationState.settingsNavigationIdentifier = .advanced
                    appState.appDelegate?.openSettingsWindow()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.link)
            }
        } else if menuBarManager.isMenuBarHiddenBySystemUserDefaults {
            message("Ice cannot display menu bar items for automatically hidden menu bars") {
                EmptyView()
            }
        } else {
            IceSection("Hidden") {
                capturedItems(for: .hidden)
            }
            if showsAlwaysHidden {
                IceSection("Always-Hidden") {
                    capturedItems(for: .alwaysHidden)
                }
            }
        }
    }

    @ViewBuilder
    private func message<Actions: View>(_ text: LocalizedStringKey, @ViewBuilder actions: () -> Actions) -> some View {
        IceSection {
            VStack(spacing: 6) {
                Text(text)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    actions()
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func placeholder(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 28)
    }

    @ViewBuilder
    private func capturedItems(for section: MenuBarSection.Name) -> some View {
        let items = itemManager.itemCache.managedItems(for: section).filter { imageCache.images[$0.info] != nil }
        if imageCache.cacheFailed(for: section) {
            placeholder("Unable to display menu bar items")
        } else if items.isEmpty {
            placeholder("No items")
        } else {
            IceBarFlowLayout {
                ForEach(items, id: \.windowID) { item in
                    IceBarCell {
                        IceBarItemView(item: item, closePanel: closePanel)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - AX fallback (macOS 26+)

    /// Icon row for the Ice Bar when CGS no longer has per-item windows.
    private struct AXRowItem: Identifiable {
        let entry: IceBarItemMemory.Entry
        /// The item's Accessibility node, when it currently has one.
        let liveItem: MenuBarItemAXDiscovery.AXMenuBarItem?
        let systemImage: String?
        let appIcon: NSImage?

        var id: String { entry.key }
        var section: MenuBarSection.Name { entry.sectionName }
        var title: String? { entry.title }
        var displayName: String { entry.displayName }
    }

    private static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    @ViewBuilder
    private var axContent: some View {
        if !hasAXPermission {
            message("The Ice Bar requires accessibility permission.") {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(Self.accessibilitySettingsURL)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.link)

                Button("Check Again") {
                    hasAXPermission = MenuBarItemAXDiscovery.isTrusted()
                    if hasAXPermission {
                        Task {
                            await loadAXRows()
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.link)
            }
        } else {
            IceSection("Hidden") {
                axItems(for: .hidden)
            }
            if showsAlwaysHidden {
                IceSection("Always-Hidden") {
                    axItems(for: .alwaysHidden)
                }
            }
        }
    }

    @ViewBuilder
    private func axItems(for section: MenuBarSection.Name) -> some View {
        let rows = axRows.filter { $0.section == section }
        if !rows.isEmpty {
            IceBarFlowLayout {
                ForEach(rows) { row in
                    axRowView(row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if !hasLoadedAXRows || isLoadingAXRows {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 28)
        } else {
            placeholder("No items")
        }
    }

    @ViewBuilder
    private func axRowView(_ row: AXRowItem) -> some View {
        Button {
            press(row)
        } label: {
            IceBarCell {
                if let systemName = row.systemImage {
                    Image(systemName: systemName)
                        .font(.system(size: 16))
                } else if let icon = row.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                } else if let title = row.title, !title.isEmpty {
                    Text(title)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                } else {
                    Text(row.displayName)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                }
            }
        }
        .buttonStyle(.plain)
        .help(row.displayName)
        .accessibilityLabel(row.displayName)
        .accessibilityAction(named: "press") {
            press(row)
        }
    }

    /// Lists the remembered hidden items. The first time, when nothing is
    /// remembered yet, reveals the sections for a moment to learn them.
    @MainActor
    private func loadAXRows() async {
        await reloadAXRows(refreshingMemory: IceBarItemMemory.entries.isEmpty)
    }

    @MainActor
    private func reloadAXRows(refreshingMemory: Bool) async {
        guard !isLoadingAXRows else {
            return
        }
        isLoadingAXRows = true
        defer {
            isLoadingAXRows = false
            hasLoadedAXRows = true
        }

        hasAXPermission = MenuBarItemAXDiscovery.isTrusted()
        guard hasAXPermission else {
            return
        }
        if refreshingMemory {
            await menuBarManager.iceBarPanel.refreshItemMemory()
        }
        await buildAXRows()
    }

    /// Builds rows from the remembered items whose apps are running, leaving
    /// out any that are drawn in the menu bar right now (moved to Visible).
    @MainActor
    private func buildAXRows() async {
        // NSWorkspace must be read on main; discovery runs in the background.
        let apps = NSWorkspace.shared.runningApplications
        let found = await Task.detached(priority: .userInitiated) {
            MenuBarItemAXDiscovery.discoverItems(in: apps)
        }.value

        let running = Set(apps.compactMap(\.bundleIdentifier))
        // Concealed apps keep reporting their old frames through Accessibility.
        let concealed = menuBarManager.concealer.concealedBundleIDs
        let live = Dictionary(IceBarItemMemory.keyedItems(found), uniquingKeysWith: { first, _ in first })

        var icons = [String: NSImage]()
        var rows = [AXRowItem]()
        for entry in IceBarItemMemory.entries where running.contains(entry.bundleID) {
            if (entry.sectionName == .alwaysHidden) && !showsAlwaysHidden {
                continue
            }
            let liveItem = live[entry.key]
            if
                let liveItem,
                !concealed.contains(entry.bundleID),
                IceBarItemMemory.isDrawnInMenuBar(liveItem.axFrame)
            {
                continue
            }
            // Same icon selection as Menu Bar Layout: familiar system extras
            // use SF Symbols (a PID-based icon would yield the generic MenuBarAgent icon).
            let systemImage = MenuBarItemAXDiscovery.systemImageName(forIdentifier: entry.identifier)
            if systemImage == nil, icons[entry.bundleID] == nil {
                if entry.bundleID == "com.apple.TextInputMenuAgent" {
                    icons[entry.bundleID] = MenuBarItemAXDiscovery.inputSourceIcon()
                } else {
                    icons[entry.bundleID] = NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundleID).first?.icon
                        ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
                }
            }
            rows.append(
                AXRowItem(
                    entry: entry,
                    liveItem: liveItem,
                    systemImage: systemImage,
                    appIcon: icons[entry.bundleID]
                )
            )
        }
        axRows = rows
        Logger.iceBar.info("axScan done found=\(found.count) remembered=\(IceBarItemMemory.entries.count) rows=\(rows.count)")
    }

    /// The panel owns the activation task after closing and releasing this view.
    private func press(_ row: AXRowItem) {
        Logger.iceBar.info("axPress requested key=\(row.entry.key) live=\(row.liveItem != nil)")
        menuBarManager.iceBarPanel.activate(row.entry, liveItem: row.liveItem)
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

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            return true
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
