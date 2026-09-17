//
//  MenuBarItemAXMover.swift
//  Ice
//

import Cocoa

/// Di chuyển menu bar item bằng cách giả lập Command-drag của người dùng.
///
/// Pipeline move cũ của Ice cần CGS window (windowID, ownerPID, frame change)
/// nên không còn hoạt động trên macOS 27. Cách này chỉ cần vị trí icon trên
/// màn hình và quyền Accessibility — đúng thao tác mà người dùng vẫn làm
/// bằng tay, nên hệ thống vẫn nhận.
///
/// Tọa độ Quartz (origin top-left, cùng hệ với `CGEvent.location`,
/// `WindowInfo.frame` và `AXUIElement` frame) — KHÔNG dùng tọa độ Cocoa
/// (origin bottom-left) ở đây, nhầm là thả trượt rồi quét lại thấy vị trí
/// cũ (tưởng "tự quay lại").
enum MenuBarItemAXMover {
    /// Kéo từ `source` tới `destination` trong khi giữ Command.
    ///
    /// Tọa độ Quartz (origin top-left). Chạy nền, mất chưa tới 1 giây.
    /// Chuột luôn hiện hình và được trả về đúng chỗ cũ; phím Command luôn
    /// được nhả (kể cả khi tạo event thất bại giữa chừng).
    static func commandDrag(from source: CGPoint, to destination: CGPoint) async {
        await Task.detached(priority: .userInitiated) {
            guard let eventSource = CGEventSource(stateID: .hidSystemState) else {
                return
            }

            // Giữ chỗ chuột cũ để trả về sau khi kéo xong. Không giấu chuột:
            // chuột biến mất làm người dùng tưởng app treo.
            let originalLocation = CGEvent(source: nil)?.location
            defer {
                if let originalLocation {
                    CGWarpMouseCursorPosition(originalLocation)
                }
            }

            func post(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags) {
                guard
                    let event = CGEvent(
                        mouseEventSource: eventSource,
                        mouseType: type,
                        mouseCursorPosition: point,
                        mouseButton: .left
                    )
                else {
                    return
                }
                event.flags = flags
                event.post(tap: .cghidEventTap)
            }

            // Nhả Command lúc kết thúc dù có chuyện gì xảy ra sau đó.
            var didPressCommand = false
            defer {
                if didPressCommand {
                    post(.flagsChanged, at: destination, flags: [])
                }
            }

            // Đưa chuột tới icon trước để hệ thống "thấy" điểm bắt đầu.
            post(.mouseMoved, at: source, flags: [])
            try? await Task.sleep(for: .milliseconds(120))

            // Nhấn Command (flagsChanged) như người dùng giữ phím.
            post(.flagsChanged, at: source, flags: .maskCommand)
            didPressCommand = true
            try? await Task.sleep(for: .milliseconds(80))

            post(.leftMouseDown, at: source, flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(120))

            // ponytail: 15 bước là đủ để hệ thống nhận ra cú kéo;
            // 30 bước như trước chỉ kéo dài thời gian đơ chuột.
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

            // Nhả Command, đợi hệ thống commit vị trí mới trước khi trả về.
            post(.flagsChanged, at: destination, flags: [])
            didPressCommand = false
            try? await Task.sleep(for: .milliseconds(350))
        }.value
    }
}
