// Exercises production wake-up cleanup and bounded Layout input preparation.
import Foundation
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().path
let source = try String(contentsOfFile: repo + "/Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift", encoding: .utf8)
func extract(_ signature: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound else { return "func waitForLayoutMoveInput(timeout: Duration) async throws {}" }
    let end = source.range(of: "\n    }\n", range: start..<source.endIndex)!.upperBound
    return String(source[start..<end]).replacingOccurrences(of: "private func", with: "func")
        .replacingOccurrences(of: "NSEvent.modifierFlags", with: "Input.flags")
}
let fixture = #"""
import Cocoa
enum Input { static var flags: NSEvent.ModifierFlags = [] }
struct TaskTimeoutError: Error {}
struct MenuBarItem { let ownerPID: pid_t = 714; let logString = "test" }
struct EventError: Error { enum Code { case invalidEventSource, invalidItem, eventCreationFailure }; let code: Code; let item: MenuBarItem }
enum Location { case pid(pid_t), sessionEventTap }
final class CGEventSource { enum State { case hidSystemState }; init?(stateID: State) {} }
final class CGEvent {
    enum Mouse { case leftMouseDown, leftMouseUp }
    enum Kind { case move(Mouse) }
    let mouse: Mouse
    init(_ mouse: Mouse) { self.mouse = mouse }
    static func menuBarItemEvent(type: Kind, location: CGPoint, item: MenuBarItem, pid: pid_t, source: CGEventSource) -> CGEvent? {
        if case let .move(mouse) = type { return CGEvent(mouse) }
        return nil
    }
}
enum Logger { static let itemManager = Log() }
struct Log { func debug(_ text: String) {} }
final class Manager {
    enum Failure: Error { case eventDelivery }
    var failOn: CGEvent.Mouse? = .leftMouseDown
    var releases = 0
    var lastMouseMoveStartDate: Date?
    func getCurrentFrame(for item: MenuBarItem) -> CGRect? { CGRect(x: 771, y: 0, width: 38, height: 33) }
    func scrombleEvent(_ event: CGEvent, from: Location, to: Location, item: MenuBarItem) async throws {
        if event.mouse == failOn { throw Failure.eventDelivery }
    }
    func postEvent(_ event: CGEvent, to: Location) { if event.mouse == .leftMouseUp { releases += 1 } }
    // WAKE
    // INPUT
}
@main struct Tests {
    static func main() async {
        var failures = 0
        func check(_ passed: Bool, _ name: String) {
            print("\(passed ? "PASS" : "FAIL"): \(name)"); if !passed { failures += 1 }
        }
        for failure in [CGEvent.Mouse.leftMouseDown, .leftMouseUp] {
            let manager = Manager(); manager.failOn = failure
            do { try await manager.wakeUpItem(MenuBarItem()) } catch {}
            check(manager.releases == 2, "failed \(failure) acknowledgement releases at both event routes")
        }
        let manager = Manager(); manager.failOn = nil
        do { try await manager.wakeUpItem(MenuBarItem()) } catch {}
        check(manager.releases == 0, "successful wake-up does not inject an extra release")
        Input.flags = [.capsLock, .numericPad]
        do {
            try await manager.waitForLayoutMoveInput(timeout: .milliseconds(20))
            check(true, "latched Caps Lock does not block a Layout move")
        } catch { check(false, "latched Caps Lock does not block a Layout move") }
        Input.flags = .command
        do {
            try await manager.waitForLayoutMoveInput(timeout: .milliseconds(20))
            check(false, "held Command expires the bounded input wait")
        } catch is TaskTimeoutError { check(true, "held Command expires the bounded input wait") }
          catch { check(false, "held Command expires the bounded input wait") }
        Input.flags = []
        manager.lastMouseMoveStartDate = Date.now
        do {
            try await manager.waitForLayoutMoveInput(timeout: .milliseconds(20))
            check(false, "moving pointer expires the bounded input wait")
        } catch is TaskTimeoutError { check(true, "moving pointer expires the bounded input wait") }
          catch { check(false, "moving pointer expires the bounded input wait") }
        let task = Task {
            do { try await manager.waitForLayoutMoveInput(timeout: .seconds(2)); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        task.cancel()
        check(await task.value, "cancelled preparation cannot start a native drag")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ice-transport-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let file = directory.appendingPathComponent("test.swift")
try fixture.replacingOccurrences(of: "// WAKE", with: extract("    private func wakeUpItem("))
    .replacingOccurrences(of: "// INPUT", with: extract("    private func waitForLayoutMoveInput("))
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
