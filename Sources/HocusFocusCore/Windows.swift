import AppKit
import ApplicationServices

/// A window as the WindowServer sees it, from CGWindowListCopyWindowInfo.
public struct WindowInfo {
    public let id: CGWindowID
    public let pid: pid_t
    public let layer: Int
    public let bounds: CGRect
    public let owner: String
    public let title: String

    /// Too small to be a real window. While the screen is recorded, macOS 26 puts a 66 × 20 point
    /// window on each title bar (its recording indicator), which the app reports as a dialog.
    public var isTiny: Bool { bounds.width < 120 && bounds.height < 60 }

    public var description: String {
        let name = title.isEmpty ? owner : "\(owner) — \(title)"
        return "#\(id) pid \(pid) layer \(layer) \(name)"
    }
}

public enum Windows {
    /// On-screen windows, front to back, all layers.
    public static func onScreen() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0, bounds.width > 1, bounds.height > 1 else { return nil }
            return WindowInfo(
                id: id, pid: pid, layer: layer, bounds: bounds,
                owner: info[kCGWindowOwnerName as String] as? String ?? "?",
                title: info[kCGWindowName as String] as? String ?? ""
            )
        }
    }

    /// The window drawn on top at a point (global coordinates, origin top left).
    /// Uses the WindowServer's list rather than the Accessibility hit test, which does
    /// not see some windows (Quick Look, for example).
    public static func topmost(at point: CGPoint, in windows: [WindowInfo] = onScreen()) -> WindowInfo? {
        // The mouse cursor is itself a window, owned by the WindowServer, above everything.
        let cursorLevel = Int(CGWindowLevelForKey(.cursorWindow))
        return windows.first {
            $0.bounds.contains(point) && $0.layer < cursorLevel && $0.owner != "Window Server"
        }
    }

    /// The app that owns what is under a point: a window, the Dock, Finder's desktop...
    public static func pid(at point: CGPoint) -> pid_t? {
        var raw: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &raw) == .success,
              let element = raw else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    /// The point of a window nearest its center that is on a display and that no window of a
    /// normal app covers. Nil when the window is hidden. Overlays of background apps (the Dock,
    /// JankyBorders) let the mouse through, so they don't count.
    public static func visiblePoint(of window: WindowInfo, in windows: [WindowInfo] = onScreen()) -> CGPoint? {
        guard let index = windows.firstIndex(where: { $0.id == window.id }) else { return nil }
        let cursorLevel = Int(CGWindowLevelForKey(.cursorWindow))
        let covers = windows[..<index].filter {
            $0.layer < cursorLevel && !$0.isTiny
                && NSRunningApplication(processIdentifier: $0.pid)?.activationPolicy == .regular
        }.map(\.bounds)
        let b = window.bounds, center = CGPoint(x: b.midX, y: b.midY)
        let steps = 8
        var candidates: [CGPoint] = []
        for i in 1..<steps {
            for j in 1..<steps {
                candidates.append(CGPoint(x: b.minX + b.width * CGFloat(i) / CGFloat(steps),
                                          y: b.minY + b.height * CGFloat(j) / CGFloat(steps)))
            }
        }
        candidates.sort { hypot($0.x - center.x, $0.y - center.y) < hypot($1.x - center.x, $1.y - center.y) }
        return candidates.first { point in
            var displays: UInt32 = 0
            CGGetDisplaysWithPoint(point, 0, nil, &displays)
            return displays > 0 && !covers.contains { $0.contains(point) }
        }
    }

    public enum Hit {
        /// The Accessibility element is nil when the app does not expose that window.
        case window(WindowInfo, AXUIElement?)
        case skip(String)
    }

    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        // An app that does not answer must not block the tool for the default 6 s.
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }()

    private static let menuRoles: Set<String> = [
        kAXMenuRole, kAXMenuBarRole, kAXMenuItemRole, kAXMenuBarItemRole,
    ]

    /// The normal window that would receive a click at a point.
    ///
    /// Asks Accessibility first, because it knows which windows let the mouse through.
    /// The Dock, for example, has a transparent window over the whole main screen, and
    /// only its icons take the mouse. Borders drawn by JankyBorders are the same.
    public static func hit(at point: CGPoint) -> Hit {
        let windows = onScreen()
        var raw: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &raw) == .success,
              let element = raw else {
            return fallbackHit(at: point, in: windows)
        }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock" {
            return .skip("Dock")
        }

        // Walk up from the element under the mouse to its window. A menu item sits right
        // under its menu, so the first levels are checked for menus before jumping
        // straight to the window: in web content (Electron apps such as Claude), the
        // element can be more than 50 levels deep.
        var current: AXUIElement? = element
        for depth in 0..<200 {
            guard let node = current else { break }
            let role = string(node, kAXRoleAttribute) ?? ""
            if menuRoles.contains(role) { return .skip("menu (\(role))") }
            if role == kAXWindowRole {
                guard let id = Private.windowID(of: node) else { break }
                guard let info = windows.first(where: { $0.id == id }) else {
                    return .skip("window #\(id) is not in the on-screen list")
                }
                guard info.layer == 0 else { return .skip("not a normal window: \(info.description)") }
                guard !info.isTiny else { return .skip("tiny window (recording indicator?): \(info.description)") }
                return .window(info, node)
            }
            if depth == 1, let window = self.element(node, kAXWindowAttribute) {
                current = window
            } else {
                current = parent(of: node)
            }
        }
        return fallbackHit(at: point, in: windows)
    }

    /// When Accessibility gives no window: the WindowServer's list, top to bottom, with
    /// only the windows of normal apps. Overlays such as the borders of JankyBorders
    /// belong to background apps and let the mouse through.
    private static func fallbackHit(at point: CGPoint, in windows: [WindowInfo]) -> Hit {
        let regular = windows.filter {
            $0.layer == 0 && NSRunningApplication(processIdentifier: $0.pid)?.activationPolicy == .regular
        }
        guard let top = topmost(at: point, in: regular) else {
            return .skip("no window under the mouse")
        }
        return .window(top, axWindow(id: top.id, pid: top.pid))
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// The Accessibility element of a window, found among its app's windows.
    public static func axWindow(id: CGWindowID, pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { Private.windowID(of: $0) == id }
    }

    public static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// The window that has the keyboard focus right now, and its app.
    ///
    /// The active app comes from the WindowServer (SkyLight). Asking Accessibility
    /// (kAXFocusedApplicationAttribute) often fails with error -25204, "cannot
    /// complete"; it stays as a second way, then NSWorkspace. The focused window is
    /// then asked to that app.
    public static func focused() -> (id: CGWindowID, pid: pid_t)? {
        var pid = Private.frontmostPID()
        if pid == nil, let axApp = element(systemWide, kAXFocusedApplicationAttribute) {
            var axPID: pid_t = 0
            if AXUIElementGetPid(axApp, &axPID) == .success { pid = axPID }
        }
        if pid == nil { pid = NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard let pid else { return nil }

        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        guard let window = element(axApp, kAXFocusedWindowAttribute) ?? element(axApp, kAXMainWindowAttribute),
              let id = Private.windowID(of: window) else { return nil }
        return (id, pid)
    }

    private static let popupSubroles: Set<String> = [kAXDialogSubrole, kAXSystemDialogSubrole, "AXSheet"]

    public struct Popup {
        public let window: WindowInfo
        /// True for menus, popovers and modal panels: the focus must not move at all, or
        /// the menu would close. False for dialogs, sheets and secondary windows: only
        /// the other windows of the same app are kept from taking the focus.
        public let blocksAll: Bool
    }

    /// The popup the app shows in front of its focused window, if any: a menu, popover,
    /// modal panel, dialog or sheet of that same app. The focused window itself counts:
    /// while a dialog is open, it is often the focused window. A focused secondary
    /// window (settings, about, inspector) counts too, see `isSecondary`.
    ///
    /// Not counted: floating "always on top" windows and palettes (layers 3 and 19),
    /// and other standard windows of the app, which focus without raise often leaves in
    /// front of the focused one.
    public static func popup(over focused: (id: CGWindowID, pid: pid_t), in windows: [WindowInfo] = onScreen()) -> Popup? {
        guard let index = windows.firstIndex(where: { $0.id == focused.id }) else { return nil }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let modalLevel = Int(CGWindowLevelForKey(.modalPanelWindow))
        let cursorLevel = Int(CGWindowLevelForKey(.cursorWindow))
        for window in windows[...index] where window.pid == focused.pid {
            switch window.layer {
            case menuLevel..<cursorLevel, modalLevel:
                return Popup(window: window, blocksAll: true)
            case 0:
                // macOS's recording indicators are tiny "dialogs" in front of every window.
                if window.isTiny { continue }
                // Hidden from Accessibility: most likely a popover or another transient.
                guard let ax = axWindow(id: window.id, pid: window.pid) else { return Popup(window: window, blocksAll: true) }
                if popupSubroles.contains(string(ax, kAXSubroleAttribute) ?? "")
                    || (window.id == focused.id && isSecondary(ax)) {
                    return Popup(window: window, blocksAll: false)
                }
            default:
                continue
            }
        }
        return nil
    }

    /// A secondary window: its minimize and zoom buttons are both disabled or missing.
    /// Settings, about and inspector windows are like that (RandAmp's settings, for
    /// example); main windows can be minimized. While such a window has the focus, the
    /// mouse often has to cross the app's main window to reach it.
    public static func isSecondary(_ window: AXUIElement) -> Bool {
        !buttonEnabled(window, kAXMinimizeButtonAttribute) && !buttonEnabled(window, kAXZoomButtonAttribute)
    }

    /// The app's own focused window when it is a popup-like window: a dialog, a sheet
    /// or a secondary window (settings...). An app that is not active keeps its focused
    /// window, so when the mouse comes back to the app, that window can get the focus
    /// again instead of the one under the mouse.
    public static func pendingPopup(ofApp pid: pid_t, in windows: [WindowInfo] = onScreen()) -> (WindowInfo, AXUIElement)? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let window = element(app, kAXFocusedWindowAttribute),
              let id = Private.windowID(of: window),
              let info = windows.first(where: { $0.id == id && $0.layer == 0 && !$0.isTiny }) else { return nil }
        let isPopup = popupSubroles.contains(string(window, kAXSubroleAttribute) ?? "") || isSecondary(window)
        return isPopup ? (info, window) : nil
    }

    private static func buttonEnabled(_ window: AXUIElement, _ attribute: String) -> Bool {
        guard let button = element(window, attribute) else { return false }
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(button, kAXEnabledAttribute as CFString, &value)
        return (value as? Bool) ?? false
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
