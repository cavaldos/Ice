//
//  ControlItem.swift
//  Ice
//

import Cocoa
import Combine

/// A status item that controls a section in the menu bar.
@MainActor
final class ControlItem {
    /// Possible identifiers for control items.
    enum Identifier: String, CaseIterable {
        case iceIcon = "SItem"
        case hidden = "HItem"
        case alwaysHidden = "AHItem"
    }

    /// Possible hiding states for control items.
    enum HidingState {
        case hideItems, showItems
    }

    /// Possible lengths for control items.
    enum Lengths {
        static let standard: CGFloat = NSStatusItem.variableLength
        static let expanded: CGFloat = 10_000
    }

    /// Length of an expanded hiding spacer.
    ///
    /// On macOS 27, a spacer wider than the native status region is discarded
    /// instead of pushing its neighbours into overflow (jordanbaird/Ice#980),
    /// so the width is fitted inside the region. Older systems keep the
    /// 10 000 trick.
    private func expandedHidingLength() -> CGFloat {
        if #available(macOS 27, *) {
            let screen = window?.screen ?? NSScreen.main
            let regionWidth: CGFloat
            if let rightArea = screen?.auxiliaryTopRightArea {
                regionWidth = rightArea.width
            } else if let screen {
                let appMenuWidth = appState?.menuBarManager.getApplicationMenuFrame(for: screen.displayID)?.width ?? 300
                regionWidth = screen.frame.width - appMenuWidth
            } else {
                regionWidth = 0
            }
            if regionWidth.isFinite, regionWidth > 64 {
                return max(32, regionWidth - 32)
            }
            // ponytail: fallback guess inside any real status region; exact fit recomputed on next toggle
            return 1_000
        }
        return Lengths.expanded
    }

    /// The control item's hiding state (`@Published`).
    @Published var state = HidingState.hideItems

    /// A Boolean value that indicates whether the control item is visible (`@Published`).
    @Published var isVisible = true

    /// The frame of the control item's window (`@Published`).
    @Published private(set) var windowFrame: CGRect?

    /// The shared app state.
    private weak var appState: AppState?

    /// The control item's underlying status item.
    private let statusItem: NSStatusItem

    /// A horizontal constraint for the control item's content view.
    private let constraint: NSLayoutConstraint?

    /// The control item's identifier.
    private let identifier: Identifier

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The menu bar section associated with the control item.
    private weak var section: MenuBarSection? {
        appState?.menuBarManager.sections.first { $0.controlItem === self }
    }

    /// The control item's window.
    var window: NSWindow? {
        statusItem.button?.window
    }

    /// The identifier of the control item's window.
    var windowID: CGWindowID? {
        guard let window else {
            return nil
        }
        // windowNumber is Int and traps on overflow with the non-failable
        // initializer on macOS 26 (see jordanbaird/Ice#580, #977).
        return CGWindowID(exactly: window.windowNumber)
    }

    /// A Boolean value that indicates whether the control item serves as
    /// a divider between sections.
    var isSectionDivider: Bool {
        identifier != .iceIcon
    }

    /// A Boolean value that indicates whether the control item is currently
    /// displayed in the menu bar.
    var isAddedToMenuBar: Bool {
        statusItem.isVisible
    }

    /// Creates a control item with the given identifier and app state.
    init(identifier: Identifier, appState: AppState) {
        let autosaveName = identifier.rawValue

        // If the status item doesn't have a preferred position, set it
        // according to the identifier.
        if StatusItemDefaults[.preferredPosition, autosaveName] == nil {
            switch identifier {
            case .iceIcon:
                StatusItemDefaults[.preferredPosition, autosaveName] = 0
            case .hidden:
                StatusItemDefaults[.preferredPosition, autosaveName] = 1
            case .alwaysHidden:
                // Lower values sit further right, so the always-hidden
                // divider defaults left of the hidden divider. On macOS 27
                // per-item windows are gone and nothing can auto-arrange
                // the dividers, so a correct initial position is the only
                // thing keeping the sections in the right order.
                StatusItemDefaults[.preferredPosition, autosaveName] = 2
            }
        }

        self.statusItem = NSStatusBar.system.statusItem(withLength: 0)
        self.statusItem.autosaveName = autosaveName
        self.identifier = identifier
        self.appState = appState

        // This could break in a new macOS release, but we need this constraint in order to be
        // able to hide the control item when the `ShowSectionDividers` setting is disabled. A
        // previous implementation used the status item's `isVisible` property, which was more
        // robust, but would completely remove the control item. With the current set of
        // features, we need to be able to accurately retrieve the items for each section, so
        // we need the control item to always be present to act as a delimiter. The new solution
        // is to remove the constraint that prevents status items from having a length of zero,
        // then resize the content view. FIXME: Find a replacement for this.
        if
            let button = statusItem.button,
            let constraints = button.window?.contentView?.constraintsAffectingLayout(for: .horizontal),
            let constraint = constraints.first(where: Predicates.controlItemConstraint(button: button))
        {
            assert(constraints.filter(Predicates.controlItemConstraint(button: button)).count == 1)
            self.constraint = constraint
        } else {
            self.constraint = nil
        }

        configureStatusItem()
    }

    /// Removes the status item without clearing its stored position.
    deinit {
        // Removing the status item has the unwanted side effect of deleting
        // the preferredPosition. Cache and restore it.
        let autosaveName = statusItem.autosaveName as String
        let cached = StatusItemDefaults[.preferredPosition, autosaveName]
        NSStatusBar.system.removeStatusItem(statusItem)
        StatusItemDefaults[.preferredPosition, autosaveName] = cached
    }

    /// Configures the internal observers for the control item.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        $state
            .sink { [weak self] state in
                self?.updateStatusItem(with: state)
            }
            .store(in: &c)

        Publishers.CombineLatest($isVisible, $state)
            .sink { [weak self] (isVisible, state) in
                guard
                    let self,
                    let section
                else {
                    return
                }
                if isVisible {
                    statusItem.length = switch section.name {
                    case .visible: Lengths.standard
                    case .hidden, .alwaysHidden:
                        switch state {
                        case .hideItems: expandedHidingLength()
                        case .showItems: Lengths.standard
                        }
                    }
                    constraint?.isActive = true
                } else {
                    statusItem.length = 0
                    constraint?.isActive = false
                    if let window {
                        var size = window.frame.size
                        size.width = 1
                        window.setContentSize(size)
                    }
                }
            }
            .store(in: &c)

        constraint?.publisher(for: \.isActive)
            .removeDuplicates()
            .sink { [weak self] isActive in
                self?.isVisible = isActive
            }
            .store(in: &c)

        statusItem.publisher(for: \.isVisible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isVisible in
                guard
                    let self,
                    let appState,
                    let section
                else {
                    return
                }

                let manager = appState.settingsManager.hotkeySettingsManager

                let hotkey: Hotkey? = switch section.name {
                case .visible: nil
                case .hidden: manager.hotkey(withAction: .toggleHiddenSection)
                case .alwaysHidden: manager.hotkey(withAction: .toggleAlwaysHiddenSection)
                }

                guard let hotkey else {
                    return
                }

                if isVisible {
                    hotkey.enable()
                } else {
                    hotkey.disable()
                }
            }
            .store(in: &c)

        window?.publisher(for: \.frame)
            .sink { [weak self] frame in
                guard
                    let self,
                    let screen = window?.screen,
                    screen.frame.intersects(frame)
                else {
                    return
                }
                windowFrame = frame
            }
            .store(in: &c)

        if let appState {
            appState.settingsManager.generalSettingsManager.$showIceIcon
                .receive(on: DispatchQueue.main)
                .sink { [weak self] showIceIcon in
                    guard
                        let self,
                        !isSectionDivider
                    else {
                        return
                    }
                    if showIceIcon {
                        addToMenuBar()
                    } else {
                        removeFromMenuBar()
                    }
                }
                .store(in: &c)

            appState.settingsManager.generalSettingsManager.$iceIcon
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else {
                        return
                    }
                    updateStatusItem(with: state)
                }
                .store(in: &c)

            appState.settingsManager.generalSettingsManager.$customIceIconIsTemplate
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else {
                        return
                    }
                    updateStatusItem(with: state)
                }
                .store(in: &c)

            appState.settingsManager.generalSettingsManager.$reverseIceIcon
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else {
                        return
                    }
                    updateStatusItem(with: state)
                }
                .store(in: &c)

            appState.settingsManager.generalSettingsManager.$useIceBar
                .receive(on: DispatchQueue.main)
                .sink { [weak self] useIceBar in
                    guard
                        let self,
                        let button = statusItem.button
                    else {
                        return
                    }
                    if useIceBar {
                        button.sendAction(on: [.leftMouseDown, .rightMouseUp])
                    } else {
                        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                    }
                }
                .store(in: &c)

            appState.settingsManager.advancedSettingsManager.$showSectionDividers
                .receive(on: DispatchQueue.main)
                .sink { [weak self] shouldShow in
                    guard
                        let self,
                        isSectionDivider,
                        state == .showItems
                    else {
                        return
                    }
                    isVisible = shouldShow
                }
                .store(in: &c)

            appState.settingsManager.advancedSettingsManager.$enableAlwaysHiddenSection
                .receive(on: DispatchQueue.main)
                .sink { [weak self] enable in
                    guard
                        let self,
                        identifier == .alwaysHidden,
                        let visibleSection = appState.menuBarManager.section(withName: .visible)
                    else {
                        return
                    }
                    if enable {
                        addToMenuBar()
                    } else {
                        removeFromMenuBar()
                    }
                    // The Ice icon mirrors this section; repaint its arrow
                    // now that the source has changed.
                    visibleSection.controlItem.updateStatusItem(with: visibleSection.controlItem.state)
                }
                .store(in: &c)
        }

        cancellables = c
    }

    /// Sets the initial configuration for the status item.
    private func configureStatusItem() {
        defer {
            configureCancellables()
            updateStatusItem(with: state)
        }
        guard let button = statusItem.button else {
            return
        }
        button.target = self
        button.action = #selector(performAction)
        // Định danh AX cho vạch chia để tra vị trí qua Accessibility
        // (MenuBarItemAXDiscovery.dividerFrames): trên macOS 27
        // button.window.frame trả về rect của spacer chứ không phải vị trí
        // chevron, nên Ice Bar không thể dùng nó để phân loại section.
        switch identifier {
        case .hidden:
            button.setAccessibilityIdentifier("IceHiddenDivider")
        case .alwaysHidden:
            button.setAccessibilityIdentifier("IceAlwaysHiddenDivider")
        case .iceIcon:
            break
        }
    }

    /// Updates the appearance of the status item using the given hiding state.
    func updateStatusItem(with state: HidingState) {
        guard
            let appState,
            let section,
            let button = statusItem.button
        else {
            return
        }

        switch section.name {
        case .visible:
            isVisible = true
            // Enable the cell, as it may have been previously disabled.
            button.cell?.isEnabled = true
            let icon = appState.settingsManager.generalSettingsManager.iceIcon
            let reversed = appState.settingsManager.generalSettingsManager.reverseIceIcon
            let hiddenImage = reversed ? icon.visible : icon.hidden
            let visibleImage = reversed ? icon.hidden : icon.visible
            // Closed points right like a collapsed disclosure; open points
            // left toward the revealed items, matching the section dividers.
            // The arrow mirrors the always-hidden section while it is enabled;
            // otherwise it mirrors this section.
            let alwaysHiddenSection = appState.menuBarManager.section(withName: .alwaysHidden)
            let showsOpenArrow = if alwaysHiddenSection?.isEnabled == true {
                alwaysHiddenSection?.controlItem.state == .showItems
            } else {
                state == .showItems
            }
            button.image = showsOpenArrow ? hiddenImage.nsImage(for: appState) : visibleImage.nsImage(for: appState)
            if
                case .custom = icon.name,
                let originalImage = button.image
            {
                // Custom icons need to be resized to fit inside the button.
                let originalWidth = originalImage.size.width
                let originalHeight = originalImage.size.height
                let ratio = max(originalWidth / 25, originalHeight / 17)
                let newSize = CGSize(width: originalWidth / ratio, height: originalHeight / ratio)
                button.image = originalImage.resized(to: newSize)
            }
        case .hidden, .alwaysHidden:
            switch state {
            case .hideItems:
                isVisible = true
                // Prevent the cell from highlighting while expanded.
                button.cell?.isEnabled = false
                // Cell still sometimes briefly flashes on expansion unless manually unhighlighted.
                button.isHighlighted = false
                button.image = nil
            case .showItems:
                isVisible = appState.settingsManager.advancedSettingsManager.showSectionDividers
                // Enable the cell, as it may have been previously disabled.
                button.cell?.isEnabled = true
                // Set the image based on the section name and the hiding state.
                switch section.name {
                case .hidden:
                    button.image = ControlItemImage.builtin(.chevronLarge).nsImage(for: appState)
                case .alwaysHidden:
                    button.image = ControlItemImage.builtin(.chevronSmall).nsImage(for: appState)
                case .visible: break
                }
            }
        }
    }

    /// Performs the control item's action.
    @objc private func performAction() {
        guard
            let appState,
            let event = NSApp.currentEvent
        else {
            return
        }
        switch event.type {
        case .leftMouseDown, .leftMouseUp:
            if NSEvent.modifierFlags == .control {
                statusItem.showMenu(createMenu(with: appState))
            } else if
                NSEvent.modifierFlags == .option,
                appState.settingsManager.advancedSettingsManager.canToggleAlwaysHiddenSection
            {
                if let alwaysHiddenSection = appState.menuBarManager.section(withName: .alwaysHidden) {
                    alwaysHiddenSection.toggle()
                }
            } else if
                identifier == .iceIcon,
                let alwaysHiddenSection = appState.menuBarManager.section(withName: .alwaysHidden),
                alwaysHiddenSection.isEnabled
            {
                // The Ice icon drives the always-hidden section, leaving the
                // hidden section untouched (it is driven by click/hover/scroll
                // on empty menu bar space, its divider, or its hotkey).
                alwaysHiddenSection.toggle()
            } else {
                section?.toggle()
            }
        case .rightMouseUp:
            statusItem.showMenu(createMenu(with: appState))
        default:
            break
        }
    }

    /// Creates a menu to show under the control item.
    private func createMenu(with appState: AppState) -> NSMenu {
        func hotkey(withAction action: HotkeyAction) -> Hotkey? {
            let hotkeySettingsManager = appState.settingsManager.hotkeySettingsManager
            return hotkeySettingsManager.hotkey(withAction: action)
        }

        let menu = NSMenu(title: "Ice")

        let settingsItem = NSMenuItem(
            title: "Ice Settings…",
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // Add menu items to toggle the hidden and always-hidden sections.
        let sectionNames: [MenuBarSection.Name] = [.hidden, .alwaysHidden]
        for name in sectionNames {
            guard
                let section = appState.menuBarManager.section(withName: name),
                section.controlItem.isAddedToMenuBar
            else {
                // Section doesn't exist, or is disabled.
                continue
            }
            let item = NSMenuItem(
                title: "\(section.isHidden ? "Show" : "Hide") the \(name.displayString) Section",
                action: #selector(toggleMenuBarSection),
                keyEquivalent: ""
            )
            item.target = self
            Self.sectionStorage.weakSet(section, for: item)
            switch name {
            case .visible:
                break
            case .hidden:
                if
                    let hotkey = hotkey(withAction: .toggleHiddenSection),
                    let keyCombination = hotkey.keyCombination
                {
                    item.keyEquivalent = keyCombination.key.keyEquivalent
                    item.keyEquivalentModifierMask = keyCombination.modifiers.nsEventFlags
                }
            case .alwaysHidden:
                if
                    let hotkey = hotkey(withAction: .toggleAlwaysHiddenSection),
                    let keyCombination = hotkey.keyCombination
                {
                    item.keyEquivalent = keyCombination.key.keyEquivalent
                    item.keyEquivalentModifierMask = keyCombination.modifiers.nsEventFlags
                }
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = self
        menu.addItem(checkForUpdatesItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Ice",
            action: #selector(NSApp.terminate),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)

        return menu
    }

    /// Toggles the menu bar section associated with the given menu item.
    @objc private func toggleMenuBarSection(for menuItem: NSMenuItem) {
        Self.sectionStorage.value(for: menuItem)?.toggle()
    }

    /// Opens the settings window and checks for app updates.
    @objc private func checkForUpdates() {
        guard let appState else {
            return
        }
        appState.updatesManager.checkForUpdates()
    }

    /// Adds the control item to the menu bar.
    func addToMenuBar() {
        guard !isAddedToMenuBar else {
            return
        }
        statusItem.isVisible = true
    }

    /// Removes the control item from the menu bar.
    func removeFromMenuBar() {
        guard isAddedToMenuBar else {
            return
        }
        // Setting `statusItem.isVisible` to `false` has the unwanted side
        // effect of deleting the preferredPosition. Cache and restore it.
        let autosaveName = statusItem.autosaveName as String
        let cached = StatusItemDefaults[.preferredPosition, autosaveName]
        statusItem.isVisible = false
        StatusItemDefaults[.preferredPosition, autosaveName] = cached
    }
}

private extension ControlItem {
    /// Storage for menu items that toggle a menu bar section.
    ///
    /// When one of these menu items is created, its section is stored here.
    /// When its action is invoked, the section is retrieved from storage.
    static let sectionStorage = ObjectStorage<MenuBarSection>()
}

// MARK: - Logger
private extension Logger {
    /// The logger to use for control items.
    static let controlItem = Logger(category: "ControlItem")
}
