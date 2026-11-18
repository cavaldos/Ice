//
//  IceBarItemMemory.swift
//  Ice
//

import Cocoa

/// Remembers which menu bar items sit in the hidden sections, for the Ice Bar.
///
/// On macOS 27 an item in a hidden section leaves the bar entirely: its app
/// reports no `AXExtrasMenuBar` at all, and Ice's dividers aren't drawn either
/// (measured on macOS 27.2). The Ice Bar therefore can't read the sections while
/// they are hidden. They are learned whenever the Ice Bar reveals the sections
/// and remembered across launches.
enum IceBarItemMemory {
    /// A remembered item.
    struct Entry: Codable, Hashable {
        /// Identity of the item across scans; see ``keyedItems(_:)``.
        let key: String
        let bundleID: String
        let identifier: String?
        let title: String?
        /// 1 hidden, 2 always hidden.
        let section: Int
        /// Horizontal position when learned, to keep menu bar order.
        let order: Double

        var sectionName: MenuBarSection.Name {
            section == 2 ? .alwaysHidden : .hidden
        }

        var displayName: String {
            title ?? identifier ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
        }
    }

    private static let defaultsKey = "IceBarRememberedItems"

    /// The remembered items, in menu bar order.
    static var entries: [Entry] {
        get {
            guard
                let data = UserDefaults.standard.data(forKey: defaultsKey),
                let entries = try? JSONDecoder().decode([Entry].self, from: data)
            else {
                return []
            }
            return entries.sorted { $0.order < $1.order }
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: defaultsKey)
            }
        }
    }

    /// Pairs each item with a key that stays the same across scans: bundle
    /// identifier, `AXIdentifier`, and the item's rank among its app's items
    /// sharing that identifier. Titles are left out, as many change (Wi-Fi
    /// strength, clock, input source…).
    static func keyedItems(_ items: [MenuBarItemAXDiscovery.AXMenuBarItem]) -> [(key: String, item: MenuBarItemAXDiscovery.AXMenuBarItem)] {
        let ordered = items.sorted {
            ($0.axFrame?.midX ?? .greatestFiniteMagnitude) < ($1.axFrame?.midX ?? .greatestFiniteMagnitude)
        }
        var counts = [String: Int]()
        return ordered.compactMap { item in
            guard let bundleID = item.bundleID else {
                return nil
            }
            let base = "\(bundleID)|\(item.identifier ?? "")"
            let n = counts[base, default: 0]
            counts[base] = n + 1
            return ("\(base)#\(n)", item)
        }
    }

    /// Whether a frame (AX coordinates) is drawn in some display's menu bar.
    static func isDrawnInMenuBar(_ frame: CGRect?) -> Bool {
        guard let frame, frame.width > 0, frame.minX.isFinite, frame.minY.isFinite else {
            return false
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.contains { screen in
            let bounds = CGDisplayBounds(screen.displayID)
            return bounds.contains(center) && center.y < bounds.minY + 40
        }
    }

    /// Learns the sections from a scan taken while they are revealed.
    ///
    /// - Parameters:
    ///   - items: Every item discovered while the sections are revealed.
    ///   - hiddenDividerX: Left edge of the settled Hidden divider.
    ///   - alwaysHiddenDividerX: Left edge of the settled Always-Hidden divider,
    ///     nil when that section is disabled or unreadable (its entries are kept).
    static func learn(
        from items: [MenuBarItemAXDiscovery.AXMenuBarItem],
        hiddenDividerX: CGFloat,
        alwaysHiddenDividerX: CGFloat?
    ) {
        let keyed = keyedItems(items)
        let foundKeys = Set(keyed.map(\.key))
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

        var learned = entries
        // A running app's entry in a revealed section is replaced by what the
        // bar shows now; entries of apps that aren't running are kept for later.
        learned.removeAll { entry in
            foundKeys.contains(entry.key) || (
                running.contains(entry.bundleID) &&
                (entry.section == 1 || alwaysHiddenDividerX != nil)
            )
        }
        for (key, item) in keyed {
            guard let bundleID = item.bundleID, isDrawnInMenuBar(item.axFrame), let frame = item.axFrame else {
                continue
            }
            let section = switch MenuBarItemAXDiscovery.classify(
                centerX: frame.midX,
                hiddenDividerX: hiddenDividerX,
                alwaysHiddenDividerX: alwaysHiddenDividerX
            ) {
            case .alwaysHidden: 2
            case .hidden: 1
            case .visible: 0
            }
            guard section != 0 else {
                continue
            }
            learned.append(
                Entry(
                    key: key,
                    bundleID: bundleID,
                    identifier: item.identifier,
                    title: item.title,
                    section: section,
                    order: Double(frame.midX)
                )
            )
        }
        entries = learned
    }

    /// The live item matching an entry, if it is in the given scan.
    static func match(_ entry: Entry, in items: [MenuBarItemAXDiscovery.AXMenuBarItem]) -> MenuBarItemAXDiscovery.AXMenuBarItem? {
        let keyed = keyedItems(items)
        if let exact = keyed.first(where: { $0.key == entry.key }) {
            return exact.item
        }
        // The rank can shift when the app adds or drops an item.
        return keyed.first {
            $0.item.bundleID == entry.bundleID && $0.item.identifier == entry.identifier
        }?.item
    }
}
