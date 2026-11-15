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

    public enum Hit {
        case window(WindowInfo, AXUIElement)
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

        // Walk up from the element under the mouse to its window.
        var current: AXUIElement? = element
        for _ in 0..<30 {
            guard let node = current else { break }
            let role = string(node, kAXRoleAttribute) ?? ""
            if menuRoles.contains(role) { return .skip("menu (\(role))") }
            if role == kAXWindowRole {
                guard let id = Private.windowID(of: node) else { break }
                guard let info = windows.first(where: { $0.id == id }) else {
                    return .skip("window #\(id) is not in the on-screen list")
                }
                guard info.layer == 0 else { return .skip("not a normal window: \(info.description)") }
                return .window(info, node)
            }
            current = parent(of: node)
        }
        return fallbackHit(at: point, in: windows)
    }

    /// When Accessibility gives no window: the WindowServer's list, top to bottom.
    private static func fallbackHit(at point: CGPoint, in windows: [WindowInfo]) -> Hit {
        guard let top = topmost(at: point, in: windows.filter { $0.owner != "Dock" }) else {
            return .skip("no window under the mouse")
        }
        guard top.layer == 0 else { return .skip("not a normal window: \(top.description)") }
        guard let ax = axWindow(id: top.id, pid: top.pid) else {
            return .skip("no accessibility window for \(top.description)")
        }
        return .window(top, ax)
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
    /// Asks Accessibility, not NSWorkspace.frontmostApplication: NSWorkspace only
    /// updates that value while the main run loop turns, so it can be stale.
    public static func focused() -> (id: CGWindowID, pid: pid_t)? {
        guard let axApp = element(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute),
              let window = element(axApp, kAXFocusedWindowAttribute),
              let id = Private.windowID(of: window) else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(axApp, &pid)
        return (id, pid)
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
