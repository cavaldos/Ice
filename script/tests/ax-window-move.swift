// Exercises the production fallback against controlled WindowServer/transport boundaries.
import Foundation
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().path
func extract(_ path: String, _ signature: String) throws -> String {
    let source = try String(contentsOfFile: repo + path, encoding: .utf8)
    let start = source.range(of: signature)!.lowerBound
    let end = source.range(of: "\n    }\n", range: start..<source.endIndex)!.upperBound
    return String(source[start..<end]).replacingOccurrences(of: "private func", with: "func")
}
let fallback = try extract("/Ice/Settings/SettingsPanes/MenuBarLayoutSettingsPane.swift", "    private func moveOccludedItem(")
let matcher = try extract("/Ice/MenuBar/MenuBarItems/MenuBarItemAXMover.swift", "    static func matchingWindowIndex(")
let fixture = #"""
import Cocoa
final class Element { var frame: CGRect?; init(_ frame: CGRect?) { self.frame = frame } }
enum MenuBarItemAXDiscovery {
    enum SectionKind: CaseIterable { case visible, hidden, alwaysHidden }
    static func frame(of element: Element) -> CGRect? { element.frame }
}
enum ControlItem { enum Identifier: String { case hidden = "HItem", alwaysHidden = "AHItem" } }
struct Host { let bundleIdentifier: String }
struct WindowInfo {
    let windowID: UInt32
    let frame: CGRect
    var title: String? = "Item-0"
    var ownerPID: pid_t = 714
    var owningApplication: Host? = Host(bundleIdentifier: "com.apple.controlcenter")
    var isMenuBarItem = true
    static var snapshot = [WindowInfo]()
    static func getAllWindows() -> [WindowInfo] { snapshot }
}
struct MenuBarItem {
    let window: WindowInfo
    var windowID: UInt32 { window.windowID }
    var frame: CGRect { window.frame }
    var ownerPID: pid_t { window.ownerPID }
    init?(itemWindow: WindowInfo) { guard itemWindow.isMenuBarItem else { return nil }; window = itemWindow }
}
struct RowItem {
    let title: String; let quartzFrame: CGRect?; var ownerPID: pid_t = 43319
    var axElement: Element?
    init(title: String, quartzFrame: CGRect?) { self.title = title; self.quartzFrame = quartzFrame; axElement = Element(quartzFrame) }
}
final class MenuBarItemManager {
    enum MoveDestination { case leftOfItem(MenuBarItem), rightOfItem(MenuBarItem) }
    enum Failure: Error { case nativeMoveFailed }
    var calls = [(UInt32, UInt32, Bool)]()
    var shouldFail = false
    var beforePreflight: (() -> Void)?
    func move(item: MenuBarItem, to destination: MoveDestination, preflight: (() -> Bool)? = nil) async throws {
        beforePreflight?()
        if let preflight, !preflight() { throw Failure.nativeMoveFailed }
        switch destination {
        case let .leftOfItem(anchor): calls.append((item.windowID, anchor.windowID, false))
        case let .rightOfItem(anchor): calls.append((item.windowID, anchor.windowID, true))
        }
        if shouldFail { throw Failure.nativeMoveFailed }
    }
}
final class AppState { let itemManager = MenuBarItemManager() }
enum MenuBarItemAXMover {
    // MATCHER
}
final class Pane {
    let appState = AppState()
    var hiddenDividerX: CGFloat? = 1223.5
    var alwaysHiddenDividerX: CGFloat? = 1067.5
    var moveFailure: String? = "Source is occluded"
    var isPresented = true
    var ownsLayoutSession = true
    // FALLBACK
}
@main struct Tests {
    static func main() async {
        var failures = 0
        func check(_ passed: Bool, _ name: String) {
            print("\(passed ? "PASS" : "FAIL"): \(name)")
            if !passed { failures += 1 }
        }
        let shottr = RowItem(title: "Shottr", quartzFrame: CGRect(x: 778, y: 4.5, width: 24, height: 24))
        let source = WindowInfo(windowID: 3915, frame: CGRect(x: 771, y: 0, width: 38, height: 33))
        let hidden = WindowInfo(windowID: 3773, frame: CGRect(x: 1223, y: 0, width: 1, height: 33), title: "HItem")
        let always = WindowInfo(windowID: 3774, frame: CGRect(x: 1067, y: 0, width: 1, height: 33), title: "AHItem")
        for (kind, expectedID, right) in [(MenuBarItemAXDiscovery.SectionKind.visible, UInt32(3773), true),
                                          (.hidden, UInt32(3773), false), (.alwaysHidden, UInt32(3774), false)] {
            WindowInfo.snapshot = [source, hidden, always]
            let pane = Pane()
            let result = await pane.moveOccludedItem(shottr, to: kind)
            let calls = pane.appState.itemManager.calls
            check(result && calls.count == 1 && calls[0].0 == 3915 && calls[0].1 == expectedID
                  && calls[0].2 == right && pane.moveFailure == nil,
                  "occluded source uses correct divider and side for \(kind)")
        }
        let target = RowItem(title: "Target", quartzFrame: CGRect(x: 1185, y: 4.5, width: 38, height: 24))
        // Captured Claude AX bounds overflow the hosted window by 1pt on each side.
        let claude = RowItem(title: "Claude", quartzFrame: CGRect(x: 770, y: 3.5, width: 42, height: 26))
        let claudeWindow = WindowInfo(windowID: 5642, frame: CGRect(x: 771, y: 0, width: 40, height: 33))
        for (name, windows, expected) in [
            ("centered Claude bounds", [claudeWindow, hidden, always], true),
            ("ambiguous Claude windows", [claudeWindow, claudeWindow, hidden, always], false),
            ("shifted Claude window", [WindowInfo(windowID: 5642, frame: claudeWindow.frame.offsetBy(dx: 1, dy: 0)), hidden, always], false),
            ("excessive Claude overflow", [WindowInfo(windowID: 5642, frame: CGRect(x: 772, y: 0, width: 38, height: 33)), hidden, always], false)
        ] {
            WindowInfo.snapshot = windows
            let pane = Pane()
            let result = await pane.moveOccludedItem(claude, to: .hidden)
            let calls = pane.appState.itemManager.calls
            check(result == expected && (expected
                  ? calls.count == 1 && calls[0].0 == 5642 && calls[0].1 == 3773 && !calls[0].2
                  : calls.isEmpty), "\(name) uses only a unique tightly bounded native target")
        }
        for kind in MenuBarItemAXDiscovery.SectionKind.allCases {
            WindowInfo.snapshot = [source, hidden, always]
            let padded = Pane()
            // Captured compact dividers: 4pt AX hit area around a 1pt status window.
            padded.hiddenDividerX = 1221.5
            padded.alwaysHiddenDividerX = 1065.5
            let moved = await padded.moveOccludedItem(shottr, to: kind)
            let call = padded.appState.itemManager.calls.first
            check(moved && call?.0 == 3915 && call?.1 == (kind == .alwaysHidden ? 3774 : 3773)
                  && call?.2 == (kind == .visible), "compact AX padding resolves the correct divider for \(kind)")
        }
        WindowInfo.snapshot = [source, hidden, always]
        let displaced = Pane()
        displaced.hiddenDividerX = 1219.5
        let displacedResult = await displaced.moveOccludedItem(shottr, to: .hidden)
        check(!displacedResult && displaced.appState.itemManager.calls.isEmpty,
              "divider outside the compact hit-area tolerance is rejected")
        WindowInfo.snapshot = [source, WindowInfo(windowID: 145, frame: CGRect(x: 1185, y: 0, width: 38, height: 33))]
        let onto = Pane()
        let inserted = await onto.moveOccludedItem(shottr, to: .hidden, before: target)
        check(inserted && onto.appState.itemManager.calls.first?.1 == 145
              && onto.appState.itemManager.calls.first?.2 == false,
              "item drop addresses the requested insertion anchor")
        for (name, windows) in [
            ("missing source", [hidden, always]),
            ("ambiguous source", [source, source, hidden, always]),
            ("missing divider", [source, always]),
            ("ambiguous divider", [source, hidden, hidden]),
            ("unrelated host", [WindowInfo(windowID: 3915, frame: source.frame, owningApplication: Host(bundleIdentifier: "other.app")), hidden]),
            ("non-status window", [WindowInfo(windowID: 3915, frame: source.frame, isMenuBarItem: false), hidden])
        ] {
            WindowInfo.snapshot = windows
            let pane = Pane()
            let result = await pane.moveOccludedItem(shottr, to: .hidden)
            check(!result && pane.appState.itemManager.calls.isEmpty, "\(name) produces no native move")
        }
        WindowInfo.snapshot = [source, hidden, always]
        let failed = Pane()
        failed.appState.itemManager.shouldFail = true
        let result = await failed.moveOccludedItem(shottr, to: .hidden)
        check(!result && failed.moveFailure != nil, "native transport failure is reported to the drop caller")
        let stale = Pane()
        let removed = RowItem(title: "Shottr", quartzFrame: shottr.quartzFrame)
        removed.axElement?.frame = nil
        let staleResult = await stale.moveOccludedItem(removed, to: .hidden)
        check(!staleResult && stale.appState.itemManager.calls.isEmpty,
              "disappeared AX identity cannot transfer to an equally sized replacement window")
        let delayed = Pane()
        let changing = RowItem(title: "Shottr", quartzFrame: shottr.quartzFrame)
        delayed.appState.itemManager.beforePreflight = { changing.axElement?.frame = nil }
        let delayedResult = await delayed.moveOccludedItem(changing, to: .hidden)
        check(!delayedResult && delayed.appState.itemManager.calls.isEmpty,
              "AX identity is revalidated after input settling, before native events")
        let closed = Pane()
        closed.appState.itemManager.beforePreflight = { closed.isPresented = false }
        let closedResult = await closed.moveOccludedItem(shottr, to: .hidden)
        check(!closedResult && closed.appState.itemManager.calls.isEmpty,
              "closing Layout while input settles prevents the deferred native move")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ice-window-move-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let file = directory.appendingPathComponent("test.swift")
try fixture.replacingOccurrences(of: "// MATCHER", with: matcher)
    .replacingOccurrences(of: "// FALLBACK", with: fallback).write(to: file, atomically: true, encoding: .utf8)
let binary = directory.appendingPathComponent("test")
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = ["-parse-as-library", file.path, "-o", binary.path]
try compiler.run()
compiler.waitUntilExit()
if compiler.terminationStatus != 0 { exit(compiler.terminationStatus) }
let test = Process()
test.executableURL = binary
try test.run()
test.waitUntilExit()
let status = test.terminationStatus
try FileManager.default.removeItem(at: directory)
exit(status)
