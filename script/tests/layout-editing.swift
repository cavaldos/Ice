// Exercises the layout pane's lifecycle and native drag preparation without moving the real cursor.
import Foundation

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().path
let pane = try String(contentsOfFile: repo + "/Ice/Settings/SettingsPanes/MenuBarLayoutSettingsPane.swift", encoding: .utf8)
let manager = try String(contentsOfFile: repo + "/Ice/MenuBar/MenuBarManager.swift", encoding: .utf8)
let events = try String(contentsOfFile: repo + "/Ice/Events/EventManager.swift", encoding: .utf8)
func method(_ source: String, _ signature: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound else { return "" }
    let end = source.range(of: "\n    }\n", range: start..<source.endIndex)!.upperBound
    return String(source[start..<end]).replacingOccurrences(of: "private func", with: "func")
}
func lifecycle(_ name: String) -> String {
    let start = pane.range(of: "        .\(name) {\n")!.upperBound
    let end = pane.range(of: "\n        }", range: start..<pane.endIndex)!.lowerBound
    return String(pane[start..<end])
}
let fixture = #"""
import Foundation
enum HidingState { case hideItems, showItems }
final class ControlItem {
    var state = HidingState.hideItems
    var isVisible = true
    var isAddedToMenuBar = true
    var isSectionDivider = true
    var isCompactForLayout = false
    func updateStatusItem(with state: HidingState) {}
}
final class MenuBarSection {
    let controlItem = ControlItem()
    var stateRevision = 0
    var writes = 0
    var rehideRestarts = 0
    var isEnabled = true
    func setState(_ state: HidingState, persist: Bool) {
        controlItem.state = state
        controlItem.isVisible = state == .hideItems
        stateRevision += 1
        if persist { writes += 1 }
    }
    func startRehideChecks() { rehideRestarts += 1 }
}
final class IceBarPanel {
    var isActivatingAXItem = false
    func close() {}
}
final class MenuBarManager {
    var sections = [MenuBarSection(), MenuBarSection(), MenuBarSection()]
    let iceBarPanel = IceBarPanel()
    var isEditingLayout = false
    var layoutRestoreStates = [(section: MenuBarSection, state: HidingState, visible: Bool, revision: Int)]()
    // MANAGER_METHODS
}
struct NSEvent {
    enum Flag { case command }
    let modifierFlags: Set<Flag> = [.command]
}
final class AdvancedSettings { var showAllSectionsOnUserDrag = true }
final class Settings { let advancedSettingsManager = AdvancedSettings() }
final class Appearance { func setIsDraggingMenuBarItem(_ value: Bool) {} }
final class AppState {
    let menuBarManager = MenuBarManager()
    let settingsManager = Settings()
    let appearanceManager = Appearance()
}
final class EventManager {
    var appState: AppState?
    var isMouseInsideMenuBar = true
    // EVENT_METHOD
}
final class Pane {
    let appState = AppState()
    var isMoving = false
    var isPresented = false
    var ownsLayoutSession = false
    var dividerPollGeneration = 0
    var iconRetryGeneration = 0
    var measuredDividers = false
    func applySnapshotFromCache() {}
    func refresh() async {
        measuredDividers = appState.menuBarManager.sections.filter { $0.isEnabled }
            .allSatisfy { $0.controlItem.state == .showItems && $0.controlItem.isVisible }
    }
    // PANE_METHODS
    func appear() async {
        // APPEAR
    }
    func disappear() {
        // DISAPPEAR
    }
}
var failures = 0
func check(_ condition: Bool, _ name: String) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}
@main struct Tests {
    static func main() async {
        let starting = MenuBarManager()
        starting.sections = []
        check(!starting.beginLayoutEditing() && !starting.isEditingLayout,
              "layout waits for section setup instead of claiming an empty session")
        let pane = Pane()
        let sections = pane.appState.menuBarManager.sections
        sections[2].isEnabled = false
        sections[2].controlItem.isAddedToMenuBar = false
        await pane.appear()
        check(pane.measuredDividers, "layout exposes dividers before measuring collapsed sections")
        check(sections[0].writes == 0 && sections[1].writes == 0, "opening layout does not persist a reveal")
        check(sections[2].controlItem.state == .hideItems, "disabled sections stay untouched")
        check(sections[0].controlItem.isCompactForLayout && sections[1].controlItem.isCompactForLayout
              && !sections[2].controlItem.isCompactForLayout,
              "layout temporarily compacts only enabled controls to free notch space")
        pane.disappear()
        check(sections.allSatisfy { !$0.controlItem.isCompactForLayout }, "leaving layout restores control widths")
        check(sections[0].controlItem.state == .hideItems && sections[1].controlItem.state == .hideItems,
              "leaving layout restores the original collapsed state")
        check(!pane.appState.menuBarManager.isEditingLayout, "leaving layout releases the editing guard")

        let changed = Pane()
        await changed.appear()
        changed.appState.menuBarManager.sections[1].setState(.showItems, persist: true)
        changed.disappear()
        check(changed.appState.menuBarManager.sections[1].controlItem.state == .showItems,
              "cleanup preserves a newer explicit visibility choice")
        check(changed.appState.menuBarManager.sections[1].writes == 1,
              "cleanup never rewrites visibility preferences")
        check(changed.appState.menuBarManager.sections.allSatisfy { !$0.controlItem.isCompactForLayout },
              "newer state choices do not leave compact controls behind")

        let busy = Pane()
        await busy.appear()
        busy.isMoving = true
        busy.disappear()
        check(busy.appState.menuBarManager.isEditingLayout,
              "closing the pane does not collapse icons during an in-flight drag")
        let events = EventManager()
        events.appState = busy.appState
        let disabled = busy.appState.menuBarManager.sections[2]
        disabled.controlItem.state = .hideItems
        disabled.controlItem.isAddedToMenuBar = false
        events.handleLeftMouseDragged(with: NSEvent())
        check(disabled.controlItem.state == .hideItems,
              "layout drags do not trigger the user-drag reveal of disabled sections")
        busy.isMoving = false
        busy.endLayoutEditingIfNeeded()
        check(!busy.appState.menuBarManager.isEditingLayout && busy.appState.menuBarManager.sections[0].controlItem.state == .hideItems,
              "finishing the in-flight drag releases and restores a closed layout")

        let blocked = Pane()
        blocked.appState.menuBarManager.iceBarPanel.isActivatingAXItem = true
        let release = Task {
            try? await Task.sleep(for: .milliseconds(100))
            blocked.appState.menuBarManager.iceBarPanel.isActivatingAXItem = false
        }
        await blocked.appear()
        await release.value
        check(blocked.ownsLayoutSession && blocked.measuredDividers,
              "layout retries acquisition after activation releases the native items")
        blocked.disappear()
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let generated = fixture
    .replacingOccurrences(of: "// EVENT_METHOD", with: method(events, "    private func handleLeftMouseDragged("))
    .replacingOccurrences(of: "// MANAGER_METHODS", with:
        method(manager, "    func beginLayoutEditing()") + method(manager, "    func endLayoutEditing()"))
    .replacingOccurrences(of: "// PANE_METHODS", with: method(pane, "    private func endLayoutEditingIfNeeded()"))
    .replacingOccurrences(of: "// APPEAR", with: lifecycle("task"))
    .replacingOccurrences(of: "// DISAPPEAR", with: lifecycle("onDisappear"))
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ice-layout-test-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let sourceURL = directory.appendingPathComponent("test.swift")
try generated.write(to: sourceURL, atomically: true, encoding: .utf8)
let runner = Process()
runner.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
let binary = directory.appendingPathComponent("test")
runner.arguments = ["-parse-as-library", sourceURL.path, "-o", binary.path]
try runner.run()
runner.waitUntilExit()
if runner.terminationStatus != 0 { exit(runner.terminationStatus) }
let test = Process()
test.executableURL = binary
try test.run()
test.waitUntilExit()
let status = test.terminationStatus
try FileManager.default.removeItem(at: directory)
exit(status)
