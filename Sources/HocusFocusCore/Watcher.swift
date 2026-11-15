import AppKit
import ApplicationServices

public struct Settings: Equatable {
    public enum Mode: String, CaseIterable { case focus, raise }

    public enum DisableKey: String, CaseIterable {
        case control, option, command, none

        var flags: CGEventFlags? {
            switch self {
            case .control: .maskControl
            case .option: .maskAlternate
            case .command: .maskCommand
            case .none: nil
            }
        }
    }

    /// Off: the watcher keeps running but changes nothing.
    public var enabled = true
    public var mode: Mode = .focus
    /// How long the mouse must stay still before the window under it gets the focus.
    public var dwell: TimeInterval = 0.15
    /// No focus change while the user typed less than this long ago. 0 turns it off.
    public var typingGuard: TimeInterval = 0.5
    /// Holding this key pauses the focus changes.
    public var disableKey: DisableKey = .control

    public init() {}
}

/// Listens to the mouse and the keyboard, and moves the focus to the window under the
/// mouse once the mouse rests there.
public final class Watcher {
    /// Settings can change while the watcher runs; the next mouse rest uses them.
    public var settings: Settings
    /// Receives one line for each decision. Nil: no log.
    public var log: ((String) -> Void)?
    public var isRunning: Bool { tap != nil }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var dwellTimer: DispatchWorkItem?
    private var lastKeyDown = Date.distantPast
    private var buttonsDown = 0
    private var flags: CGEventFlags = []

    public init(settings: Settings) {
        self.settings = settings
    }

    deinit { stop() }

    /// Starts listening. Fails when the app has no Accessibility access.
    @discardableResult
    public func start() -> Bool {
        if isRunning { return true }
        let types: [CGEventType] = [
            .mouseMoved, .keyDown, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        dwellTimer?.cancel()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            lastKeyDown = Date()
        case .flagsChanged:
            flags = event.flags
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            buttonsDown += 1
            dwellTimer?.cancel()
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            buttonsDown = max(0, buttonsDown - 1)
        case .mouseMoved:
            if settings.enabled { scheduleDwell(at: event.location) }
        default:
            break
        }
    }

    private func scheduleDwell(at point: CGPoint) {
        dwellTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.mouseRested(at: point) }
        dwellTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.dwell, execute: work)
    }

    private func mouseRested(at point: CGPoint) {
        guard settings.enabled else { return }
        write("rest at (\(Int(point.x)), \(Int(point.y)))\(AXIsProcessTrusted() ? "" : ", NO Accessibility access")")
        if let key = settings.disableKey.flags, flags.contains(key) { return write("skip: disable key held") }
        if buttonsDown > 0 { return write("skip: mouse button down") }
        if Date().timeIntervalSince(lastKeyDown) < settings.typingGuard { return write("skip: typing") }

        let current = Windows.focused()

        // The focused app has a pop-up or context menu open: leave the focus where it is.
        // Only that app's windows count: other apps (AutoJankyBorders, Solpaper...) keep
        // windows at the pop-up menu level that are not menus.
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        if let current, Windows.onScreen().contains(where: { $0.layer == menuLevel && $0.pid == current.pid }) {
            return write("skip: a menu is open")
        }

        // Menu bar, Dock, notifications, menus: anything that is not a normal window.
        let target: WindowInfo, axTarget: AXUIElement
        switch Windows.hit(at: point) {
        case .skip(let reason): return write("skip: \(reason)")
        case .window(let info, let ax): (target, axTarget) = (info, ax)
        }

        if current?.id == target.id { return write("already focused: \(target.description)") }

        let subrole = Windows.string(axTarget, kAXSubroleAttribute) ?? "?"
        guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else {
            return write("skip: subrole \(subrole) for \(target.description)")
        }

        if settings.mode == .focus && Private.focusWithoutRaiseAvailable {
            let done = Focus.withoutRaise(target: target.id, current: current?.id)
            write("focus \(done ? "ok" : "FAILED"): \(target.description)")
        } else {
            let done = Focus.raise(axTarget, pid: target.pid)
            write("raise \(done ? "ok" : "FAILED"): \(target.description)")
        }
    }

    private func write(_ message: String) {
        guard let log else { return }
        let time = Date().formatted(.dateTime.hour().minute().second())
        log("[\(time)] \(message)")
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        Unmanaged<Watcher>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
    }
    return Unmanaged.passUnretained(event)
}
