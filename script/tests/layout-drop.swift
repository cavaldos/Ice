// Runs both production drop paths against controlled native menu-bar positions.
import Foundation
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().path
let source = try String(contentsOfFile: repo + "/Ice/Settings/SettingsPanes/MenuBarLayoutSettingsPane.swift", encoding: .utf8)
func method(_ signature: String) -> String {
    let start = source.range(of: signature)!.lowerBound
    let end = source.range(of: "\n    }\n", range: start..<source.endIndex)!.upperBound
    return String(source[start..<end]).replacingOccurrences(of: "private func", with: "func")
}
let methods = ["drop(itemID: String, to ", "drop(itemID: String, onto ", "removeItem(", "findItem(",
               "isImmediatelyBefore(", "hasLanded(", "reorderDestination(", "leftBound(", "rightBound(", "destinationPoint("]
    .map { method("    private func " + $0) }.joined(separator: "\n")
let fixture = #"""
import Foundation
import CoreGraphics
enum MenuBarItemAXDiscovery { enum SectionKind: CaseIterable { case visible, hidden, alwaysHidden } }
typealias Kind = MenuBarItemAXDiscovery.SectionKind
struct RowItem { var id: String; var quartzFrame: CGRect?; var title: String { id } }
struct Animation { static func easeInOut(duration: Double) -> Animation { Animation() } }
func withAnimation(_ animation: Animation, _ body: () -> Void) { body() }
final class ItemManager { func cacheItemsIfNeeded(force: Bool) async {} }
final class MenuBarManager { var isEditingLayout = true }
final class AppState { let itemManager = ItemManager(); let menuBarManager = MenuBarManager() }
enum MenuBarItemAXMover {
    static var drags = [(CGPoint, CGPoint)]()
    static func commandDrag(from: CGPoint, to: CGPoint) async { drags.append((from, to)) }
}
final class Pane {
    let appState = AppState()
    var isPresented = true
    var ownsLayoutSession = true
    var isMoving = false
    var pendingMoves = Set<String>()
    var dropTargetID: String?
    var moveFailure: String?
    var sourceIsReachable = true
    var hasMatchedWindow = false
    var windowMoves = 0
    var nativeMoveSucceeds = true
    var sections: [Kind: [RowItem]] = [.visible: [RowItem(id: "shottr", quartzFrame: CGRect(x: -1000, y: 0, width: 20, height: 24))],
        .hidden: [RowItem(id: "target", quartzFrame: CGRect(x: 840, y: 0, width: 20, height: 24))]]
    var hiddenDividerX: CGFloat? = 900
    var alwaysHiddenDividerX: CGFloat? = 800
    var anchorY: CGFloat = 12
    var unlockedDuringRefresh = false
    func applySnapshotFromCache() {} // Empty CGS cache on the affected OS.
    func endLayoutEditingIfNeeded() {}
    func refresh() async {}
    func refreshAfterDrop() async { unlockedDuringRefresh = !isMoving }
    func dragSourcePoint(for item: RowItem) -> CGPoint? {
        guard sourceIsReachable, let frame = item.quartzFrame else {
            moveFailure = "Source is behind the notch"
            return nil
        }
        return CGPoint(x: frame.midX, y: frame.midY)
    }
    func moveOccludedItem(_ item: RowItem, to kind: Kind, before target: RowItem? = nil) async -> Bool {
        guard hasMatchedWindow else { return false }
        windowMoves += 1
        moveFailure = nil
        return true
    }
    func rescanAfterDrag() async {
        // AX reports the live source only after revealing the originals.
        let moved = nativeMoveSucceeds && (!MenuBarItemAXMover.drags.isEmpty || windowMoves > 0)
        sections = [.visible: [], .hidden: [RowItem(id: "target", quartzFrame: CGRect(x: 840, y: 0, width: 20, height: 24))]]
        sections[moved ? .hidden : .visible, default: []].insert(
            RowItem(id: "shottr", quartzFrame: CGRect(x: moved ? 820 : 1000, y: 0, width: 20, height: 24)), at: 0)
    }
    // METHODS
}
@main struct Tests {
    static func main() async {
        var failures = 0
        for onto in [false, true] {
            MenuBarItemAXMover.drags = []
            let pane = Pane()
            if onto { await pane.drop(itemID: "shottr", onto: "target") }
            else { await pane.drop(itemID: "shottr", to: .hidden) }
            let passed = MenuBarItemAXMover.drags.count == 1 && MenuBarItemAXMover.drags[0].0 == CGPoint(x: 1010, y: 12)
                && MenuBarItemAXMover.drags[0].1.x > 800 && MenuBarItemAXMover.drags[0].1.x < 900
            print("\(passed ? "PASS" : "FAIL"): \(onto ? "item" : "section") drop uses fresh AX source and Hidden destination")
            if !passed { failures += 1 }
            let locked = !pane.unlockedDuringRefresh && !pane.isMoving
            print("\(locked ? "PASS" : "FAIL"): \(onto ? "item" : "section") drop retains its move lock through reconciliation")
            if !locked { failures += 1 }

            MenuBarItemAXMover.drags = []
            let blocked = Pane()
            blocked.sourceIsReachable = false
            if onto { await blocked.drop(itemID: "shottr", onto: "target") }
            else { await blocked.drop(itemID: "shottr", to: .hidden) }
            let rejected = MenuBarItemAXMover.drags.isEmpty && blocked.moveFailure != nil
                && blocked.findItem(id: "shottr")?.kind == .visible && !blocked.isMoving
            print("\(rejected ? "PASS" : "FAIL"): \(onto ? "item" : "section") drop rejects an unreachable source without moving or losing it")
            if !rejected { failures += 1 }

            MenuBarItemAXMover.drags = []
            let occluded = Pane()
            occluded.sourceIsReachable = false
            occluded.hasMatchedWindow = true
            if onto { await occluded.drop(itemID: "shottr", onto: "target") }
            else { await occluded.drop(itemID: "shottr", to: .hidden) }
            let rescued = occluded.findItem(id: "shottr")?.kind == .hidden && occluded.moveFailure == nil
                && occluded.windowMoves == 1 && MenuBarItemAXMover.drags.isEmpty && !occluded.isMoving
            print("\(rescued ? "PASS" : "FAIL"): \(onto ? "item" : "section") drop moves an occluded source through its matched window")
            if !rescued { failures += 1 }

            MenuBarItemAXMover.drags = []
            let failed = Pane()
            failed.nativeMoveSucceeds = false
            if onto { await failed.drop(itemID: "shottr", onto: "target") }
            else { await failed.drop(itemID: "shottr", to: .hidden) }
            let reported = failed.moveFailure != nil && failed.findItem(id: "shottr")?.kind == .visible
                && !failed.isMoving
            print("\(reported ? "PASS" : "FAIL"): \(onto ? "item" : "section") drop reports a native failure instead of silently snapping back")
            if !reported { failures += 1 }
        }
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ice-drop-test-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let file = directory.appendingPathComponent("test.swift")
try fixture.replacingOccurrences(of: "// METHODS", with: methods).write(to: file, atomically: true, encoding: .utf8)
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
