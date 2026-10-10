//
//  ax-row-filter.swift
//  Ice
//

// Exercises the actual AX row scan and shared classifier with controlled discovery geometry.
import Foundation

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().path
let source = try String(contentsOfFile: repo + "/Ice/UI/IceBar/IceBar.swift", encoding: .utf8)
let discovery = try String(contentsOfFile: repo + "/Ice/MenuBar/MenuBarItems/MenuBarItemAXDiscovery.swift", encoding: .utf8)
let mover = try String(contentsOfFile: repo + "/Ice/MenuBar/MenuBarItems/MenuBarItemAXMover.swift", encoding: .utf8)
func method(_ signature: String, in source: String) -> String {
    let start = source.range(of: signature)!.lowerBound
    let end = source.range(of: "\n    }\n", range: start..<source.endIndex)!.upperBound
    return String(source[start..<end]).replacingOccurrences(of: "private func", with: "func")
}
let scan = method("    private func scanAXRowsOnce(", in: source)
    .replacingOccurrences(of: "NSWorkspace", with: "FixtureWorkspace")
    .replacingOccurrences(of: "NSRunningApplication", with: "FixtureApplication")
let classification = ["    static func classify(", "    static func normalizedDividers(", "    static func isSettledDividerFrame("]
    .map { method($0, in: discovery) }.joined(separator: "\n")
let fixtures = #"""
import Cocoa
struct FixtureApplication {
    let pid: pid_t
    init?(processIdentifier: pid_t) { pid = processIdentifier }
    static let current = FixtureApplication(processIdentifier: 77)!
    var processIdentifier: pid_t { pid }
    var bundleIdentifier: String? { pid == 714 ? "com.apple.controlcenter" : "fixture.app" }
    var icon: NSImage? { nil }
}
struct FixtureWorkspace {
    static let shared = FixtureWorkspace()
    let runningApplications = [FixtureApplication]()
}
struct WindowInfo {
    let title: String?
    let frame: CGRect
    var ownerPID: pid_t = 714
    var isMenuBarItem = true
    var owningApplication: FixtureApplication? { FixtureApplication(processIdentifier: ownerPID) }
    static var windows = [WindowInfo]()
    static func getAllWindows() -> [WindowInfo] { windows }
}
enum MenuBarItemAXMover {
    // MATCHER
}
enum MenuBarItemAXDiscovery {
    enum SectionKind { case visible, hidden, alwaysHidden }
    struct AXMenuBarItem {
        let pid: pid_t = 42
        let bundleID: String? = nil
        let identifier: String? = nil
        let title: String?
        var displayName: String { title ?? "unknown" }
        let axFrame: CGRect?
    }
    static var items = [AXMenuBarItem]()
    static var dividers: (hidden: CGRect?, alwaysHidden: CGRect?) = (nil, nil)
    static func discoverItems(in apps: [FixtureApplication]) -> [AXMenuBarItem] { items }
    static func dividerFrames() -> (hidden: CGRect?, alwaysHidden: CGRect?) { dividers }
    static func systemImageName(forIdentifier id: String?) -> String? { nil }
    static func inputSourceIcon() -> NSImage? { nil }
    // PRODUCTION_CLASSIFICATION
}
struct AXRowItem {
    let id: String
    let item: MenuBarItemAXDiscovery.AXMenuBarItem
    let title: String?
    let displayName: String
    let systemImage: String?
    let appIcon: NSImage?
    let midX: CGFloat?
}
struct Window { let frame: CGRect }
final class ControlItem { var window: Window? }
final class Section {
    enum Name { case visible, hidden, alwaysHidden }
    let controlItem = ControlItem()
    var isEnabled = true
}
final class MenuBarManager {
    let hidden = Section()
    let alwaysHidden = Section()
    func section(withName name: Section.Name) -> Section? { name == .hidden ? hidden : alwaysHidden }
}
final class AppState { var isActiveSpaceFullscreen = false }
struct Screen {
    let displayID = 1
    let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
}
enum MenuBarOverlayPanelContentView {
    static var width: CGFloat?
    static func currentTrailingVisibleWidth(for displayID: Int) -> CGFloat? { width }
}
struct Logger {
    static let iceBar = Logger()
    func info(_ message: String) {}
}
@MainActor final class Content {
    var section = Section.Name.hidden
    let menuBarManager = MenuBarManager()
    let appState = AppState()
    let screen = Screen()
    var axRows = [AXRowItem]()
    // PRODUCTION_SCAN
}
@MainActor func runTests() async {
    var failures = 0
    func expect(_ name: String, _ passed: Bool) {
        print("\(passed ? "PASS" : "FAIL"): \(name)")
        if !passed { failures += 1 }
    }
    func divider(_ x: CGFloat?) -> CGRect? { x.map { CGRect(x: $0, y: 0, width: 20, height: 24) } }
    func check(_ name: String, hidden: CGFloat?, always: CGFloat?, width: CGFloat? = nil,
               fullscreen: Bool = false, nativeHidden: CGFloat? = nil,
               section: Section.Name = .hidden, alwaysEnabled: Bool = true, expected: [String]) async {
        let content = Content()
        content.section = section
        content.menuBarManager.alwaysHidden.isEnabled = alwaysEnabled
        content.appState.isActiveSpaceFullscreen = fullscreen
        content.menuBarManager.hidden.controlItem.window = divider(nativeHidden).map { Window(frame: $0) }
        MenuBarItemAXDiscovery.dividers = (divider(hidden), divider(always))
        MenuBarOverlayPanelContentView.width = width
        await content.scanAXRowsOnce(attempt: 0)
        expect(name, content.axRows.compactMap(\.title) == expected)
        if content.axRows.compactMap(\.title) != expected {
            print("  expected \(expected), got \(content.axRows.compactMap(\.title))")
        }
    }
    MenuBarItemAXDiscovery.items = [1000, 600, 400].map {
        .init(title: String($0), axFrame: CGRect(x: $0 - 10, y: 0, width: 20, height: 24))
    } + [.init(title: "unframed", axFrame: nil)]
    await check("normal bar excludes Always Hidden and visible items", hidden: 800, always: 500, expected: ["600"])
    await check("explicit Always Hidden bar excludes Hidden items", hidden: 800, always: 500, section: .alwaysHidden, expected: ["400"])
    await check("missing enabled Always Hidden boundary cannot leak its items", hidden: 800, always: nil, expected: [])
    await check("disabled Always Hidden allows all known hidden items", hidden: 800, always: nil, alwaysEnabled: false, expected: ["400", "600"])
    await check("missing hidden boundary does not expose unknown sections", hidden: nil, always: 500, expected: [])
    await check("visible-region estimate cannot replace section boundaries", hidden: nil, always: 500, width: 200, expected: [])
    await check("both missing boundaries do not expose all items", hidden: nil, always: nil, expected: [])
    await check("fullscreen with missing boundaries stays closed", hidden: nil, always: 500, width: 200, fullscreen: true, expected: [])
    await check("native hidden-divider fallback preserves section isolation", hidden: nil, always: 500, nativeHidden: 800, expected: ["600"])
    await check("parking-spacer geometry cannot expose unrelated items", hidden: 7, always: 500, width: 200, expected: [])
    await check("reversed dividers cannot leak Always Hidden", hidden: 500, always: 800, expected: [])
    await check("disabled Always Hidden cannot be opened", hidden: 800, always: 500, section: .alwaysHidden, alwaysEnabled: false, expected: [])
    MenuBarItemAXDiscovery.items = [-9100, -3950, 1250].map {
        .init(title: String(Int($0)), axFrame: CGRect(x: $0 - 12, y: 4.5, width: 24, height: 24))
    }
    let nativeItems = [-9100, -3950, 1250].map {
        WindowInfo(title: "Item", frame: CGRect(x: $0 - 19, y: 0, width: 38, height: 33))
    }
    let h = WindowInfo(title: "HItem", frame: CGRect(x: -3840, y: 0, width: 5016, height: 33))
    let ah = WindowInfo(title: "AHItem", frame: CGRect(x: -9081, y: 0, width: 5016, height: 33))
    WindowInfo.windows = nativeItems + [h, ah]
    await check("collapsed native spacers retain Hidden isolation", hidden: nil, always: nil, expected: ["-3950"])
    await check("collapsed native spacers retain Always Hidden isolation", hidden: nil, always: nil, section: .alwaysHidden, expected: ["-9100"])
    WindowInfo.windows = nativeItems + [h, ah, ah]
    await check("duplicate native anchors cannot expose items", hidden: nil, always: nil, expected: [])
    var wrongOwner = ah; wrongOwner.ownerPID = 123
    WindowInfo.windows = nativeItems + [h, wrongOwner]
    await check("unrelated native anchor cannot expose items", hidden: nil, always: nil, expected: [])
    WindowInfo.windows = nativeItems + [h, ah, nativeItems[1]]
    await check("ambiguous native item is withheld", hidden: nil, always: nil, expected: [])
    WindowInfo.windows = nativeItems + [h, ah]
    MenuBarItemAXDiscovery.items = [.init(title: "stale", axFrame: CGRect(x: -3962, y: 986, width: 24, height: 24))]
    await check("parked AX item cannot inherit native section", hidden: nil, always: nil, expected: [])
    expect("shared classifier still treats nil as a disabled section", MenuBarItemAXDiscovery.classify(centerX: 600, hiddenDividerX: nil, alwaysHiddenDividerX: 500) == .visible)
    exit(failures == 0 ? 0 : 1)
}
await runTests()
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ice-row-filter-test-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let generated = directory.appendingPathComponent("row-filter.swift")
try fixtures.replacingOccurrences(of: "    // PRODUCTION_CLASSIFICATION", with: classification)
    .replacingOccurrences(of: "// MATCHER", with: method("    static func matchingWindowIndex(", in: mover))
    .replacingOccurrences(of: "    // PRODUCTION_SCAN", with: scan)
    .write(to: generated, atomically: true, encoding: .utf8)
let runner = Process()
runner.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
runner.arguments = [generated.path]
try runner.run()
runner.waitUntilExit()
let status = runner.terminationStatus
try FileManager.default.removeItem(at: directory)
exit(status)
