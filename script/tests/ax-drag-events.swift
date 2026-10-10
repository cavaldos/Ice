// Runs the production drag sequence with real Quartz events, recording instead of posting them.
import Foundation
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().path
let source = try String(contentsOfFile: repo + "/Ice/MenuBar/MenuBarItems/MenuBarItemAXMover.swift", encoding: .utf8)
let instrumented = source
    .replacingOccurrences(of: "event.post(tap: .cghidEventTap)", with: "recorder.record(event)")
    .replacingOccurrences(of: "CGWarpMouseCursorPosition(originalLocation)", with: "_ = originalLocation")
let tests = #"""
final class Recorder: @unchecked Sendable {
    let lock = NSLock()
    var events = [CGEvent]()
    func record(_ event: CGEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }
}
let recorder = Recorder()
await MenuBarItemAXMover.commandDrag(from: CGPoint(x: 1100, y: 12), to: CGPoint(x: 900, y: 12))
let events = recorder.events
var failures = 0
func check(_ condition: Bool, _ name: String) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}
let modifiers = events.filter { $0.type == .flagsChanged }
check(modifiers.count == 2, "native drag actually emits Command press and release")
if modifiers.count == 2 {
    check(modifiers[0].getIntegerValueField(.keyboardEventKeycode) == 55 && modifiers[0].flags.contains(.maskCommand),
          "Command press identifies the modifier key")
    check(modifiers[1].getIntegerValueField(.keyboardEventKeycode) == 55 && !modifiers[1].flags.contains(.maskCommand),
          "Command release clears the same modifier key")
    let types = events.map(\.type)
    check(types.firstIndex(of: .flagsChanged)! < types.firstIndex(of: .leftMouseDown)!,
          "Command is pressed before grabbing the icon")
    check(types.lastIndex(of: .flagsChanged)! > types.lastIndex(of: .leftMouseUp)!,
          "Command is released after dropping the icon")
}
check(events.filter { $0.type == .leftMouseDown || $0.type == .leftMouseDragged || $0.type == .leftMouseUp }
    .allSatisfy { $0.flags.contains(.maskCommand) }, "mouse events retain Command throughout the drag")
let menuRegions = [CGRect(x: 0, y: 0, width: 663, height: 32),
                   CGRect(x: 848, y: 0, width: 664, height: 32)]
check(MenuBarItemAXMover.dragPoint(in: CGRect(x: 796, y: 4.5, width: 24, height: 24), usableRegions: menuRegions) == nil,
      "Shottr's captured frame wholly behind the notch is not a drag source")
check(MenuBarItemAXMover.dragPoint(in: CGRect(x: 836, y: 4.5, width: 24, height: 24), usableRegions: menuRegions)
      == CGPoint(x: 854, y: 16.5), "partially occluded icon uses its visible portion")
check(MenuBarItemAXMover.dragPoint(in: CGRect(x: 1170, y: 4.5, width: 24, height: 24), usableRegions: menuRegions)
      == CGPoint(x: 1182, y: 16.5), "fully visible icon retains its center")
check(MenuBarItemAXMover.dragPoint(in: CGRect(x: -9000, y: 4.5, width: 24, height: 24), usableRegions: menuRegions) == nil,
      "offscreen spacer position is not a drag source")
check(MenuBarItemAXMover.dragPoint(in: CGRect(x: 900, y: 1000, width: 24, height: 24), usableRegions: menuRegions) == nil,
      "parked frame below the menu bar is not a drag source")
check(MenuBarItemAXMover.dragPoint(in: CGRect(x: -1200, y: 204, width: 24, height: 24),
      usableRegions: [CGRect(x: -1512, y: 200, width: 1512, height: 32)]) == CGPoint(x: -1188, y: 216),
      "menu bar on an offset secondary display keeps global Quartz coordinates")
let shottr = CGRect(x: 778, y: 4.5, width: 24, height: 24)
let hostedWindow = CGRect(x: 771, y: 0, width: 38, height: 33)
check(MenuBarItemAXMover.matchingWindowIndex(for: shottr, in: [CGRect(x: 809, y: 0, width: 40, height: 33), hostedWindow]) == 1,
      "occluded Shottr maps to its uniquely centered padded status window")
check(MenuBarItemAXMover.matchingWindowIndex(for: shottr, in: [hostedWindow, hostedWindow]) == nil,
      "ambiguous window matches are rejected")
check(MenuBarItemAXMover.matchingWindowIndex(for: shottr, in: [hostedWindow.offsetBy(dx: 10, dy: 0)]) == nil,
      "neighboring window does not inherit a stale AX source")
check(MenuBarItemAXMover.matchingWindowIndex(for: shottr, in: [CGRect(x: 0, y: 0, width: 1512, height: 33)]) == nil,
      "whole menu-bar window cannot substitute for a status item")
check(MenuBarItemAXMover.matchingWindowIndex(for: .zero, in: [.zero]) == nil,
      "empty AX frames are rejected")
check(MenuBarItemAXMover.matchingWindowIndex(for: CGRect(x: CGFloat.nan, y: 0, width: 24, height: 24), in: [hostedWindow]) == nil,
      "nonfinite AX frames are rejected")
check(MenuBarItemAXMover.matchingWindowIndex(for: shottr.offsetBy(dx: 0, dy: 982), in: [hostedWindow]) == nil,
      "vertically parked AX frame is not matched to the live menu bar")
exit(failures == 0 ? 0 : 1)
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ice-drag-events-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let file = directory.appendingPathComponent("test.swift")
try (instrumented + "\n" + tests).write(to: file, atomically: true, encoding: .utf8)
let runner = Process()
runner.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
runner.arguments = [file.path]
try runner.run()
runner.waitUntilExit()
let status = runner.terminationStatus
try FileManager.default.removeItem(at: directory)
exit(status)
