import AppKit
import ApplicationServices
import HocusFocusCore

let usage = """
usage:
  hocusfocus check                 Show whether the private functions and Accessibility are available
  hocusfocus list                  List the normal windows on screen, front to back
  hocusfocus hit <x> <y>           Show which window would get the focus at a point, or why none would
  hocusfocus test-focus <id>       Focus one window without raising it, then report what changed
  hocusfocus run [options]         Focus the window under the mouse when the mouse rests

run options:
  --mode focus|raise    focus = focus without raise (default), raise = classic raise
  --dwell <ms>          How long the mouse must rest (default 150)
  --typing-guard <ms>   No change if a key was pressed this recently (default 500)
  --disable-key control|option|command|none   Hold to pause (default control)
  --except <id,id>      Never focus these apps (bundle identifiers)
  --only <id,id>        Focus only these apps (bundle identifiers)
  --no-move-pointer     Leave the pointer where it is when an app becomes active from the
                        keyboard or the Dock (by default it goes to the app's window)
  --no-new-windows      Leave the pointer where it is when an app opens a window that takes
                        the focus (by default it goes to that window)
  --verbose             Log every decision
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func requireAccessibility() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if !AXIsProcessTrustedWithOptions(options) {
        fail("Accessibility access is missing. Allow this app (or your terminal) in System Settings > Privacy & Security > Accessibility, then run again.")
    }
}

/// Turns the main run loop for a while: runs the scheduled checks and lets NSWorkspace
/// learn which app is active.
func settle(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date() + seconds)
}

func normalWindows() -> [WindowInfo] {
    Windows.onScreen().filter { $0.layer == 0 }
}

// Write each log line at once, even when the output goes to a file or a pipe.
setvbuf(stdout, nil, _IOLBF, 0)

var arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.isEmpty ? "help" : arguments.removeFirst()

switch command {
case "check":
    print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    for (name, found) in Private.report { print("  \(found ? "ok     " : "MISSING") \(name)") }
    print("Focus without raise: \(Private.focusWithoutRaiseAvailable ? "available" : "NOT available, raise only")")
    print("Accessibility: \(AXIsProcessTrusted() ? "allowed" : "NOT allowed")")

case "list":
    requireAccessibility()
    settle(0.05)
    let focused = Windows.focused()
    for window in normalWindows() {
        print("\(window.id == focused?.id ? "*" : " ") \(window.description)")
    }
    if let focused {
        if let popup = Windows.popup(over: focused) {
            let effect = popup.blocksAll ? "no focus change at all" : "no focus change inside the app"
            print("popup over the focused window: \(popup.window.description) (\(effect))")
        } else {
            print("popup over the focused window: none")
        }
    }

case "hit":
    requireAccessibility()
    guard arguments.count == 2, let x = Double(arguments[0]), let y = Double(arguments[1]) else { fail(usage) }
    switch Windows.hit(at: CGPoint(x: x, y: y)) {
    case .window(let info, _): print("window: \(info.description)")
    case .skip(let reason): print("skip: \(reason)")
    }

case "test-focus":
    requireAccessibility()
    guard let raw = arguments.first, let target = CGWindowID(raw) else { fail(usage) }
    guard normalWindows().contains(where: { $0.id == target }) else { fail("No normal window #\(target) on screen.") }

    settle(0.05)
    let orderBefore = normalWindows().map(\.id)
    let focusBefore = Windows.focused()
    print("before: focus #\(focusBefore.map { String($0.id) } ?? "none"), order \(orderBefore)")

    guard Focus.withoutRaise(target: target, current: focusBefore?.id) else { fail("Focus without raise failed.") }
    settle(0.4)

    let orderAfter = normalWindows().map(\.id)
    let focusAfter = Windows.focused()
    print("after:  focus #\(focusAfter.map { String($0.id) } ?? "none"), order \(orderAfter)")

    let focused = focusAfter?.id == target
    let sameOrder = orderBefore == orderAfter
    print("focus moved to #\(target): \(focused ? "yes" : "NO")")
    print("stacking order unchanged: \(sameOrder ? "yes" : "NO")")
    exit(focused && sameOrder ? 0 : 2)

case "run":
    requireAccessibility()
    var settings = Settings()
    var verbose = false
    while !arguments.isEmpty {
        let option = arguments.removeFirst()
        func value() -> String {
            guard !arguments.isEmpty else { fail("Missing value for \(option)") }
            return arguments.removeFirst()
        }
        switch option {
        case "--mode":
            guard let mode = Settings.Mode(rawValue: value()) else { fail("--mode must be focus or raise") }
            settings.mode = mode
        case "--dwell":
            guard let ms = Double(value()) else { fail("--dwell needs milliseconds") }
            settings.dwell = ms / 1000
        case "--typing-guard":
            guard let ms = Double(value()) else { fail("--typing-guard needs milliseconds") }
            settings.typingGuard = ms / 1000
        case "--disable-key":
            guard let key = Settings.DisableKey(rawValue: value()) else {
                fail("--disable-key must be control, option, command or none")
            }
            settings.disableKey = key
        case "--except":
            settings.appFilter = .except
            settings.exceptApps = Set(value().split(separator: ",").map { String($0) })
        case "--only":
            settings.appFilter = .only
            settings.onlyApps = Set(value().split(separator: ",").map { String($0) })
        case "--no-move-pointer":
            settings.movePointer = false
        case "--no-new-windows":
            settings.movePointerToNewWindows = false
        case "--verbose":
            verbose = true
        default:
            fail("Unknown option \(option)\n\n\(usage)")
        }
    }
    if settings.mode == .focus && !Private.focusWithoutRaiseAvailable {
        print("Focus without raise is not available on this macOS. Falling back to raise.")
    }

    let watcher = Watcher(settings: settings)
    if verbose { watcher.log = { print($0) } }
    guard watcher.start() else { fail("Could not create the event tap. Check Accessibility access.") }
    print("hocusfocus running (mode \(settings.mode.rawValue), dwell \(Int(settings.dwell * 1000)) ms). Ctrl-C to quit.")
    CFRunLoopRun()

default:
    print(usage)
}
