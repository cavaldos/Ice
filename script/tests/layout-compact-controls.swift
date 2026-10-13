// Exercises actual compact-mode didSet, appearance updates and Combine width observers.
import Foundation
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().path
let source = try String(contentsOfFile: repo + "/Ice/MenuBar/ControlItem/ControlItem.swift", encoding: .utf8)
func block(_ signature: String) -> String {
    let start = source.range(of: signature)!.lowerBound
    let end = source.range(of: "\n    }\n", range: start..<source.endIndex)!.upperBound
    return String(source[start..<end])
}
let start = source.range(of: "        $state\n")!.lowerBound
let end = source.range(of: "        statusItem.publisher(for: \\.isVisible)", range: start..<source.endIndex)!.lowerBound
let fixture = #"""
import Cocoa
import Combine
enum HidingState { case hideItems, showItems }
enum Lengths { static let standard: CGFloat = 24 }
enum SectionName { case visible, hidden, alwaysHidden }
struct ControlState { var state = HidingState.showItems }
final class Section {
    var name = SectionName.hidden
    var isEnabled = true
    var controlItem = ControlState()
}
struct ImageValue { func nsImage(for app: AppState) -> NSImage { NSImage(size: NSSize(width: 10, height: 10)) } }
enum IconName { case custom, builtin }
struct Icon { var name = IconName.builtin; var visible = ImageValue(); var hidden = ImageValue() }
enum ControlItemImage {
    enum Builtin { case chevronLarge, chevronSmall }
    static func builtin(_ value: Builtin) -> ImageValue { ImageValue() }
}
extension NSImage { func resized(to size: NSSize) -> NSImage { self } }
final class General { var iceIcon = Icon(); var reverseIceIcon = false }
final class Advanced { var showSectionDividers = true }
final class Settings { let generalSettingsManager = General(); let advancedSettingsManager = Advanced() }
final class Manager { func section(withName name: SectionName) -> Section? { nil } }
final class AppState { let settingsManager = Settings(); let menuBarManager = Manager() }
final class Cell { var isEnabled = true }
final class Button {
    var image: NSImage?
    var isHighlighted = false
    let cell: Cell? = Cell()
}
final class Constraint: NSObject { @objc dynamic var isActive = false }
final class StatusItem { var length: CGFloat = 24; let button: Button? = Button() }
final class Window {
    var frame = CGRect(x: 0, y: 0, width: 24, height: 33)
    func setContentSize(_ size: NSSize) { frame.size = size }
}
final class Control {
    @Published var state = HidingState.showItems
    @Published var isVisible = true
    // COMPACT_PROPERTY
    let appState: AppState? = AppState()
    let section: Section? = Section()
    let statusItem = StatusItem()
    let window: Window? = Window()
    let constraint: Constraint? = Constraint()
    var cancellables = Set<AnyCancellable>()
    func expandedHidingLength() -> CGFloat { 10000 }
    func configure() {
        var c = Set<AnyCancellable>()
        // OBSERVERS
        cancellables = c
    }
    // APPEARANCE
}
var failures = 0
func check(_ passed: Bool, _ name: String) {
    print("\(passed ? "PASS" : "FAIL"): \(name)")
    if !passed { failures += 1 }
}
for showDivider in [true, false] {
    let control = Control()
    control.appState?.settingsManager.advancedSettingsManager.showSectionDividers = showDivider
    control.configure()
    control.isCompactForLayout = true
    check(control.statusItem.length == 2 && control.constraint?.isActive == false,
          "compact toggle alone shrinks divider and disables minimum width (visible preference \(showDivider))")
    check(control.statusItem.button?.image == nil, "compact toggle clears divider image (visible preference \(showDivider))")
    control.isCompactForLayout = false
    check(control.statusItem.length == (showDivider ? 24 : 0) && control.constraint?.isActive == showDivider,
          "leaving compact mode alone restores width and constraint (visible preference \(showDivider))")
}
exit(failures == 0 ? 0 : 1)
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ice-compact-controls-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let file = directory.appendingPathComponent("test.swift")
try fixture.replacingOccurrences(of: "// COMPACT_PROPERTY", with: block("    var isCompactForLayout = false"))
    .replacingOccurrences(of: "// OBSERVERS", with: String(source[start..<end]))
    .replacingOccurrences(of: "// APPEARANCE", with: block("    func updateStatusItem(with state:"))
    .write(to: file, atomically: true, encoding: .utf8)
let runner = Process(); runner.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
runner.arguments = [file.path]
try runner.run(); runner.waitUntilExit()
let status = runner.terminationStatus
try FileManager.default.removeItem(at: directory)
exit(status)
