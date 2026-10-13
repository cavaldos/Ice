// Exercises production quick/full scan scheduling with controlled measurement timing.
import Foundation
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().path
let source = try String(contentsOfFile: repo + "/Ice/MenuBar/Appearance/MenuBarOverlayPanel.swift", encoding: .utf8)
func method(_ signature: String) -> String {
    let start = source.range(of: signature)!.lowerBound
    let end = source.range(of: "\n    }\n", range: start..<source.endIndex)!.upperBound
    return String(source[start..<end]).replacingOccurrences(of: "private func", with: "func")
}
let fixture = #"""
import Cocoa
// A queue-checking dictionary catches the race deterministically before memory corruption.
struct MainQueueDictionary<Key: Hashable, Value> {
    private var values = [Key: Value]()
    subscript(key: Key) -> Value? {
        get { requireMain(); return values[key] }
        set { requireMain(); values[key] = newValue }
    }
    private func requireMain() {
        guard Thread.isMainThread else {
            print("FAIL: shared overlay dictionary accessed off main thread")
            exit(1)
        }
    }
}
struct Logger {
    static let overlayPanel = Logger()
    func debug(_ message: String) {}
}
final class Overlay {
    enum EdgeVerdict { case added(hitX: CGFloat) }
    struct Measurement { let width: CGFloat; let fullBleed: Bool; let captureActive: Bool }
    static var trailingQuickRanAt = MainQueueDictionary<CGDirectDisplayID, Date>()
    static var trailingWidthCache = MainQueueDictionary<CGDirectDisplayID, (width: CGFloat, date: Date)>()
    static var trailingWidthScanInFlight = Set<CGDirectDisplayID>()
    static let trailingWidthTTL: TimeInterval = 2
    static var settledConcealedWidth = [CGDirectDisplayID: CGFloat]()
    static var settledRevealedWidth = [CGDirectDisplayID: CGFloat]()
    static var displayedTrailingWidth = [CGDirectDisplayID: CGFloat]()
    static var predictiveTarget = [CGDirectDisplayID: CGFloat]()
    static var trailingBurstUntil = [CGDirectDisplayID: Date]()
    static var trailingFullBleed = [CGDirectDisplayID: Bool]()
    static var screenCaptureActive = false
    static let sweepStarted = DispatchSemaphore(value: 0)
    static let releaseSweep = DispatchSemaphore(value: 0)
    static let quickFinished = DispatchSemaphore(value: 0)
    var needsDisplay = false {
        didSet { precondition(Thread.isMainThread, "UI mutation must stay on main") }
    }
    func isConcealed() -> Bool? { true }
    static func settledWidth(for display: CGDirectDisplayID, concealed: Bool?) -> CGFloat? { nil }
    static func persistTrailingWidths() { precondition(Thread.isMainThread) }
    static func isStripOccluded(display: CGDirectDisplayID) -> Bool { false }
    static func quickLeadingEdgeWidth(for display: CGDirectDisplayID, verdict: EdgeVerdict) -> CGFloat? {
        precondition(!Thread.isMainThread, "AX quick measurement must stay off main")
        quickFinished.signal()
        return 320
    }
    static func trailingStatusWidthFallback(for display: CGDirectDisplayID) -> Measurement? {
        precondition(!Thread.isMainThread, "AX sweep must stay off main")
        sweepStarted.signal()
        precondition(releaseSweep.wait(timeout: .now() + 10) == .success)
        return Measurement(width: 400, fullBleed: true, captureActive: true)
    }
    // METHODS
}
func check(_ passed: Bool, _ name: String) {
    guard passed else { print("FAIL: \(name)"); exit(1) }
    print("PASS: \(name)")
}
func pump(until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    check(condition(), "main-queue completion arrives")
}
let view = Overlay()
// Start a new sweep with a quick verdict. Previously this scheduled the dictionary write on a worker.
view.refreshTrailingStatusWidth(for: 1, force: true, quick: .added(hitX: 100))
check(Overlay.sweepStarted.wait(timeout: .now() + 5) == .success, "full sweep starts in background")
pump { Overlay.trailingWidthCache[1]?.width == 320 }
check(Overlay.trailingQuickRanAt[1] != nil, "new sweep records quick throttle on main")
check(Overlay.quickFinished.wait(timeout: .now() + 1) == .success, "quick measurement completes while sweep is blocked")
// Force the already-in-flight branch and allow its next quick measurement.
Overlay.trailingQuickRanAt[1] = .distantPast
Overlay.trailingWidthCache[1] = (200, Date())
view.refreshTrailingStatusWidth(for: 1, force: true, quick: .added(hitX: 120))
pump { Overlay.trailingWidthCache[1]?.width == 320 }
check(Overlay.quickFinished.wait(timeout: .now() + 1) == .success, "in-flight sweep still permits quick correction")
// An immediate burst must be throttled without dispatching another measurement.
for _ in 0..<100 { view.refreshTrailingStatusWidth(for: 1, force: true, quick: .added(hitX: 120)) }
check(Overlay.quickFinished.wait(timeout: .now() + 0.05) == .timedOut, "burst does not queue duplicate quick walks")
Overlay.releaseSweep.signal()
pump { !Overlay.trailingWidthScanInFlight.contains(1) }
check(Overlay.trailingWidthCache[1]?.width == 400, "full sweep corrects quick width")
check(Overlay.settledConcealedWidth[1] == 400, "completed sweep learns settled width")
check(Overlay.trailingFullBleed[1] == true && Overlay.screenCaptureActive, "scan flags land on main")
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ice-overlay-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let file = directory.appendingPathComponent("main.swift")
let methods = ["    private func applyQuickLeadingEdge(", "    private func refreshTrailingStatusWidth("]
    .map(method).joined(separator: "\n")
try fixture.replacingOccurrences(of: "// METHODS", with: methods).write(to: file, atomically: true, encoding: .utf8)
let binary = directory.appendingPathComponent("test")
let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = [file.path, "-o", binary.path]
if ProcessInfo.processInfo.environment["ICE_TEST_TSAN"] == "1" { compiler.arguments!.append("-sanitize=thread") }
try compiler.run(); compiler.waitUntilExit()
if compiler.terminationStatus != 0 { exit(compiler.terminationStatus) }
let test = Process(); test.executableURL = binary
try test.run(); test.waitUntilExit()
exit(test.terminationStatus)
