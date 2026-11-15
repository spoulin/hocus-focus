import AppKit
import ApplicationServices

/// Gives the keyboard focus to a window.
public enum Focus {
    /// Mode passed to _SLPSSetFrontProcessWithOptions: "user generated", without
    /// bringing the app's windows forward.
    private static let kCPSUserGenerated: UInt32 = 0x200

    /// Focuses `target` without changing the stacking order of any window.
    ///
    /// The event record layout (0xf8 bytes, the offsets below) is not documented. It
    /// was worked out by the yabai project (github.com/koekeishiya/yabai, MIT license),
    /// which AutoRaise also uses. It imitates what the WindowServer sends to an app
    /// when the user clicks one of its windows, without the click.
    @discardableResult
    public static func withoutRaise(target: CGWindowID, current: CGWindowID?) -> Bool {
        guard let post = Private.postEventRecordTo,
              let setFront = Private.setFrontProcessWithOptions,
              var targetPSN = Private.psn(ofWindow: target) else { return false }

        // Inside one app, tell the old window it lost the focus and the new one that
        // it got it. Across apps, _SLPSSetFrontProcessWithOptions does that part.
        if let current, var currentPSN = Private.psn(ofWindow: current), samePSN(targetPSN, currentPSN) {
            var bytes = [UInt8](repeating: 0, count: 0xf8)
            bytes[0x04] = 0xf8
            bytes[0x08] = 0x0d
            bytes[0x8a] = 0x02
            write(current, into: &bytes, at: 0x3c)
            _ = post(&currentPSN, &bytes)

            // Some apps get confused when both events arrive at the same moment.
            usleep(10_000)

            bytes[0x8a] = 0x01
            write(target, into: &bytes, at: 0x3c)
            _ = post(&targetPSN, &bytes)
        }

        guard setFront(&targetPSN, target, kCPSUserGenerated) == .success else { return false }
        makeKeyWindow(target, psn: &targetPSN, post: post)
        return true
    }

    /// The classic way: raise the window, then activate its app.
    @discardableResult
    public static func raise(_ window: AXUIElement, pid: pid_t) -> Bool {
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else { return false }
        NSRunningApplication(processIdentifier: pid)?.activate()
        return true
    }

    private static func makeKeyWindow(_ window: CGWindowID, psn: inout ProcessSerialNumber, post: Private.PostEventRecordTo) {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        write(window, into: &bytes, at: 0x3c)
        for i in 0x20..<0x30 { bytes[i] = 0xff }

        bytes[0x08] = 0x01
        _ = post(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = post(&psn, &bytes)
    }

    private static func write(_ id: CGWindowID, into bytes: inout [UInt8], at offset: Int) {
        withUnsafeBytes(of: id.littleEndian) { raw in
            for (i, byte) in raw.enumerated() { bytes[offset + i] = byte }
        }
    }

    private static func samePSN(_ a: ProcessSerialNumber, _ b: ProcessSerialNumber) -> Bool {
        a.highLongOfPSN == b.highLongOfPSN && a.lowLongOfPSN == b.lowLongOfPSN
    }
}
