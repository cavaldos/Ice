//
//  MenuBarOverlayPanel.swift
//  Ice
//

import AXSwift
import Cocoa
import Combine
import QuartzCore

// MARK: - Overlay Panel

/// A subclass of `NSPanel` that sits atop the menu bar to alter its appearance.
final class MenuBarOverlayPanel: NSPanel {
    /// Flags representing the updatable components of a panel.
    enum UpdateFlag: String, CustomStringConvertible {
        case applicationMenuFrame

        var description: String { rawValue }
    }

    /// The kind of validation that occurs before an update.
    private enum ValidationKind {
        case showing
        case updates
    }

    /// A context that manages panel update tasks.
    private final class UpdateTaskContext {
        private var tasks = [UpdateFlag: Task<Void, any Error>]()

        /// Sets the task for the given update flag.
        ///
        /// Setting the task cancels the previous task for the flag, if there is one.
        ///
        /// - Parameters:
        ///   - flag: The update flag to set the task for.
        ///   - timeout: The timeout of the task.
        ///   - operation: The operation for the task to perform.
        func setTask(for flag: UpdateFlag, timeout: Duration, operation: @escaping () async throws -> Void) {
            cancelTask(for: flag)
            tasks[flag] = Task.detached(timeout: timeout) {
                try await operation()
            }
        }

        /// Cancels the task for the given update flag.
        ///
        /// - Parameter flag: The update flag to cancel the task for.
        func cancelTask(for flag: UpdateFlag) {
            tasks.removeValue(forKey: flag)?.cancel()
        }
    }

    /// A Boolean value that indicates whether the panel needs to be shown.
    @Published var needsShow = false

    /// A Boolean value that indicates whether the user is dragging a menu bar item.
    @Published var isDraggingMenuBarItem = false

    /// Flags representing the components of the panel currently in need of an update.
    @Published private(set) var updateFlags = Set<UpdateFlag>()

    /// The frame of the application menu.
    @Published private(set) var applicationMenuFrame: CGRect?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The context that manages panel update tasks.
    private let updateTaskContext = UpdateTaskContext()

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// The screen that owns the panel.
    let owningScreen: NSScreen

    /// Creates an overlay panel with the given app state and owning screen.
    init(appState: AppState, owningScreen: NSScreen) {
        self.appState = appState
        self.owningScreen = owningScreen
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Level 24 (same as the menu bar background): the tint is fully
        // opaque, so the panel must never sit above the status-item windows
        // (level 25) or it would cover the menu bar icons. show() orders it
        // just above the menu bar background window instead.
        self.level = .mainMenu
        self.title = "Menu Bar Overlay"
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.fullScreenNone, .ignoresCycle, .moveToActiveSpace]
        self.contentView = MenuBarOverlayPanelContentView()
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        // Show the panel on the active space.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .debounce(for: 0.1, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.needsShow = true
            }
            .store(in: &c)

        // Redraw with the correct light/dark tint when the system
        // appearance changes. The stored configuration holds both variants,
        // so no publisher fires for the switch — trigger a redraw directly.
        DistributedNotificationCenter.default()
            .publisher(for: DistributedNotificationCenter.interfaceThemeChangedNotification)
            .debounce(for: 0.1, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.contentView?.needsDisplay = true
            }
            .store(in: &c)

        // Update application menu frame when the menu bar owning or frontmost app changes.
        Publishers.Merge(
            NSWorkspace.shared.publisher(for: \.menuBarOwningApplication, options: .old)
                .combineLatest(NSWorkspace.shared.publisher(for: \.menuBarOwningApplication, options: .new))
                .compactMap { $0 == $1 ? nil : $0 },
            NSWorkspace.shared.publisher(for: \.frontmostApplication, options: .old)
                .combineLatest(NSWorkspace.shared.publisher(for: \.frontmostApplication, options: .new))
                .compactMap { $0 == $1 ? nil : $0 }
        )
        .removeDuplicates()
        .sink { [weak self] _ in
            guard
                let self,
                let appState
            else {
                return
            }
            let displayID = owningScreen.displayID
            updateTaskContext.setTask(for: .applicationMenuFrame, timeout: .seconds(10)) {
                var hasDoneInitialUpdate = false
                var consecutiveMisses = 0
                while true {
                    try Task.checkCancellation()
                    guard
                        let latestFrame = appState.menuBarManager.getApplicationMenuFrame(for: displayID),
                        latestFrame != self.applicationMenuFrame
                    else {
                        // ponytail: was 1ms spin (~1000 AX round-trips/s for up to 10s).
                        // Back off exponentially while the menu bar isn't resolving so
                        // boot/app-switch doesn't stall WindowServer IPC.
                        if hasDoneInitialUpdate {
                            try await Task.sleep(for: .seconds(1))
                        } else {
                            consecutiveMisses += 1
                            let backoffMs = Int64(min(50 * consecutiveMisses, 500))
                            try await Task.sleep(for: .milliseconds(backoffMs))
                        }
                        continue
                    }
                    consecutiveMisses = 0
                    self.insertUpdateFlag(.applicationMenuFrame)
                    hasDoneInitialUpdate = true
                }
            }
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                if self.owningScreen != NSScreen.main {
                    self.updateTaskContext.cancelTask(for: .applicationMenuFrame)
                }
            }
        }
        .store(in: &c)

        // Special cases for when the user drags an app onto or clicks into another space.
        Publishers.Merge(
            publisher(for: \.isOnActiveSpace)
                .receive(on: DispatchQueue.main)
                .mapToVoid(),
            UniversalEventMonitor.publisher(for: .leftMouseUp)
                .filter { [weak self] _ in self?.isOnActiveSpace ?? false }
                .mapToVoid()
        )
        .debounce(for: 0.05, scheduler: DispatchQueue.main)
        .sink { [weak self] in
            self?.insertUpdateFlag(.applicationMenuFrame)
        }
        .store(in: &c)

        Timer.publish(every: 10, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                self?.insertUpdateFlag(.applicationMenuFrame)
            }
            .store(in: &c)

        $needsShow
            .debounce(for: 0.05, scheduler: DispatchQueue.main)
            .sink { [weak self] needsShow in
                guard let self, needsShow else {
                    return
                }
                defer {
                    self.needsShow = false
                }
                show()
            }
            .store(in: &c)

        $updateFlags
            .sink { [weak self] flags in
                guard let self, !flags.isEmpty else {
                    return
                }
                Task {
                    // Must be run async, or this will not remove the flags.
                    self.updateFlags.removeAll()
                }
                let windows = WindowInfo.getOnScreenWindows()
                guard let owningDisplay = self.validate(for: .updates, with: windows) else {
                    return
                }
                performUpdates(for: flags, windows: windows, display: owningDisplay)
            }
            .store(in: &c)

        if let appState {
            appState.menuBarManager.$isMenuBarHiddenBySystem
                .sink { [weak self] isHidden in
                    self?.alphaValue = isHidden ? 0 : 1
                }
                .store(in: &c)
        }

        cancellables = c
    }

    /// Inserts the given update flag into the panel's current list of update flags.
    private func insertUpdateFlag(_ flag: UpdateFlag) {
        updateFlags.insert(flag)
    }

    /// Performs validation for the given validation kind. Returns the panel's
    /// owning display if successful. Returns `nil` on failure.
    private func validate(for kind: ValidationKind, with windows: [WindowInfo]) -> CGDirectDisplayID? {
        lazy var actionMessage = switch kind {
        case .showing: "Preventing overlay panel from showing."
        case .updates: "Preventing overlay panel from updating."
        }
        guard let appState else {
            Logger.overlayPanel.debug("No app state. \(actionMessage)")
            return nil
        }
        guard !appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults else {
            Logger.overlayPanel.debug("Menu bar is hidden by system. \(actionMessage)")
            return nil
        }
        guard !appState.isActiveSpaceFullscreen else {
            Logger.overlayPanel.debug("Active space is fullscreen. \(actionMessage)")
            return nil
        }
        let owningDisplay = owningScreen.displayID
        guard appState.menuBarManager.hasValidMenuBar(in: windows, for: owningDisplay) else {
            Logger.overlayPanel.debug("No valid menu bar found. \(actionMessage)")
            return nil
        }
        return owningDisplay
    }

    /// Stores the frame of the menu bar's application menu.
    private func updateApplicationMenuFrame(for display: CGDirectDisplayID) {
        guard
            let menuBarManager = appState?.menuBarManager,
            !menuBarManager.isMenuBarHiddenBySystem
        else {
            return
        }
        applicationMenuFrame = menuBarManager.getApplicationMenuFrame(for: display)
    }

    /// Updates the panel to prepare for display.
    private func performUpdates(for flags: Set<UpdateFlag>, windows: [WindowInfo], display: CGDirectDisplayID) {
        if flags.contains(.applicationMenuFrame) {
            updateApplicationMenuFrame(for: display)
        }
    }

    /// Shows the panel.
    private func show() {
        guard
            let appState,
            !appState.isPreview
        else {
            return
        }

        guard appState.appearanceManager.overlayPanels.contains(self) else {
            Logger.overlayPanel.warning("Overlay panel \(self) not retained")
            return
        }

        guard let menuBarHeight = owningScreen.getMenuBarHeight() else {
            return
        }

        let newFrame = CGRect(
            x: owningScreen.frame.minX,
            y: (owningScreen.frame.maxY - menuBarHeight) - 5,
            width: owningScreen.frame.width,
            height: menuBarHeight + 5
        )

        alphaValue = 0
        setFrame(newFrame, display: false)
        orderFrontRegardless()
        // The tint is opaque: keep the panel below the status-item windows
        // (level 25) by pinning it just above the menu bar background window
        // (same level 24). Otherwise the pills would cover the menu bar icons.
        if let menuBarWindowID = WindowInfo.getMenuBarWindow(for: owningScreen.displayID)?.windowID {
            order(.above, relativeTo: Int(menuBarWindowID))
        }

        updateFlags = [.applicationMenuFrame]

        // ponytail: no animator() fade on show. Fading while the split shape is
        // still unresolved (AX pending) flashes a half-tinted gray bar and costs
        // a compositor animation at every space switch. Appear instantly; the
        // shape resolves into place via needsDisplay.
        if !appState.menuBarManager.isMenuBarHiddenBySystem {
            alphaValue = 1
        }
    }

    override func isAccessibilityElement() -> Bool {
        return false
    }
}

// MARK: - Content View

final class MenuBarOverlayPanelContentView: NSView {
    /// Chiều rộng pill trailing đang vẽ trên display (vùng visible items).
    ///
    /// Ice Bar (spacer nở, vạch chia frame rác) dùng để loại items user đang
    /// thấy sẵn trên menubar. Ưu tiên width đang vẽ, rồi predicted, rồi cache.
    /// Nil khi chưa đo được — bên gọi hiện tất cả như cũ.
    static func currentTrailingVisibleWidth(for display: CGDirectDisplayID) -> CGFloat? {
        loadPersistedTrailingWidths()
        let width = displayedTrailingWidth[display]
            ?? predictiveTarget[display]
            ?? trailingWidthCache[display]?.width
        guard let width, width > 0 else {
            return nil
        }
        return width
    }
    /// Last-known trailing status widths per display, shared across panels.
    ///
    /// Panels are recreated on display/space/config changes, so per-view
    /// memory forced a full AX re-learn (toggle on/off a few times) every
    /// time — including every cold boot. Shared statics + UserDefaults
    /// persistence mean the first draw already knows last session's widths;
    /// the background rescan only corrects them.
    ///
    /// The Accessibility fallback scan blocks in cross-process IPC, so it must
    /// never run inside `draw(_:)`. Draws read this cache (main thread only);
    /// stale entries trigger a background rescan that redisplays on completion.
    private static var trailingWidthCache = [CGDirectDisplayID: (width: CGFloat, date: Date)]()

    /// Displays with a background trailing-width rescan in flight.
    private static var trailingWidthScanInFlight = Set<CGDirectDisplayID>()

    /// How long a cached trailing width is trusted before rescanning.
    ///
    /// Short enough that third-party trailing changes (Control Center
    /// sliders, clock/date width) re-measure quickly; the scan itself stays
    /// on a background queue, so the cost is one background sweep per TTL.
    private static let trailingWidthTTL: TimeInterval = 2

    /// Burst-rescan deadlines per display.
    ///
    /// While a hide/show slide animation is in flight, each completed scan
    /// chains another one so the trailing pill tracks the sliding icons
    /// instead of jumping on the TTL.
    private static var trailingBurstUntil = [CGDirectDisplayID: Date]()

    /// Settled trailing widths remembered per display: concealed (hidden
    /// section put away) vs revealed. Toggles alternate between these two
    /// values, so a hide/show can start gliding toward the remembered
    /// opposite end instantly — ~1s before the AX rescan lands to confirm.
    private static var settledConcealedWidth = [CGDirectDisplayID: CGFloat]()
    private static var settledRevealedWidth = [CGDirectDisplayID: CGFloat]()

    /// Predictive target per display. Draws snap to this instead of the stale
    /// cache while a toggle burst (or cold boot) is resolving; cleared when
    /// the rescan confirms the real width.
    private static var predictiveTarget = [CGDirectDisplayID: CGFloat]()

    /// Currently drawn trailing width per display.
    ///
    /// Expands snap to the target instantly, but collapses ease toward it
    /// (see `trailingCollapsePointsPerSecond`), so the pill glides shut with
    /// the sliding icons instead of blinking to its final size.
    private static var displayedTrailingWidth = [CGDirectDisplayID: CGFloat]()

    /// Collapse speed of the trailing pill, in points per second.
    ///
    /// ~900pt/s closes a typical 300pt cluster in a third of a second —
    /// close to the native icon slide, deliberately slower than the instant
    /// snap used before. Raise to retract faster, lower for a lazier close.
    private static let trailingCollapsePointsPerSecond: CGFloat = 900

    /// 60Hz driver that advances the collapse animation. Created on demand,
    /// stopped as soon as every width lands — never a perpetual redraw.
    private var trailingEaseTimer: Timer?

    /// Whether persisted trailing widths have been loaded this launch.
    private static var trailingWidthsLoaded = false

    /// UserDefaults key for persisted trailing widths.
    ///
    /// Bumped to v2: v1 learnings captured while dividers were misordered
    /// (or before the AH default change) predict a stale pill that trails
    /// the icons by a beat. Relearn from the current arrangement instead.
    private static let trailingWidthsDefaultsKey = "Ice.TrailingWidths.v2"

    /// Displays for which the split-shape auxiliary-area fallback fired.
    ///
    /// Logged once per display: the draw path runs on every redisplay while
    /// a measurement stays unavailable, so an unguarded log would spam.
    private static var splitFallbackLogged = Set<CGDirectDisplayID>()

    /// Logs the split-shape auxiliary-area fallback once per display.
    private static func logSplitFallbackOnce(for display: CGDirectDisplayID, side: String) {
        guard !splitFallbackLogged.contains(display) else {
            return
        }
        splitFallbackLogged.insert(display)
        Logger.overlayPanel.debug("Split \(side) measurement unknown — using auxiliary-area fallback on display \(display)")
    }

    /// Loads persisted trailing widths once per launch.
    ///
    /// Stored as `"<displayID>.concealed|revealed|cache": Double`. Cached
    /// entries load as stale (`.distantPast`) so the first draw paints the
    /// remembered pill instantly while a background rescan re-validates it.
    private static func loadPersistedTrailingWidths() {
        guard !trailingWidthsLoaded else {
            return
        }
        trailingWidthsLoaded = true
        guard let dict = UserDefaults.standard.dictionary(forKey: trailingWidthsDefaultsKey) as? [String: Double] else {
            return
        }
        for (key, value) in dict {
            let parts = key.split(separator: ".")
            guard
                parts.count == 2,
                let display = CGDirectDisplayID(String(parts[0]))
            else {
                continue
            }
            let width = CGFloat(value)
            guard width > 0, width < 2000 else {
                continue
            }
            switch parts[1] {
            case "concealed":
                settledConcealedWidth[display] = width
            case "revealed":
                settledRevealedWidth[display] = width
            case "cache":
                if trailingWidthCache[display] == nil {
                    trailingWidthCache[display] = (width, .distantPast)
                }
            default:
                break
            }
        }
    }

    /// Persists the learned trailing widths for the next launch.
    private static func persistTrailingWidths() {
        var dict = [String: Double]()
        for (display, width) in settledConcealedWidth {
            dict["\(display).concealed"] = Double(width)
        }
        for (display, width) in settledRevealedWidth {
            dict["\(display).revealed"] = Double(width)
        }
        for (display, entry) in trailingWidthCache where entry.width > 0 {
            dict["\(display).cache"] = Double(entry.width)
        }
        UserDefaults.standard.set(dict, forKey: trailingWidthsDefaultsKey)
    }

    /// Returns the remembered settled width for the display.
    ///
    /// Falls back to the opposite end when only one is known (fresh install,
    /// first toggle): a slightly wrong pill beats a missing one.
    private static func settledWidth(for display: CGDirectDisplayID, concealed: Bool?) -> CGFloat? {
        guard let concealed else {
            return settledConcealedWidth[display] ?? settledRevealedWidth[display]
        }
        let width = concealed ? settledConcealedWidth[display] : settledRevealedWidth[display]
        return width ?? (concealed ? settledRevealedWidth[display] : settledConcealedWidth[display])
    }

    /// Whether the hidden section is currently concealed, if known.
    private func isConcealed() -> Bool? {
        guard
            let hiddenSection = overlayPanel?.appState?.menuBarManager.section(withName: .hidden)
        else {
            return nil
        }
        return hiddenSection.controlItem.state == .hideItems
    }

    /// Seeds the predictive target from remembered widths when empty, so the
    /// first draw after boot/recreation opens at the right size, not 0.
    private func seedPredictionIfNeeded(for display: CGDirectDisplayID) {
        Self.loadPersistedTrailingWidths()
        guard Self.predictiveTarget[display] == nil else {
            return
        }
        if
            let remembered = Self.settledWidth(for: display, concealed: isConcealed()),
            remembered > 0
        {
            Self.predictiveTarget[display] = remembered
        }
    }

    /// Frosted-glass blur of the live background, masked to the pills.
    ///
    /// Sits below `tintView`: blur first, then the (possibly translucent)
    /// tint on top.
    private lazy var blurView: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.mask = blurMask
        return view
    }()

    /// Mask that clips `blurView` to the pills.
    private let blurMask = CAShapeLayer()

    /// Draws the pill tint (and border) above `blurView`.
    private lazy var tintView = MenuBarTintView()

    @Published private var fullConfiguration: MenuBarAppearanceConfigurationV2 = .defaultConfiguration

    @Published private var previewConfiguration: MenuBarAppearancePartialConfiguration?

    private var cancellables = Set<AnyCancellable>()

    /// The overlay panel that contains the content view.
    private var overlayPanel: MenuBarOverlayPanel? {
        window as? MenuBarOverlayPanel
    }

    /// The currently displayed configuration.
    private var configuration: MenuBarAppearancePartialConfiguration {
        previewConfiguration ?? fullConfiguration.current
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // blurView below, tintView above: blur first, then tint on top.
        addSubview(blurView)
        addSubview(tintView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureCancellables()
        guard let panel = overlayPanel else {
            // Detached: stop the collapse driver, if running.
            trailingEaseTimer?.invalidate()
            trailingEaseTimer = nil
            return
        }
        // Warm the shared trailing cache immediately so the first draw (and
        // cold boot) already has a width. Previously the scan only started
        // lazily inside draw(), adding ~1s of mismatched pill at login.
        let display = panel.owningScreen.displayID
        seedPredictionIfNeeded(for: display)
        refreshTrailingStatusWidth(for: display, force: false)
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let overlayPanel {
            if let appState = overlayPanel.appState {
                appState.appearanceManager.$configuration
                    .removeDuplicates()
                    .assign(to: &$fullConfiguration)

                appState.appearanceManager.$previewConfiguration
                    .removeDuplicates()
                    .assign(to: &$previewConfiguration)

                for section in appState.menuBarManager.sections {
                    // Redraw whenever the window frame of a control item changes.
                    //
                    // - NOTE: A previous attempt was made to redraw the view when the
                    //   section's `isHidden` property was changed. This would be semantically
                    //   ideal, but the property sometimes changes before the menu bar items
                    //   are actually updated on-screen. Since the view's drawing process relies
                    //   on getting an accurate position of each menu bar item, we need to use
                    //   something that publishes its changes only after the items are updated.
                    section.controlItem.$windowFrame
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] _ in
                            self?.noteControlItemMoved()
                        }
                        .store(in: &c)

                    // Redraw whenever the visibility of a control item changes.
                    //
                    // - NOTE: If the "ShowSectionDividers" setting is disabled, the window
                    //   frame does not update when the section is hidden or shown, but the
                    //   visibility does. We observe both to ensure the update occurs.
                    section.controlItem.$isVisible
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] _ in
                            self?.noteControlItemMoved()
                        }
                        .store(in: &c)
                }
            }

            // Fade out whenever a menu bar item is being dragged.
            overlayPanel.$isDraggingMenuBarItem
                .removeDuplicates()
                .sink { [weak self] isDragging in
                    if isDragging {
                        self?.animator().alphaValue = 0
                    } else {
                        self?.animator().alphaValue = 1
                    }
                }
                .store(in: &c)
            // Redraw whenever the application menu frame changes.
            overlayPanel.$applicationMenuFrame
                .sink { [weak self] _ in
                    self?.needsDisplay = true
                }
                .store(in: &c)
        }

        // Redraw whenever the configurations change.
        $fullConfiguration.mapToVoid()
            .merge(with: $previewConfiguration.mapToVoid())
            .sink { [weak self] _ in
                self?.needsDisplay = true
            }
            .store(in: &c)

        // Third-party trailing changes (Control Center sliders, clock/date
        // width, minute rollover, freshly launched apps) don't move Ice's
        // control items, so none of the above fires. Redisplay on a backstop
        // interval; draws re-measure in the background when stale. The fast
        // edge check below is what catches changes quickly — this is only
        // the safety net.
        Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.needsDisplay = true
            }
            .store(in: &c)

        // Fast edge check: a handful of AX probes around the currently drawn
        // edge, ~10x cheaper than a full sweep. Catches appeared/removed
        // icons within half a second instead of leaving them floating off
        // the pill until the next toggle or backstop tick.
        Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkTrailingEdge()
            }
            .store(in: &c)

        // A newly launched or quit app often adds/removes a status icon with
        // no Ice control item moving at all — check the edge right away.
        Publishers.Merge(
            NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didLaunchApplicationNotification)
                .mapToVoid(),
            NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didTerminateApplicationNotification)
                .mapToVoid()
        )
        .debounce(for: 0.4, scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.checkTrailingEdge()
        }
        .store(in: &c)

        cancellables = c
    }

    /// Returns a path in the given rectangle, with the given end caps,
    /// and inset by the given amounts.
    private func shapePath(in rect: CGRect, leadingEndCap: MenuBarEndCap, trailingEndCap: MenuBarEndCap, screen: NSScreen) -> NSBezierPath {
        let insetRect: CGRect = if !screen.hasNotch {
            switch (leadingEndCap, trailingEndCap) {
            case (.square, .square):
                CGRect(x: rect.origin.x, y: rect.origin.y + 1, width: rect.width, height: rect.height - 2)
            case (.square, .round):
                CGRect(x: rect.origin.x, y: rect.origin.y + 1, width: rect.width - 1, height: rect.height - 2)
            case (.round, .square):
                CGRect(x: rect.origin.x + 1, y: rect.origin.y + 1, width: rect.width - 1, height: rect.height - 2)
            case (.round, .round):
                CGRect(x: rect.origin.x + 1, y: rect.origin.y + 1, width: rect.width - 2, height: rect.height - 2)
            }
        } else {
            rect
        }

        let shapeBounds = CGRect(
            x: insetRect.minX + insetRect.height / 2,
            y: insetRect.minY,
            width: insetRect.width - insetRect.height,
            height: insetRect.height
        )
        let leadingEndCapBounds = CGRect(
            x: insetRect.minX,
            y: insetRect.minY,
            width: insetRect.height,
            height: insetRect.height
        )
        let trailingEndCapBounds = CGRect(
            x: insetRect.maxX - insetRect.height,
            y: insetRect.minY,
            width: insetRect.height,
            height: insetRect.height
        )

        var path = NSBezierPath(rect: shapeBounds)

        path = switch leadingEndCap {
        case .square: path.union(NSBezierPath(rect: leadingEndCapBounds))
        case .round: path.union(NSBezierPath(ovalIn: leadingEndCapBounds))
        }

        path = switch trailingEndCap {
        case .square: path.union(NSBezierPath(rect: trailingEndCapBounds))
        case .round: path.union(NSBezierPath(ovalIn: trailingEndCapBounds))
        }

        return path
    }

    /// Returns a path for the ``MenuBarShapeKind/full`` shape kind.
    private func pathForFullShape(in rect: CGRect, info: MenuBarFullShapeInfo, isInset: Bool, screen: NSScreen) -> NSBezierPath {
        guard let appearanceManager = overlayPanel?.appState?.appearanceManager else {
            return NSBezierPath()
        }
        var rect = rect
        let shouldInset = isInset && screen.hasNotch
        if shouldInset {
            rect = rect.insetBy(dx: 0, dy: appearanceManager.menuBarInsetAmount)
            if info.leadingEndCap == .round {
                rect.origin.x += appearanceManager.menuBarInsetAmount
                rect.size.width -= appearanceManager.menuBarInsetAmount
            }
            if info.trailingEndCap == .round {
                rect.size.width -= appearanceManager.menuBarInsetAmount
            }
        }
        return shapePath(
            in: rect,
            leadingEndCap: info.leadingEndCap,
            trailingEndCap: info.trailingEndCap,
            screen: screen
        )
    }

    /// Returns a path for the ``MenuBarShapeKind/split`` shape kind.
    private func pathForSplitShape(in rect: CGRect, info: MenuBarSplitShapeInfo, isInset: Bool, screen: NSScreen) -> NSBezierPath {
        guard let appearanceManager = overlayPanel?.appState?.appearanceManager else {
            return NSBezierPath()
        }
        var rect = rect
        let shouldInset = isInset && screen.hasNotch
        if shouldInset {
            rect = rect.insetBy(dx: 0, dy: appearanceManager.menuBarInsetAmount)
            if info.leading.leadingEndCap == .round {
                rect.origin.x += appearanceManager.menuBarInsetAmount
                rect.size.width -= appearanceManager.menuBarInsetAmount
            }
            if info.trailing.trailingEndCap == .round {
                rect.size.width -= appearanceManager.menuBarInsetAmount
            }
        }
        let leadingPathBounds: CGRect = {
            if let width = overlayPanel?.applicationMenuFrame?.width, width > 0 {
                var maxX = width
                if shouldInset {
                    maxX += 10
                    if info.leading.leadingEndCap == .square {
                        maxX += appearanceManager.menuBarInsetAmount
                    }
                } else {
                    maxX += 20
                }
                return CGRect(x: rect.minX, y: rect.minY, width: maxX, height: rect.height)
            }
            // ponytail: AX app-menu frame unknown (probe miss). On notch screens
            // the system reserves the left auxiliary area for the app menu, so
            // bind the pill to it instead of dropping it — a lone trailing pill
            // reads as a "missing border" bug.
            guard
                screen.hasNotch,
                let leftArea = screen.auxiliaryTopLeftArea
            else {
                return .zero
            }
            Self.logSplitFallbackOnce(for: screen.displayID, side: "leading")
            let pad: CGFloat = shouldInset ? 10 : 20
            let width = max(0, leftArea.maxX - screen.frame.minX - rect.minX + pad)
            guard width > 0 else {
                return .zero
            }
            return CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        }()
        let trailingPathBounds: CGRect = {
            let items = MenuBarItem.getMenuBarItems(on: screen.displayID, onScreenOnly: true, activeSpaceOnly: false)
            let totalWidth: CGFloat = if items.isEmpty {
                // macOS 27: CGSGetProcessMenuBarWindowList no longer returns status
                // items, so fall back to a cached Accessibility-based estimate.
                // The live AX scan blocks in IPC and must stay off the draw path.
                cachedTrailingStatusWidth(for: screen.displayID)
            } else {
                items.reduce(into: 0) { width, item in
                    width += item.frame.width
                }
            }
            if totalWidth > 0 {
                var position = rect.maxX - totalWidth
                if shouldInset {
                    position += 4
                    if info.trailing.trailingEndCap == .square {
                        position -= appearanceManager.menuBarInsetAmount
                    }
                } else {
                    position -= 7
                }
                guard position < rect.maxX else {
                    return .zero
                }
                return CGRect(x: position, y: rect.minY, width: rect.maxX - position, height: rect.height)
            }
            // ponytail: CGS is empty on macOS 27+ and the AX rescan has no width
            // yet (roles/frames vary by OS, scan window capped). On notch screens
            // the system reserves the right auxiliary area for status items, so
            // bind the pill to it instead of dropping it — a slightly wide pill
            // with border beats a missing one.
            guard
                screen.hasNotch,
                let rightArea = screen.auxiliaryTopRightArea
            else {
                return .zero
            }
            Self.logSplitFallbackOnce(for: screen.displayID, side: "trailing")
            var position = rightArea.minX - screen.frame.minX
            if shouldInset {
                position += 4
                if info.trailing.trailingEndCap == .square {
                    position -= appearanceManager.menuBarInsetAmount
                }
            } else {
                position -= 7
            }
            let clamped = min(max(position, rect.minX), rect.maxX)
            guard clamped < rect.maxX else {
                return .zero
            }
            return CGRect(x: clamped, y: rect.minY, width: rect.maxX - clamped, height: rect.height)
        }()

        let hasLeading = leadingPathBounds != .zero
        let hasTrailing = trailingPathBounds != .zero

        if hasLeading, hasTrailing {
            if leadingPathBounds.intersects(trailingPathBounds) {
                // Genuinely crowded bar: fall back to a full-width shape.
                return shapePath(
                    in: rect,
                    leadingEndCap: info.leading.leadingEndCap,
                    trailingEndCap: info.trailing.trailingEndCap,
                    screen: screen
                )
            }
            let leadingPath = shapePath(
                in: leadingPathBounds,
                leadingEndCap: info.leading.leadingEndCap,
                trailingEndCap: info.leading.trailingEndCap,
                screen: screen
            )
            let trailingPath = shapePath(
                in: trailingPathBounds,
                leadingEndCap: info.trailing.leadingEndCap,
                trailingEndCap: info.trailing.trailingEndCap,
                screen: screen
            )
            let path = NSBezierPath()
            path.append(leadingPath)
            path.append(trailingPath)
            return path
        }
        // Only one side is known (the other is still resolving, e.g. the
        // trailing width on macOS 26+ where the CGS menu-bar-item list comes
        // back empty until the AX rescan lands). Draw just the known pill so
        // the rest of the bar keeps showing the wallpaper instead of
        // collapsing to a full-width tint, which paints the transparent gap
        // gray and makes tint/wallpaper look swapped.
        if hasLeading {
            return shapePath(
                in: leadingPathBounds,
                leadingEndCap: info.leading.leadingEndCap,
                trailingEndCap: info.leading.trailingEndCap,
                screen: screen
            )
        }
        if hasTrailing {
            return shapePath(
                in: trailingPathBounds,
                leadingEndCap: info.trailing.leadingEndCap,
                trailingEndCap: info.trailing.trailingEndCap,
                screen: screen
            )
        }
        // Nothing known yet: leave the whole bar as wallpaper.
        return NSBezierPath()
    }

    /// Returns the last-known trailing status width for the display without
    /// blocking. Kicks off a background rescan when the cached value is stale;
    /// the view redisplays when the rescan completes.
    /// ponytail: no per-frame easing here — the old 0.22/frame glide re-armed
    /// needsDisplay from inside draw() (~60fps redraw storm per toggle/scan).
    /// Draws now snap to the cached/predicted target; the background rescan
    /// corrects it once AX lands.
    private func cachedTrailingStatusWidth(for display: CGDirectDisplayID) -> CGFloat {
        seedPredictionIfNeeded(for: display)
        refreshTrailingStatusWidth(for: display, force: false)
        let target = Self.predictiveTarget[display] ?? Self.trailingWidthCache[display]?.width ?? 0
        guard let current = Self.displayedTrailingWidth[display] else {
            // First draw after boot/recreation: snap, never grow from 0.
            Self.displayedTrailingWidth[display] = target
            return target
        }
        if target >= current {
            // Expanding (show): snap, as before.
            Self.displayedTrailingWidth[display] = target
            return target
        }
        // Collapsing (hide): hold the current frame and let the 60Hz driver
        // glide it down to the target.
        startTrailingEaseIfNeeded()
        return current
    }

    /// Starts the 60Hz collapse driver, unless already running.
    private func startTrailingEaseIfNeeded() {
        guard trailingEaseTimer == nil else {
            return
        }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.stepTrailingEase()
        }
        RunLoop.main.add(timer, forMode: .common)
        trailingEaseTimer = timer
    }

    /// Advances the collapse animation one frame toward its target.
    private func stepTrailingEase() {
        guard let panel = overlayPanel else {
            trailingEaseTimer?.invalidate()
            trailingEaseTimer = nil
            return
        }
        let display = panel.owningScreen.displayID
        let target = Self.predictiveTarget[display] ?? Self.trailingWidthCache[display]?.width ?? 0
        let current = Self.displayedTrailingWidth[display] ?? target
        let next: CGFloat = if target >= current {
            target
        } else {
            max(target, current - Self.trailingCollapsePointsPerSecond / 60.0)
        }
        Self.displayedTrailingWidth[display] = next
        if next == target {
            trailingEaseTimer?.invalidate()
            trailingEaseTimer = nil
        }
        needsDisplay = true
    }

    /// A control item moved or toggled: redraw now and keep chaining scans
    /// briefly so the rescan confirms (and corrects) the prediction mid-slide.
    private func noteControlItemMoved() {
        needsDisplay = true
        guard let panel = overlayPanel else {
            return
        }
        let display = panel.owningScreen.displayID
        // Toggles alternate concealed <-> revealed: predict the destination
        // now instead of waiting ~1s for the AX rescan. Hide => shrink toward
        // the remembered concealed width; show => expand toward revealed.
        // Falls back to the opposite end when only one is known, so even the
        // very first toggle glides instead of jumping from 0.
        let concealed = isConcealed()
        if
            let remembered = Self.settledWidth(for: display, concealed: concealed),
            remembered > 0
        {
            Self.predictiveTarget[display] = remembered
        }
        Self.trailingBurstUntil[display] = Date().addingTimeInterval(1.5)
        refreshTrailingStatusWidth(for: display, force: true)
    }

    /// Kicks off a background trailing-width rescan unless one is already in
    /// flight. Completions redisplay and, while a toggle burst is active,
    /// chain the next scan.
    private func refreshTrailingStatusWidth(for display: CGDirectDisplayID, force: Bool) {
        let cached = Self.trailingWidthCache[display]
        let isStale = force || cached.map { Date().timeIntervalSince($0.date) > Self.trailingWidthTTL } ?? true
        guard isStale, !Self.trailingWidthScanInFlight.contains(display) else {
            return
        }
        Self.trailingWidthScanInFlight.insert(display)
        let concealed = isConcealed()
        // Never collapse to 0 while a stale-but-sane value exists: a
        // slightly wrong pill is far less jarring than a disappearing one.
        let previous = cached?.width ?? Self.settledWidth(for: display, concealed: concealed) ?? 0
        DispatchQueue.global(qos: .userInitiated).async {
            let width = Self.trailingStatusWidthFallback(for: display) ?? previous
            DispatchQueue.main.async { [weak self] in
                // Shared state first: the result survives even if this view
                // is gone (panel recreated mid-scan).
                Self.trailingWidthScanInFlight.remove(display)
                if Self.isStripOccluded(display: display) {
                    // A dropdown/panel is over the bar: the scan saw the panel,
                    // not the icons. Drop it so neither the cache nor the settled
                    // widths learn the occluded value; the pill holds its width.
                    self?.needsDisplay = true
                    return
                }
                Self.trailingWidthCache[display] = (width, Date())
                guard let self else {
                    return
                }
                self.needsDisplay = true
                if let until = Self.trailingBurstUntil[display], Date() < until {
                    self.refreshTrailingStatusWidth(for: display, force: true)
                } else {
                    Self.trailingBurstUntil.removeValue(forKey: display)
                    // Burst settled: this is the real end position. Remember
                    // it so the next toggle (and next launch) can predict
                    // instantly, and drop the prediction it was gliding toward.
                    // Re-read: the toggle may have flipped again mid-scan.
                    if width > 0 {
                        let fresh = self.isConcealed() ?? concealed
                        if fresh ?? true {
                            Self.settledConcealedWidth[display] = width
                        } else {
                            Self.settledRevealedWidth[display] = width
                        }
                        Self.persistTrailingWidths()
                    }
                    Self.predictiveTarget.removeValue(forKey: display)
                }
            }
        }
    }

    /// Whether a foreign window currently overlaps the menu bar strip.
    ///
    /// A dropdown/panel hanging over the bar corrupts AX width scans (probes
    /// hit the panel instead of the icons) and would retract the background
    /// mid-interaction. While occluded the pill may expand but its collapse is
    /// frozen; collapse resumes once focus leaves (panel closed). Steady state
    /// only ever shows the Menubar base and Ice's own overlay here, so both
    /// are excluded.
    private static func isStripOccluded(display: CGDirectDisplayID) -> Bool {
        let bounds = CGDisplayBounds(display)
        guard bounds.width > 0 else {
            return false
        }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == display }) else {
            return false
        }
        let barHeight = screen.frame.maxY - screen.visibleFrame.maxY
        guard barHeight > 0 else {
            return false
        }
        let strip = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: barHeight)
        let ownPID = NSRunningApplication.current.processIdentifier
        return WindowInfo.getOnScreenWindows(excludeDesktopWindows: true).contains { window in
            window.ownerPID != ownPID &&
            !window.isWindowServerWindow &&
            window.frame.intersects(strip)
        }
    }

    /// Whether an AX element at the given role/pid belongs to the trailing
    /// status cluster. App-menu items share the frontmost pid and are out.
    private static func isTrailingStatusElement(role: String?, pid: pid_t?, appMenuPid: pid_t?) -> Bool {
        // macOS 27 roles observed in the status cluster: AXGroup
        // (MenuBarAgent/ControlCenter), AXMenuBarItem, AXButton and AXImage
        // (third-party extras, screen-sharing/mirroring indicators).
        if role == "AXGroup" {
            return true
        }
        if role == "AXMenuBarItem" || role == "AXButton" || role == "AXImage" {
            return pid != nil && pid != appMenuPid
        }
        return false
    }

    /// Returns the frame of the status element at the given point, or `nil`
    /// when there is nothing status-like there.
    private static func statusFrameAt(
        x: CGFloat,
        y: Float,
        displayBounds: CGRect,
        appMenuPid: pid_t?
    ) -> CGRect? {
        guard let element = try? systemWideElement.elementAtPosition(Float(x), y) else {
            return nil
        }
        let role: String? = try? element.attribute("AXRole")
        if role == "AXMenuBar" {
            return nil
        }
        let frame: CGRect? = try? element.attribute("AXFrame")
        let pid: pid_t? = try? element.pid()
        guard
            isTrailingStatusElement(role: role, pid: pid, appMenuPid: appMenuPid),
            let frame,
            frame.width > 0, frame.height > 0, frame.height <= 50,
            frame.minY <= displayBounds.origin.y + 10
        else {
            return nil
        }
        return frame
    }

    /// Refines a coarse leftmost edge by sweeping the strip just left of it.
    ///
    /// The coarse 16pt single-row sweep can straddle a narrow glyph (or miss
    /// one whose hit area sits off the probed row, e.g. an active
    /// screen-sharing pill) and stop one icon too far right, leaving that
    /// icon floating off the pill. This bounded sweep (100pt, 8pt columns,
    /// three rows) catches the straggler. It stops after 24pt of empty strip
    /// so it can never jump the center gap into the application menu.
    private static func refineLeadingEdge(
        leftOf coarseX: CGFloat,
        displayBounds: CGRect,
        appMenuPid: pid_t?
    ) -> CGFloat {
        var leftmostX = coarseX
        var consecutiveMisses = 0
        var x = coarseX - 8
        let stopX = max(displayBounds.minX, coarseX - 100)
        let rows: [Float] = [
            Float(displayBounds.origin.y + 10),
            Float(displayBounds.origin.y + 16),
            Float(displayBounds.origin.y + 22),
        ]
        while x > stopX, consecutiveMisses < 3 {
            var found: CGRect?
            for y in rows {
                if let frame = statusFrameAt(x: x, y: y, displayBounds: displayBounds, appMenuPid: appMenuPid) {
                    found = frame
                    break
                }
            }
            if let found {
                leftmostX = min(leftmostX, found.minX)
                consecutiveMisses = 0
                // Skip past the found element, like the coarse sweep.
                x = min(found.minX - 2, x - 8)
            } else {
                consecutiveMisses += 1
                x -= 8
            }
        }
        return leftmostX
    }

    /// Verifies the currently drawn edge with a few AX probes: status just
    /// inside it, wallpaper just outside it.
    ///
    /// Returns `false` when icons appeared/removed past the edge. Open menus
    /// covering the bar read as transient overlay and count as valid, so a
    /// menu never triggers a rescan war.
    private static func validateTrailingEdge(
        expectedWidth: CGFloat,
        displayBounds: CGRect,
        appMenuPid: pid_t?
    ) -> Bool {
        let edgeX = displayBounds.maxX - expectedWidth
        guard edgeX > displayBounds.minX + 20 else {
            // Nearly full bar — the full sweep owns this case.
            return true
        }
        let rows: [Float] = [
            Float(displayBounds.origin.y + 16),
            Float(displayBounds.origin.y + 10),
        ]
        var insideHit = false
        for y in rows {
            guard let element = try? systemWideElement.elementAtPosition(
                Float(min(edgeX + 6, displayBounds.maxX - 2)),
                y
            ) else {
                continue
            }
            let role: String? = try? element.attribute("AXRole")
            if role == "AXMenu" || role == "AXMenuItem" {
                return true
            }
            if role == "AXMenuBar" {
                continue
            }
            let pid: pid_t? = try? element.pid()
            guard isTrailingStatusElement(role: role, pid: pid, appMenuPid: appMenuPid) else {
                continue
            }
            let frame: CGRect? = try? element.attribute("AXFrame")
            if
                let frame,
                frame.width > 0, frame.height > 0, frame.height <= 50,
                frame.minY <= displayBounds.origin.y + 10
            {
                insideHit = true
                break
            }
        }
        guard insideHit else {
            return false
        }
        // Outside must be empty. The pill pads 10pt past the AX frame, so
        // 16/28pt out is clear wallpaper when the edge is right.
        for dx: CGFloat in [16, 28] {
            let ox = edgeX - dx
            if ox <= displayBounds.minX {
                break
            }
            for y in rows where statusFrameAt(x: ox, y: y, displayBounds: displayBounds, appMenuPid: appMenuPid) != nil {
                return false
            }
        }
        return true
    }

    /// Fast-path edge check; runs on a timer and on app launch/terminate.
    ///
    /// On mismatch it kicks a short burst + forced rescan so the pill heals
    /// in ~1s. On match it just touches the cache timestamp, which also keeps
    /// the draw-path backstop from firing redundant full sweeps — steady
    /// state costs ~10 AX probes/s instead of a full sweep every TTL.
    private func checkTrailingEdge() {
        guard
            let panel = overlayPanel,
            let appState = panel.appState,
            !appState.isPreview,
            !appState.menuBarManager.isMenuBarHiddenBySystem,
            !appState.isActiveSpaceFullscreen
        else {
            return
        }
        let display = panel.owningScreen.displayID
        guard
            !Self.trailingWidthScanInFlight.contains(display),
            Self.trailingBurstUntil[display].map({ Date() >= $0 }) ?? true
        else {
            // A scan or toggle burst already owns the edge.
            return
        }
        let displayBounds = CGDisplayBounds(display)
        guard displayBounds.width > 0 else {
            return
        }
        let expected = Self.predictiveTarget[display]
            ?? Self.trailingWidthCache[display]?.width
            ?? Self.settledWidth(for: display, concealed: isConcealed())
            ?? 0
        guard expected > 0 else {
            refreshTrailingStatusWidth(for: display, force: false)
            return
        }
        let y = Float(displayBounds.origin.y + 16)
        let appMenuPid: pid_t? = try? systemWideElement.elementAtPosition(
            Float(displayBounds.origin.x + 2),
            y
        )?.pid()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let valid = Self.validateTrailingEdge(
                expectedWidth: expected,
                displayBounds: displayBounds,
                appMenuPid: appMenuPid
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                if valid {
                    if Self.trailingWidthCache[display] != nil {
                        Self.trailingWidthCache[display]?.date = Date()
                    }
                } else if !Self.isStripOccluded(display: display) {
                    Self.trailingBurstUntil[display] = Date().addingTimeInterval(1.0)
                    self.needsDisplay = true
                    self.refreshTrailingStatusWidth(for: display, force: true)
                }
                // Else: a dropdown/panel is over the bar — hold the pill until
                // it leaves instead of rescanning toward the occluded width.
            }
        }
    }

    /// Estimates the width of the trailing status-item cluster using Accessibility.
    ///
    /// On macOS 27, `CGSGetProcessMenuBarWindowList` returns only the Menubar
    /// itself, so `MenuBarItem.getMenuBarItems` comes back empty and split
    /// shapes collapse to full. This scans the top strip from right to left
    /// and returns the distance from the right edge to the leftmost status
    /// element. Returns `nil` when nothing status-like is found.
    ///
    /// - ponytail: O(n) AX scan per call; always call via cachedTrailingStatusWidth
    ///   (background + TTL), never directly from draw.
    private static func trailingStatusWidthFallback(for display: CGDirectDisplayID) -> CGFloat? {
        let displayBounds = CGDisplayBounds(display)
        guard displayBounds.width > 0 else {
            return nil
        }
        let y = Float(displayBounds.origin.y + 16)
        // Middle of the (now 33pt on macOS 27) bar hits items reliably;
        // the top edge can return the WindowManager glass container instead.
        let appMenuPid: pid_t? = (try? systemWideElement.elementAtPosition(
            Float(displayBounds.origin.x + 2),
            y
        )?.pid())

        var leftmostX: CGFloat?
        // Status cluster lives at the right edge; 800pt covers even wide clusters.
        // Scan the whole window: some third-party items report their parent
        // AXMenuBar instead of a button, so early-exit on gaps stops too soon.
        // Step 16pt stays below the narrowest icon (~20pt) so nothing is
        // skipped, but cuts AX round-trips ~40% vs 10pt — the scan, not the
        // animation, was the ~1s lag behind the icons. A bounded fine sweep
        // below fixes up whatever the coarse step straddles.
        let step: CGFloat = 16
        var x = displayBounds.maxX - 2
        let stopX = max(displayBounds.minX, displayBounds.maxX - 800)
        while x > stopX {
            guard let frame = statusFrameAt(x: x, y: y, displayBounds: displayBounds, appMenuPid: appMenuPid) else {
                x -= step
                continue
            }
            leftmostX = min(leftmostX ?? frame.minX, frame.minX)
            // Skip past this element to cut down on AX calls.
            // min() guarantees progress when the frame edge lands on x.
            x = min(frame.minX - 2, x - step)
            continue
        }
        guard let coarseX = leftmostX else {
            return nil
        }
        // Fine sweep for a narrow/off-row straggler left of the coarse edge
        // (e.g. an active screen-sharing pill), then pad left so the pill
        // tucks under system-drawn active backgrounds that run wider than
        // their AX frame. Over-covering wallpaper by a few points is
        // invisible; leaving an icon off the pill is not.
        let refinedX = refineLeadingEdge(leftOf: coarseX, displayBounds: displayBounds, appMenuPid: appMenuPid)
        leftmostX = max(displayBounds.minX, refinedX - 10)
        guard let leftmostX else {
            return nil
        }
        let width = displayBounds.maxX - leftmostX
        guard width > 0 else {
            return nil
        }
        // The sweep only covers the trailing 800pt. A width pinned at that
        // cap means the scan swallowed a glass container (or a cluster wider
        // than the scan window) — treat it as unknown so split doesn't paint
        // an over-wide pill over the transparent gap.
        let scanWindow = min(displayBounds.width, 800)
        guard width < scanWindow - 10 else {
            return nil
        }
        Logger.overlayPanel.debug("Trailing scan: coarse=\(coarseX) refined=\(refinedX) width=\(width)")
        return width
    }

    /// Returns the bounds that the view's drawn content can occupy.
    private func getDrawableBounds() -> CGRect {
        return CGRect(
            x: bounds.origin.x,
            y: bounds.origin.y + 5,
            width: bounds.width,
            height: bounds.height - 5
        )
    }

    /// Syncs the blur and tint layers with the given shape.
    private func updateChrome(with shapePath: NSBezierPath, fillRect: CGRect, shapeKind: MenuBarShapeKind) {
        if blurView.frame != bounds {
            blurView.frame = bounds
        }
        if tintView.frame != bounds {
            tintView.frame = bounds
        }
        let isEmpty = shapePath.isEmpty
        // Blur only matters when enabled and visible through the tint.
        // NSVisualEffectView has no radius API, so the amount drives the
        // layer opacity: it fades between fully blurred and the sharp live
        // background, which reads as blur strength.
        blurView.isHidden = configuration.blurAmount <= 0
            || isEmpty
            || (configuration.tintKind != .none && configuration.tintOpacity >= 1)
        blurView.alphaValue = configuration.blurAmount
        blurMask.frame = blurView.bounds
        blurMask.path = shapePath.cgPath
        tintView.shapePath = shapePath
        tintView.fillRect = fillRect
        tintView.shapeKind = shapeKind
        tintView.tintKind = configuration.tintKind
        tintView.tintColor = configuration.tintColor
        tintView.tintGradient = configuration.tintGradient
        tintView.tintOpacity = configuration.tintOpacity
        tintView.hasBorder = configuration.hasBorder
        tintView.borderColor = configuration.borderColor
        tintView.borderWidth = configuration.borderWidth
        tintView.isHidden = isEmpty || (configuration.tintKind == .none && !configuration.hasBorder)
        tintView.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard
            let overlayPanel,
            let context = NSGraphicsContext.current
        else {
            return
        }

        let drawableBounds = getDrawableBounds()

        let shapePath = switch fullConfiguration.shapeKind {
        case .none:
            NSBezierPath(rect: drawableBounds)
        case .full:
            pathForFullShape(
                in: drawableBounds,
                info: fullConfiguration.fullShapeInfo,
                isInset: fullConfiguration.isInset,
                screen: overlayPanel.owningScreen
            )
        case .split:
            pathForSplitShape(
                in: drawableBounds,
                info: fullConfiguration.splitShapeInfo,
                isInset: fullConfiguration.isInset,
                screen: overlayPanel.owningScreen
            )
        }

        switch fullConfiguration.shapeKind {
        case .none:
            if configuration.hasShadow {
                let gradient = NSGradient(
                    colors: [
                        NSColor(white: 0.0, alpha: 0.0),
                        NSColor(white: 0.0, alpha: 0.2),
                    ]
                )
                let shadowBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: 5
                )
                gradient?.draw(in: shadowBounds, angle: 90)
            }
        case .full, .split:
            // Nothing is drawn outside the shape: the panel is transparent
            // there, so the live background shows through.
            if configuration.hasShadow {
                context.saveGraphicsState()
                defer {
                    context.restoreGraphicsState()
                }

                let shadowClipPath = NSBezierPath(rect: bounds)
                shadowClipPath.append(shapePath.reversed)
                shadowClipPath.setClip()

                shapePath.drawShadow(color: .black.withAlphaComponent(0.5), radius: 5)
            }
        }

        // Tint and border live in layers above the blur; sync them here.
        updateChrome(with: shapePath, fillRect: drawableBounds, shapeKind: fullConfiguration.shapeKind)
    }
}

// MARK: - Tint View

/// Draws the pill tint (and border) above the blur layer.
private final class MenuBarTintView: NSView {
    var shapePath = NSBezierPath()
    var fillRect = CGRect.zero
    var shapeKind = MenuBarShapeKind.none
    var tintKind = MenuBarTintKind.none
    var tintColor: CGColor = NSColor.black.cgColor
    var tintGradient = CustomGradient.defaultMenuBarTint
    var tintOpacity = 1.0
    var hasBorder = false
    var borderColor: CGColor = NSColor.black.cgColor
    var borderWidth = 1.0

    override func draw(_ dirtyRect: NSRect) {
        guard
            !shapePath.isEmpty,
            let context = NSGraphicsContext.current
        else {
            return
        }

        context.saveGraphicsState()
        shapePath.setClip()

        switch tintKind {
        case .none:
            break
        case .solid:
            if let tintColor = NSColor(cgColor: tintColor)?.withAlphaComponent(tintOpacity) {
                tintColor.setFill()
                fillRect.fill()
            }
        case .gradient:
            if let tintGradient = tintGradient.withAlphaComponent(tintOpacity).nsGradient {
                tintGradient.draw(in: fillRect, angle: 0)
            }
        }

        context.restoreGraphicsState()

        if hasBorder {
            switch shapeKind {
            case .none:
                let borderBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY + 5,
                    width: bounds.width,
                    height: borderWidth
                )
                NSColor(cgColor: borderColor)?.setFill()
                NSBezierPath(rect: borderBounds).fill()
            case .full, .split:
                guard let borderColor = NSColor(cgColor: borderColor) else {
                    return
                }
                context.saveGraphicsState()
                defer {
                    context.restoreGraphicsState()
                }

                // HACK: Insetting a path to get an "inside" stroke is surprisingly
                // difficult. We can fake the correct line width by doubling it, as
                // anything outside the shape path will be clipped.
                shapePath.lineWidth = borderWidth * 2
                shapePath.setClip()

                borderColor.setStroke()
                shapePath.stroke()
            }
        }
    }
}

// MARK: - Logger
private extension Logger {
    static let overlayPanel = Logger(category: "MenuBarOverlayPanel")
}
