// Executes the production click handler; only AppKit event/menu/toggle boundaries are controlled.
import Foundation
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().path
let source = try String(contentsOfFile: repo + "/Ice/MenuBar/ControlItem/ControlItem.swift", encoding: .utf8)
let start = source.range(of: "    @objc private func performAction()")!.lowerBound
let end = source.range(of: "\n    /// Creates a menu", range: start..<source.endIndex)!.lowerBound
let action = String(source[start..<end]).replacingOccurrences(of: "@objc private", with: "")
let fixture = #"""
import Cocoa
enum Name { case visible, hidden, alwaysHidden }
final class Section {
    let name: Name
    var isEnabled = true
    var toggles = 0
    init(_ name: Name) { self.name = name }
    func toggle() { toggles += 1 }
}
final class Manager {
    let visible = Section(.visible), hidden = Section(.hidden), always = Section(.alwaysHidden)
    func section(withName name: Name) -> Section? {
        switch name { case .visible: visible; case .hidden: hidden; case .alwaysHidden: always }
    }
}
final class Advanced { var canToggleAlwaysHiddenSection = true }
final class Settings { let advancedSettingsManager = Advanced() }
final class AppState { let menuBarManager = Manager(); let settingsManager = Settings() }
struct Event { var type: NSEvent.EventType; var clickCount = 1 }
final class App { var currentEvent: Event? }
let NSApp = App()
enum NSEvent {
    enum EventType: Int { case leftMouseDown, leftMouseUp, rightMouseUp, mouseMoved }
    static var modifierFlags = AppKit.NSEvent.ModifierFlags()
}
struct Logger { static let controlItem = Logger(); func info(_ text: String) {} }
final class StatusItem { var menus = 0; func showMenu(_ menu: Int) { menus += 1 } }
final class Control {
    enum Identifier { case iceIcon, hidden, alwaysHidden }
    let identifier: Identifier
    var appState: AppState? = AppState()
    let statusItem = StatusItem()
    var section: Section? {
        appState?.menuBarManager.section(withName: identifier == .iceIcon ? .visible : (identifier == .hidden ? .hidden : .alwaysHidden))
    }
    init(_ id: Identifier = .iceIcon) { identifier = id }
    func createMenu(with app: AppState) -> Int { 0 }
    // ACTION
}
var failures = 0
func check(_ passed: Bool, _ name: String) {
    print("\(passed ? "PASS" : "FAIL"): \(name)"); if !passed { failures += 1 }
}
func run(_ name: String, id: Control.Identifier = .iceIcon, type: NSEvent.EventType = .leftMouseDown,
         flags: AppKit.NSEvent.ModifierFlags = [], clicks: Int = 1, allowed: Bool = true,
         enabled: Bool = true, expected: [Int]) {
    let control = Control(id)
    let app = control.appState!
    app.settingsManager.advancedSettingsManager.canToggleAlwaysHiddenSection = allowed
    app.menuBarManager.always.isEnabled = enabled
    NSApp.currentEvent = Event(type: type, clickCount: clicks); NSEvent.modifierFlags = flags
    control.performAction()
    let m = app.menuBarManager
    check([m.visible.toggles + m.hidden.toggles, m.always.toggles, control.statusItem.menus] == expected, name)
}
run("normal Ice Bar click never opens Always Hidden", expected: [1, 0, 0])
run("normal native menu-bar click never opens Always Hidden", type: .leftMouseUp, expected: [1, 0, 0])
run("Option-click explicitly opens Always Hidden", flags: .option, expected: [0, 1, 0])
run("double-click explicitly opens Always Hidden", clicks: 2, expected: [0, 1, 0])
run("disabled special gesture uses normal Hidden", clicks: 2, allowed: false, expected: [1, 0, 0])
run("disabled Always Hidden cannot be toggled", flags: .option, enabled: false, expected: [1, 0, 0])
run("Hidden divider remains a Hidden toggle", id: .hidden, expected: [1, 0, 0])
run("Always Hidden divider remains explicit", id: .alwaysHidden, expected: [0, 1, 0])
run("right click opens menu without revealing", type: .rightMouseUp, expected: [0, 0, 1])
run("Control-click opens menu without revealing", flags: .control, expected: [0, 0, 1])
exit(failures == 0 ? 0 : 1)
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ice-click-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let file = directory.appendingPathComponent("test.swift")
try fixture.replacingOccurrences(of: "// ACTION", with: action).write(to: file, atomically: true, encoding: .utf8)
let runner = Process(); runner.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
runner.arguments = [file.path]; try runner.run(); runner.waitUntilExit()
let status = runner.terminationStatus
try FileManager.default.removeItem(at: directory)
exit(status)
