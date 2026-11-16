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

    /// Which apps can get the focus: all of them, all except a list, or only a list.
    public enum AppFilter: String, CaseIterable { case all, except, only }
    public var appFilter: AppFilter = .all
    /// Bundle identifiers that never get the focus, in the `except` mode.
    public var exceptApps: Set<String> = []
    /// Bundle identifiers that alone get the focus, in the `only` mode.
    public var onlyApps: Set<String> = []

    /// When an app becomes active from the keyboard (⌘Tab, a shortcut, Spotlight) or the Dock, put
    /// the pointer on its focused window. Otherwise the next nudge of the mouse would give the
    /// focus back to the window that happens to be under the pointer.
    public var movePointer = true

    /// True when the app with this bundle identifier can get the focus.
    public func allows(_ bundleID: String?) -> Bool {
        switch appFilter {
        case .all: true
        case .except: !exceptApps.contains(bundleID ?? "")
        case .only: onlyApps.contains(bundleID ?? "")
        }
    }

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
    private var lastMouseDown = (date: Date.distantPast, point: CGPoint.zero)
    private var lastMouseMove = Date.distantPast
    /// The app HocusFocus itself just focused: its activation must not move the pointer.
    private var ownActivation = (pid: pid_t(0), date: Date.distantPast)
    private var activationObserver: NSObjectProtocol?
    private var pointerMove: DispatchWorkItem?

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
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appActivated(app)
        }
        return true
    }

    public func stop() {
        dwellTimer?.cancel()
        pointerMove?.cancel()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
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
            lastMouseDown = (Date(), event.location)
            dwellTimer?.cancel()
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            buttonsDown = max(0, buttonsDown - 1)
        case .mouseMoved:
            lastMouseMove = Date()
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
        let windows = Windows.onScreen()

        // The focused app shows a menu, popover, sheet, dialog or panel in front of its
        // window: leave the focus where it is. Only that app's windows count: other apps
        // (AutoJankyBorders, Solpaper...) keep windows above that are not popups.
        let popup = current.flatMap { Windows.popup(over: $0, in: windows) }
        if let popup, popup.blocksAll {
            return write("skip: menu open: \(popup.window.description)")
        }

        // Menu bar, Dock, notifications, menus: anything that is not a normal window.
        var target: WindowInfo, axTarget: AXUIElement?
        switch Windows.hit(at: point) {
        case .skip(let reason): return write("skip: \(reason)")
        case .window(let info, let ax): (target, axTarget) = (info, ax)
        }

        // Coming back to an app that left a popup-like window focused (its settings, a
        // dialog): give the focus back to that window, not to the one under the mouse,
        // so the popup is not hidden behind the app's main window.
        // A dialog, sheet or secondary window (settings) has the focus: the other windows
        // of that app don't take it, since the mouse often crosses the main window to
        // reach the popup. Other apps can take it; coming back gives it to the popup again.
        if let popup, target.pid == popup.window.pid, target.id != popup.window.id {
            return write("skip: popup open in the same app: \(popup.window.description)")
        }

        var raisePopup = false
        if target.pid != current?.pid, let (popup, ax) = Windows.pendingPopup(ofApp: target.pid, in: windows),
           popup.id != target.id {
            write("back to the app's popup: \(popup.description) instead of #\(target.id)")
            (target, axTarget) = (popup, ax)
            raisePopup = true
        }

        if current?.id == target.id { return write("already focused: \(target.description)") }

        let bundleID = NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier
        guard settings.allows(bundleID) else {
            return write("skip: \(bundleID ?? target.owner) is filtered out (\(settings.appFilter.rawValue))")
        }

        // Without an Accessibility element (some apps hide their windows from it), the
        // window is taken as a standard one.
        if let axTarget {
            let subrole = Windows.string(axTarget, kAXSubroleAttribute) ?? "?"
            guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else {
                return write("skip: subrole \(subrole) for \(target.description)")
            }
        }

        ownActivation = (target.pid, Date())
        if settings.mode == .focus && Private.focusWithoutRaiseAvailable {
            let done = Focus.withoutRaise(target: target.id, current: current?.id)
            write("focus \(done ? "ok" : "FAILED"): \(target.description)")
            // The popup the user was in may be hidden behind another app: bring it up.
            // The app is active now, so the raise works.
            if done, raisePopup, let axTarget {
                AXUIElementPerformAction(axTarget, kAXRaiseAction as CFString)
            }
        } else {
            guard let axTarget else { return write("skip: cannot raise without accessibility: \(target.description)") }
            let done = Focus.raise(axTarget, pid: target.pid)
            write("raise \(done ? "ok" : "FAILED"): \(target.description)")
        }
    }

    // MARK: Pointer on the app the user switches to

    private func appActivated(_ app: NSRunningApplication) {
        pointerMove?.cancel()
        guard settings.enabled, settings.movePointer, app.activationPolicy == .regular else { return }
        let pid = app.processIdentifier
        let now = Date()
        let name = app.localizedName ?? "pid \(pid)"
        if ownActivation.pid == pid, now.timeIntervalSince(ownActivation.date) < 1 { return }
        if let key = settings.disableKey.flags, flags.contains(key) { return write("pointer: \(name) active, disable key held") }
        guard settings.allows(app.bundleIdentifier) else { return write("pointer: \(name) active, filtered out") }
        // A click in the app made it active (its window, or the desktop for Finder): the pointer
        // is already where the user wants it. A click in the Dock or in another app moves it.
        if buttonsDown > 0 || now.timeIntervalSince(lastMouseDown.date) < 1,
           Windows.pid(at: lastMouseDown.point) == pid {
            return write("pointer: \(name) active from a click in it")
        }
        movePointer(to: pid, name: name, since: now, attempt: 0)
    }

    /// Waits for the app's focused window (an app opened from the Dock shows it a moment after
    /// it becomes active), then puts the pointer on the part of it nearest its center that no
    /// other window covers.
    private func movePointer(to pid: pid_t, name: String, since start: Date, attempt: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // The user took the mouse, or switched again: leave the pointer alone.
            guard lastMouseMove < start, buttonsDown == 0 else { return write("pointer: \(name) active, the mouse moved") }
            guard Private.frontmostPID().map({ $0 == pid }) ?? true else { return }
            let windows = Windows.onScreen()
            guard let focused = Windows.focused(), focused.pid == pid,
                  let window = windows.first(where: { $0.id == focused.id && $0.layer == 0 && !$0.isTiny }) else {
                if attempt < 16 { movePointer(to: pid, name: name, since: start, attempt: attempt + 1) }
                else { write("pointer: \(name) active, no window") }
                return
            }
            let mouse = CGEvent(source: nil)?.location ?? .zero
            if case .window(let under, _) = Windows.hit(at: mouse), under.id == window.id {
                return write("pointer: already on \(window.description)")
            }
            guard let point = Windows.visiblePoint(of: window, in: windows) else {
                return write("pointer: no visible part of \(window.description)")
            }
            dwellTimer?.cancel()
            CGWarpMouseCursorPosition(point)
            // After a warp, macOS ignores the mouse for a quarter second unless told otherwise.
            CGAssociateMouseAndMouseCursorPosition(1)
            write("pointer moved to (\(Int(point.x)), \(Int(point.y))): \(window.description)")
        }
        pointerMove = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
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
