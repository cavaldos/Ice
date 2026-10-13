// Runs the production rescan and row builder against nonempty native caches.
import Foundation
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().path
let pane = try String(contentsOfFile: repo + "/Ice/Settings/SettingsPanes/MenuBarLayoutSettingsPane.swift", encoding: .utf8)
let mover = try String(contentsOfFile: repo + "/Ice/MenuBar/MenuBarItems/MenuBarItemAXMover.swift", encoding: .utf8)
let discovery = try String(contentsOfFile: repo + "/Ice/MenuBar/MenuBarItems/MenuBarItemAXDiscovery.swift", encoding: .utf8)
func method(_ source: String, _ signature: String) -> String {
    let start = source.range(of: signature)!.lowerBound
    let end = source.range(of: "\n    }\n", range: start..<source.endIndex)!.upperBound
    return String(source[start..<end]).replacingOccurrences(of: "private func", with: "func")
}
let methods = ["    private func rescanAfterDrag()", "    private func buildSections("]
    .map { method(pane, $0) }.joined(separator: "\n")
    .replacingOccurrences(of: "NSWorkspace", with: "FixtureWorkspace")
    .replacingOccurrences(of: "NSRunningApplication", with: "FixtureApplication")
let fixture = #"""
import Cocoa
final class Element {}
struct FixtureApplication {
    var bundleIdentifier: String? = "test.shottr"
    var icon: NSImage? { nil }
    init() {}
    init?(processIdentifier: pid_t) {}
}
struct FixtureWorkspace {
    static let shared = FixtureWorkspace()
    let runningApplications = [FixtureApplication]()
}
enum MenuBarItemAXDiscovery {
    enum SectionKind { case visible, hidden, alwaysHidden }
    struct AXMenuBarItem {
        let element: Element
        var pid: pid_t = 42
        var bundleID: String? = "test.shottr"
        let identifier: String? = "shottr"
        let title: String? = "Shottr"
        let displayName = "Shottr"
        let subtitle: String? = nil
        var axFrame: CGRect?
    }
    static var items = [AXMenuBarItem]()
    static var trusted = true
    static var hiddenX: CGFloat = 1223
    static var alwaysX: CGFloat = 1067
    static var duringDiscovery: (() -> Void)?
    static func isTrusted() -> Bool { trusted }
    static func discoverItems(in apps: [FixtureApplication]) -> [AXMenuBarItem] {
        duringDiscovery?()
        return items
    }
    // CLASSIFIER
    static func systemImageName(forTitle: String, bundleID: String?) -> String? { nil }
    static func systemImageName(forIdentifier: String?) -> String? { nil }
    static func inputSourceIcon() -> NSImage? { nil }
}
struct CachedItem {
    var frame = CGRect(x: 771, y: 0, width: 38, height: 33)
    var ownerPID: pid_t = 42
    var owningApplication: FixtureApplication? = FixtureApplication()
    let title: String? = "Shottr"
    let displayName = "Shottr"
    let subtitle: String? = nil
    let info = "shottr"
}
final class Cache { var allItems = [CachedItem()] }
final class ItemManager {
    let itemCache = Cache()
    func cacheItemsIfNeeded(force: Bool) async {}
}
final class AppState { let itemManager = ItemManager() }
struct RowItem {
    let id: String; let title: String; let subtitle: String?; let systemImage: String?
    let appIcon: NSImage?; let isSystem: Bool; let ownerPID: pid_t
    let axElement: Element?; let quartzFrame: CGRect?
}
enum MenuBarItemAXMover {
    // MATCHER
}
final class Pane {
    let appState = AppState()
    var hiddenDividerX: CGFloat?
    var alwaysHiddenDividerX: CGFloat?
    var sections = [MenuBarItemAXDiscovery.SectionKind: [RowItem]]()
    var anchorY: CGFloat = 0
    var iconCache = [pid_t: NSImage]()
    func resolveDividers() -> (CGFloat?, CGFloat?) { (MenuBarItemAXDiscovery.hiddenX, MenuBarItemAXDiscovery.alwaysX) }
    // METHODS
}
@main struct Tests {
    static func main() async {
        var failures = 0
        func check(_ passed: Bool, _ name: String) {
            print("\(passed ? "PASS" : "FAIL"): \(name)")
            if !passed { failures += 1 }
        }
        let element = Element()
        let content = CGRect(x: 778, y: 4.5, width: 24, height: 24)
        let ax = MenuBarItemAXDiscovery.AXMenuBarItem(element: element, axFrame: content)
        MenuBarItemAXDiscovery.items = [ax]
        let pane = Pane()
        await pane.rescanAfterDrag()
        let row = pane.sections[.alwaysHidden]?.first
        check(row?.axElement === element, "nonempty native cache receives exact AX identity during pre-drag rescan")
        check(row?.quartzFrame == content, "cached row retains AX content frame for fallback freshness checks")
        check(row?.id == "cgs:shottr:42", "AX enrichment preserves native row identity")
        let hosted = Pane()
        hosted.appState.itemManager.itemCache.allItems[0].ownerPID = 714
        hosted.appState.itemManager.itemCache.allItems[0].owningApplication?.bundleIdentifier = "com.apple.controlcenter"
        await hosted.rescanAfterDrag()
        check(hosted.sections[.alwaysHidden]?.first?.axElement === element,
              "Control Center hosted cache pairs with app-owned AX element")
        for (name, items) in [
            ("ambiguous", [ax, ax]),
            ("missing", []),
            ("wrong owner", [MenuBarItemAXDiscovery.AXMenuBarItem(element: element, pid: 99, axFrame: content)]),
            ("neighbor", [MenuBarItemAXDiscovery.AXMenuBarItem(element: element, axFrame: content.offsetBy(dx: 38, dy: 0))])
        ] {
            MenuBarItemAXDiscovery.items = items
            await pane.rescanAfterDrag()
            check(pane.sections[.alwaysHidden]?.first?.axElement == nil, "\(name) AX candidate is not attached to cached row")
        }
        MenuBarItemAXDiscovery.items = [ax]
        MenuBarItemAXDiscovery.trusted = false
        await pane.rescanAfterDrag()
        check(pane.sections[.alwaysHidden]?.first?.axElement == nil, "untrusted AX discovery does not enrich cached rows")
        MenuBarItemAXDiscovery.trusted = true
        pane.appState.itemManager.itemCache.allItems = []
        await pane.rescanAfterDrag()
        check(pane.sections[.alwaysHidden]?.first?.axElement === element, "empty native cache retains AX fallback")
        // The system settles the divider while the asynchronous AX walk is running.
        MenuBarItemAXDiscovery.hiddenX = 1038.5
        MenuBarItemAXDiscovery.alwaysX = 922.5
        MenuBarItemAXDiscovery.items = [MenuBarItemAXDiscovery.AXMenuBarItem(
            element: element, axFrame: CGRect(x: 1047, y: 4.5, width: 24, height: 24))]
        MenuBarItemAXDiscovery.duringDiscovery = { MenuBarItemAXDiscovery.hiddenX = 1076.5 }
        await pane.rescanAfterDrag()
        check(pane.sections[.hidden]?.first?.axElement === element && pane.sections[.visible] == nil,
              "post-drag classification uses dividers settled during the AX walk")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ice-cached-ax-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let file = directory.appendingPathComponent("test.swift")
try fixture.replacingOccurrences(of: "// METHODS", with: methods)
    .replacingOccurrences(of: "// CLASSIFIER", with: ["    static func classify(", "    static func normalizedDividers("]
        .map { method(discovery, $0) }.joined(separator: "\n"))
    .replacingOccurrences(of: "// MATCHER", with: method(mover, "    static func matchingWindowIndex("))
    .write(to: file, atomically: true, encoding: .utf8)
let binary = directory.appendingPathComponent("test")
let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = ["-parse-as-library", file.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit()
if compiler.terminationStatus != 0 { exit(compiler.terminationStatus) }
let test = Process(); test.executableURL = binary
try test.run(); test.waitUntilExit()
let status = test.terminationStatus
try FileManager.default.removeItem(at: directory)
exit(status)
