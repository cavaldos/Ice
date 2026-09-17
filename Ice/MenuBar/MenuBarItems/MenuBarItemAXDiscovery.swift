//
//  MenuBarItemAXDiscovery.swift
//  Ice
//

import ApplicationServices
import Carbon.HIToolbox
import Cocoa

/// Liệt kê menu bar items qua Accessibility (`AXExtrasMenuBar`).
///
/// Cách này chỉ cần quyền Accessibility, không cần Screen Recording,
/// và vẫn hoạt động khi `CGSGetProcessMenuBarWindowList` không còn trả về
/// per-item windows (macOS 27+) — cùng cách mà Thaw dùng.
enum MenuBarItemAXDiscovery {
    /// Một menu bar item đọc được qua Accessibility.
    struct AXMenuBarItem: Hashable {
        /// Process identifier của app sở hữu item. Dùng để lấy app icon.
        let pid: pid_t

        /// Tên hiển thị của app sở hữu item.
        let appName: String

        /// Bundle identifier của app sở hữu item.
        let bundleID: String?

        /// `AXIdentifier` của item (vd `com.apple.menuextra.wifi`).
        let identifier: String?

        /// Tiêu đề/mô tả của item (có thể nil với icon thuần).
        let title: String?

        /// Frame raw của item theo tọa độ AX (origin top-left).
        /// Convert sang tọa độ Cocoa khi phân loại.
        let axFrame: CGRect?

        /// Tên chi tiết nhất để hiển thị.
        var displayName: String {
            title ?? identifier ?? appName
        }
    }

    /// Nhóm menubar mà một item đang thuộc về.
    enum SectionKind: Hashable {
        case visible
        case hidden
        case alwaysHidden
    }

    /// Phân loại item theo vị trí ngang của nó so với các vạch chia của Ice.
    ///
    /// Trục X giống nhau ở cả tọa độ AX lẫn Cocoa (chỉ trục Y bị lật),
    /// nên gọi được cho cả frame AX lẫn frame window CGS.
    ///
    /// Mỗi vạch được xét độc lập để vẫn đúng khi một section bị tắt
    /// (vạch tương ứng nil): trái vạch Always-Hidden → alwaysHidden,
    /// trái vạch Hidden → hidden, còn lại → visible.
    ///
    /// - Parameters:
    ///   - centerX: Tâm X của item, nil khi không đọc được (về Visible).
    ///   - hiddenDividerX: Cạnh trái (minX) của vạch Hidden, nil khi section tắt.
    ///   - alwaysHiddenDividerX: Cạnh trái của vạch Always Hidden, nil khi section tắt.
    static func classify(
        centerX: CGFloat?,
        hiddenDividerX: CGFloat?,
        alwaysHiddenDividerX: CGFloat?
    ) -> SectionKind {
        guard let centerX else {
            return .visible
        }
        if let alwaysHiddenDividerX, centerX < alwaysHiddenDividerX {
            return .alwaysHidden
        }
        if let hiddenDividerX, centerX < hiddenDividerX {
            return .hidden
        }
        return .visible
    }

    /// Trả về true khi app đã được cấp quyền Accessibility.
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Icon của input source đang dùng (bộ gõ/chữ trên menubar).
    ///
    /// Dùng cho item của TextInputMenuAgent — app này không có icon riêng,
    /// icon thật trên menubar chính là icon của input source hiện tại.
    static func inputSourceIcon() -> NSImage? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyIconImageURL) else {
            return nil
        }
        let url = Unmanaged<CFURL>.fromOpaque(pointer).takeUnretainedValue() as URL
        return NSImage(contentsOf: url)
    }

    /// SF Symbol cho các system menu extras quen thuộc.
    ///
    /// Các item này thường bị host bởi MenuBarAgent nên app icon lấy theo
    /// PID sẽ ra icon chung chung, không đúng.
    static func systemImageName(forIdentifier identifier: String?) -> String? {
        switch identifier {
        case "com.apple.menuextra.wifi": "wifi"
        case "com.apple.menuextra.sound": "speaker.wave.2.fill"
        case "com.apple.menuextra.bluetooth": "bluetooth"
        case "com.apple.menuextra.battery": "battery.100"
        case "com.apple.menuextra.controlcenter": "switch.2"
        case "com.apple.menuextra.clock": "clock"
        case "com.apple.menuextra.spotlight": "magnifyingglass"
        case "com.apple.menuextra.airplay": "airplayvideo"
        default: nil
        }
    }

    /// Liệt kê tất cả menu bar items của các app đang chạy.
    ///
    /// - Parameter apps: Các app cần quét. Truyền `NSWorkspace.shared.runningApplications`
    ///   từ main thread.
    /// - Returns: Danh sách item, sắp xếp theo tên hiển thị.
    static func discoverItems(in apps: [NSRunningApplication]) -> [AXMenuBarItem] {
        guard isTrusted() else {
            return []
        }
        // Bỏ icon của chính Ice (các vạch chia) khỏi danh sách.
        let ownBundleID = Bundle.main.bundleIdentifier
        var result = [AXMenuBarItem]()
        var visited = 0
        for app in apps {
            guard visited < maxElementsVisited else {
                break
            }
            guard app.bundleIdentifier != ownBundleID else {
                continue
            }
            result.append(contentsOf: items(for: app, visited: &visited))
        }
        return result.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Nhấn (AXPress) menu bar item khớp với pid/identifier/title cho trước.
    ///
    /// Dùng cho Ice Bar trên macOS 27: không còn CGS window để temp-show +
    /// click, nên nhấn trực tiếp qua Accessibility rồi để hệ thống mở menu.
    /// AXPress không phân biệt trái/phải — hầu hết extras bỏ qua chuột phải
    /// nên Ice Bar dùng chung một action cho cả hai. Chạy nền (mỗi app có
    /// thể block tới ~1s theo messaging timeout), trả về true khi đã nhấn.
    ///
    /// Không khớp identifier/title nào (item không tên) thì nhấn item đầu
    /// tiên của app — đủ tốt cho bản đầu, sai số nhỏ hơn bar trống.
    static func press(pid: pid_t, identifier: String?, title: String?) -> Bool {
        guard isTrusted() else {
            return false
        }
        let axApp = AXUIElementCreateApplication(pid)
        // ponytail: timeout ngắn cho mỗi app — một app treo không được
        // block cả lần nhấn (mặc định hệ thống chờ tới 6s).
        AXUIElementSetMessagingTimeout(axApp, 1)

        var bar: AnyObject?
        guard
            AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &bar) == .success,
            let bar,
            CFGetTypeID(bar) == AXUIElementGetTypeID()
        else {
            return false
        }
        // swiftlint:disable:next force_cast
        let barElement = bar as! AXUIElement
        var visited = 0
        return pressFirstMatch(from: barElement, identifier: identifier, title: title, depth: maxWalkDepth, visited: &visited)
    }

    /// Đi sâu cây AX và nhấn item đầu tiên khớp identifier/title.
    ///
    /// Mirror `collectItems`: bỏ qua cả cây `AXMenu`/`AXMenuItem` (nội dung
    /// dropdown), `AXMenuBarItem` khớp thì nhấn luôn không đi sâu, element
    /// bọc ngoài chỉ thử nhấn khi bên trong không có gì nhấn được.
    private static func pressFirstMatch(
        from element: AXUIElement,
        identifier: String?,
        title: String?,
        depth: Int,
        visited: inout Int
    ) -> Bool {
        guard depth > 0, visited < maxElementsVisited else {
            return false
        }
        visited += 1

        let role = stringAttribute(kAXRoleAttribute as CFString, of: element)

        guard role != "AXMenu", role != "AXMenuItem" else {
            return false
        }

        if role == "AXMenuBarItem" {
            guard matches(element, identifier: identifier, title: title) else {
                return false
            }
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }

        var children: AnyObject?
        if
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
            let elements = children as? [AXUIElement],
            !elements.isEmpty
        {
            for child in elements {
                let pressed = pressFirstMatch(from: child, identifier: identifier, title: title, depth: depth - 1, visited: &visited)
                if pressed {
                    return true
                }
            }
        }

        // Không child nào nhấn được → thử chính element này khi nó có identity
        // khớp (mirror `record` với recordNameless: false).
        guard matches(element, identifier: identifier, title: title, requireIdentity: true) else {
            return false
        }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// True khi element khớp identifier/title cho trước (nil = không ràng buộc).
    private static func matches(_ element: AXUIElement, identifier: String?, title: String?, requireIdentity: Bool = false) -> Bool {
        let candidateID = stringAttribute("AXIdentifier" as CFString, of: element)
        let candidateTitle = stringAttribute(kAXTitleAttribute as CFString, of: element)
            ?? stringAttribute(kAXDescriptionAttribute as CFString, of: element)
            ?? stringAttribute(kAXHelpAttribute as CFString, of: element)
        if requireIdentity, candidateID == nil, candidateTitle == nil {
            return false
        }
        if let identifier, candidateID != identifier {
            return false
        }
        if let title, candidateTitle != title {
            return false
        }
        return true
    }

    /// Khung (tọa độ AX, cùng hệ với `AXMenuBarItem.axFrame`) của các vạch
    /// chia của Ice, tra qua Accessibility.
    ///
    /// Trên macOS 27 `NSStatusItem.button.window.frame` trả về rect của spacer
    /// chứ không phải vị trí chevron, nên Ice Bar không thể dùng nó để phân
    /// loại section. Vạch được định danh bằng `accessibilityIdentifier` do
    /// ControlItem tự đặt nên tra cứu này chính xác và không phụ thuộc layout
    /// của window. Chỉ đọc app của chính mình nên nhanh, gọi nền được.
    ///
    /// - Note: Khi spacer đang nở (section ẩn), window của vạch bị park
    ///   offscreen và frame trả về là rect rác (rộng hàng trăm pt, nằm dưới
    ///   đáy màn hình). Luôn lọc qua ``isSettledDividerFrame(_:)`` trước khi
    ///   dùng `minX` để phân loại.
    static func dividerFrames() -> (hidden: CGRect?, alwaysHidden: CGRect?) {
        guard isTrusted() else {
            return (nil, nil)
        }
        let axApp = AXUIElementCreateApplication(NSRunningApplication.current.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1)

        var bar: AnyObject?
        guard
            AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &bar) == .success,
            let bar,
            CFGetTypeID(bar) == AXUIElementGetTypeID()
        else {
            return (nil, nil)
        }
        // swiftlint:disable:next force_cast
        let barElement = bar as! AXUIElement
        var visited = 0
        var found = [String: CGRect]()
        collectDividerFrames(from: barElement, depth: maxWalkDepth, visited: &visited, into: &found)
        return (found["IceHiddenDivider"], found["IceAlwaysHiddenDivider"])
    }

    /// Frame AX có trông như vạch chia thật trong menubar không.
    ///
    /// Spacer nở (section ẩn) cho frame RỘNG (hàng trăm pt) nhưng minX vẫn
    /// đúng vị trí chevron và minY vẫn trong dải menubar — giữ lại để lấy
    /// minX phân loại. Chỉ loại frame rác park offscreen (minY dưới đáy
    /// màn hình, vd 986) hoặc minX dính mép trái.
    static func isSettledDividerFrame(_ frame: CGRect) -> Bool {
        frame.minY <= 100 && frame.minX > 100
    }

    /// Thu thập khung của các element mang `accessibilityIdentifier` của Ice.
    ///
    /// Mirror `collectItems` (bỏ qua cây `AXMenu`/`AXMenuItem`, đi sâu tối đa
    /// `maxWalkDepth`), nhưng ghi nhận frame theo identifier thay vì dựng item.
    /// Identifier có thể nằm ở element bọc ngoài hoặc button bên trong — lấy
    /// frame đầu tiên tìm thấy cho mỗi identifier.
    private static func collectDividerFrames(
        from element: AXUIElement,
        depth: Int,
        visited: inout Int,
        into result: inout [String: CGRect]
    ) {
        guard depth > 0, visited < maxElementsVisited else {
            return
        }
        visited += 1

        let role = stringAttribute(kAXRoleAttribute as CFString, of: element)

        guard role != "AXMenu", role != "AXMenuItem" else {
            return
        }

        if
            let identifier = stringAttribute("AXIdentifier" as CFString, of: element),
            identifier == "IceHiddenDivider" || identifier == "IceAlwaysHiddenDivider",
            result[identifier] == nil,
            let frame = frame(of: element)
        {
            result[identifier] = frame
        }

        var children: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
            let elements = children as? [AXUIElement]
        else {
            return
        }
        for child in elements {
            collectDividerFrames(from: child, depth: depth - 1, visited: &visited, into: &result)
        }
    }

    /// Số element tối đa được đọc trong một lần quét.
    private static let maxElementsVisited = 256

    /// Độ sâu tối đa khi đi xuống cây AX.
    ///
    /// Item thật thường nằm ở cấp cháu (vd `AXGroup` → `AXMenuBarItem`
    /// trong MenuBarAgent), nên phải đi sâu thay vì chỉ đọc children
    /// trực tiếp của `AXExtrasMenuBar`.
    private static let maxWalkDepth = 4

    /// Đọc `AXExtrasMenuBar` của một app.
    private static func items(for app: NSRunningApplication, visited: inout Int) -> [AXMenuBarItem] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // ponytail: timeout ngắn cho mỗi app — một app treo không được
        // block cả lần quét (mặc định hệ thống chờ tới 6s).
        AXUIElementSetMessagingTimeout(axApp, 1)

        var bar: AnyObject?
        guard
            AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &bar) == .success,
            let bar,
            CFGetTypeID(bar) == AXUIElementGetTypeID()
        else {
            return []
        }
        // swiftlint:disable:next force_cast
        let barElement = bar as! AXUIElement

        let appName = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
        var result = [AXMenuBarItem]()
        collectItems(
            from: barElement,
            pid: app.processIdentifier,
            appName: appName,
            bundleID: app.bundleIdentifier,
            depth: maxWalkDepth,
            visited: &visited,
            into: &result
        )
        return result
    }

    /// Thu thập item từ một AX element.
    ///
    /// - `AXMenu`/`AXMenuItem` là nội dung dropdown, bỏ qua cả cây.
    /// - `AXMenuBarItem` là icon thật, ghi nhận luôn, không đi sâu.
    /// - Còn lại (group bọc ngoài…) thì đi sâu trước; chỉ ghi nhận element
    ///   ngoài khi bên trong không có item nào.
    private static func collectItems(
        from element: AXUIElement,
        pid: pid_t,
        appName: String,
        bundleID: String?,
        depth: Int,
        visited: inout Int,
        into result: inout [AXMenuBarItem]
    ) {
        guard depth > 0, visited < maxElementsVisited else {
            return
        }
        visited += 1

        let role = stringAttribute(kAXRoleAttribute as CFString, of: element)

        guard role != "AXMenu", role != "AXMenuItem" else {
            return
        }

        if role == "AXMenuBarItem" {
            record(element, pid: pid, appName: appName, bundleID: bundleID, into: &result, recordNameless: true)
            return
        }

        var children: AnyObject?
        if
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
            let elements = children as? [AXUIElement],
            !elements.isEmpty
        {
            let countBefore = result.count
            for child in elements {
                collectItems(from: child, pid: pid, appName: appName, bundleID: bundleID, depth: depth - 1, visited: &visited, into: &result)
            }
            // Có child là item thì bỏ qua element bọc ngoài.
            guard result.count == countBefore else {
                return
            }
        }

        record(element, pid: pid, appName: appName, bundleID: bundleID, into: &result, recordNameless: false)
    }

    /// Ghi nhận một element thành item khi nó có identity.
    private static func record(
        _ element: AXUIElement,
        pid: pid_t,
        appName: String,
        bundleID: String?,
        into result: inout [AXMenuBarItem],
        recordNameless: Bool
    ) {
        let identifier = stringAttribute("AXIdentifier" as CFString, of: element)
        let title = stringAttribute(kAXTitleAttribute as CFString, of: element)
            ?? stringAttribute(kAXDescriptionAttribute as CFString, of: element)
            ?? stringAttribute(kAXHelpAttribute as CFString, of: element)

        guard identifier != nil || title != nil || recordNameless else {
            return
        }
        result.append(
            AXMenuBarItem(
                pid: pid,
                appName: appName,
                bundleID: bundleID,
                identifier: identifier,
                title: title,
                axFrame: frame(of: element)
            )
        )
    }

    /// Đọc frame raw (tọa độ AX) của element, nil khi không có.
    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: AnyObject?
        var size: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
            let position, let size,
            CFGetTypeID(position) == AXValueGetTypeID(),
            CFGetTypeID(size) == AXValueGetTypeID()
        else {
            return nil
        }
        // swiftlint:disable:next force_cast
        let positionValue = position as! AXValue
        // swiftlint:disable:next force_cast
        let sizeValue = size as! AXValue
        var point = CGPoint.zero
        var cgSize = CGSize.zero
        guard
            AXValueGetValue(positionValue, .cgPoint, &point),
            AXValueGetValue(sizeValue, .cgSize, &cgSize)
        else {
            return nil
        }
        return CGRect(origin: point, size: cgSize)
    }

    /// Đọc một string attribute của AX element, nil khi không có/lỗi.
    private static func stringAttribute(_ attribute: CFString, of element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let string = value as? String,
              !string.isEmpty
        else {
            return nil
        }
        return string
    }
}
