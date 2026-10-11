//
//  MenuBarItemAXMover.swift
//  Ice
//

import Cocoa

/// Moves a menu bar item by simulating the user's Command-drag.
///
/// Ice's old move pipeline needed a CGS window (windowID, ownerPID, frame change),
/// so it no longer works on macOS 27. This approach only needs the icon's
/// on-screen position plus Accessibility permission — exactly what the user
/// would do by hand, so the system still honors it.
///
/// Quartz coordinates (origin top-left, same system as `CGEvent.location`,
/// `WindowInfo.frame`, and `AXUIElement` frames) — do NOT use Cocoa coordinates
/// (origin bottom-left) here; mixing them up drops the item in the wrong spot
/// and a rescan then shows the old position (looking like it "snapped back").
enum MenuBarItemAXMover {
    /// Display-only classification can accept centered AX bounds that extend past
    /// their host window. Native drag targeting retains containment by default.
    static func matchingWindowIndex(for frame: CGRect, in windows: [CGRect], requireContainment: Bool = true) -> Int? {
        guard !frame.isEmpty, !frame.isNull, !frame.isInfinite,
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
        else {
            return nil
        }
        let matches = windows.indices.filter { index in
            let window = windows[index]
            return !window.isEmpty && !window.isInfinite && (!requireContainment || window.contains(frame)) &&
                abs(window.midX - frame.midX) <= 0.5 && abs(window.midY - frame.midY) <= 0.5 &&
                abs(window.width - frame.width) <= 32 && abs(window.height - frame.height) <= 32
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Selects a visible part of an AX frame, never a point inside the notch.
    static func dragPoint(in frame: CGRect, usableRegions: [CGRect]) -> CGPoint? {
        let intersections: [CGRect] = usableRegions.map { frame.intersection($0) }
            .filter { !$0.isNull && $0.width >= 4 && $0.height >= 4 }
        let visible = intersections.max { left, right in
            left.width * left.height < right.width * right.height
        }
        return visible.map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    /// Drags from `source` to `destination` while holding Command.
    ///
    /// Quartz coordinates (origin top-left). Runs in the background, takes well
    /// under a second. The cursor stays visible and is returned to its original
    /// spot; the Command key is always released (even if event creation fails
    /// midway).
    static func commandDrag(from source: CGPoint, to destination: CGPoint) async {
        await Task.detached(priority: .userInitiated) {
            guard let eventSource = CGEventSource(stateID: .hidSystemState) else {
                return
            }

            // Remember the old cursor position to restore after the drag. Don't hide
            // the cursor: a disappearing cursor makes users think the app hung.
            let originalLocation = CGEvent(source: nil)?.location
            defer {
                if let originalLocation {
                    CGWarpMouseCursorPosition(originalLocation)
                }
            }

            func post(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags) {
                let event: CGEvent?
                if type == .flagsChanged {
                    // CGEvent's mouse initializer rejects flagsChanged. Use a
                    // keyboard event so AppKit sees a real Command-key transition.
                    event = CGEvent(keyboardEventSource: eventSource, virtualKey: 55, keyDown: flags.contains(.maskCommand))
                    event?.type = .flagsChanged
                    event?.location = point
                } else {
                    event = CGEvent(
                        mouseEventSource: eventSource,
                        mouseType: type,
                        mouseCursorPosition: point,
                        mouseButton: .left
                    )
                }
                guard let event else {
                    return
                }
                event.flags = flags
                event.post(tap: .cghidEventTap)
            }

            // Release Command on exit no matter what happens below.
            var didPressCommand = false
            defer {
                if didPressCommand {
                    post(.flagsChanged, at: destination, flags: [])
                }
            }

            // Move the cursor onto the icon first so the system "sees" the start point.
            post(.mouseMoved, at: source, flags: [])
            try? await Task.sleep(for: .milliseconds(120))

            // Press Command (flagsChanged) as if the user is holding the key.
            post(.flagsChanged, at: source, flags: .maskCommand)
            didPressCommand = true
            try? await Task.sleep(for: .milliseconds(80))

            post(.leftMouseDown, at: source, flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(120))

            // ponytail: 15 steps are enough for the system to register the drag;
            // 30 steps as before only prolong the cursor freeze.
            let steps = 15
            for index in 1...steps {
                let progress = CGFloat(index) / CGFloat(steps)
                let point = CGPoint(
                    x: source.x + (destination.x - source.x) * progress,
                    y: source.y + (destination.y - source.y) * progress
                )
                post(.leftMouseDragged, at: point, flags: .maskCommand)
                try? await Task.sleep(for: .milliseconds(15))
            }

            post(.leftMouseUp, at: destination, flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(150))

            // Release Command and wait for the system to commit the new position
            // before restoring the cursor.
            post(.flagsChanged, at: destination, flags: [])
            didPressCommand = false
            try? await Task.sleep(for: .milliseconds(350))
        }.value
    }
}
