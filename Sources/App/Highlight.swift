import AppKit
import QuartzCore

/// A ring that closes on the pointer in about half a second, then fades: shown after HocusFocus
/// moved the pointer, so the eye finds it. Drawn in a transparent window that lets every click
/// through and never takes the focus. With Reduce Motion on, the ring only fades.
final class PointerHighlight {
    private static let size: CGFloat = 260
    private static let duration: CFTimeInterval = 0.55
    private static let indigo = NSColor(srgbRed: 0x4B / 255, green: 0x55 / 255, blue: 0xE0 / 255, alpha: 1)

    private let window: NSPanel
    private let rings: [CAShapeLayer]
    private var hideWork: DispatchWorkItem?

    init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.setAccessibilityElement(false)

        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        view.wantsLayer = true
        // A white ring under an indigo one: it reads on dark and light windows alike.
        rings = [(NSColor.white, CGFloat(9)), (Self.indigo, CGFloat(4.5))].map { color, width in
            let ring = CAShapeLayer()
            ring.frame = view.bounds
            ring.fillColor = nil
            ring.strokeColor = color.cgColor
            ring.lineWidth = width
            ring.opacity = 0
            view.layer?.addSublayer(ring)
            return ring
        }
        window.contentView = view
    }

    /// Shows the ring around a point in global coordinates, origin top left.
    func show(at point: CGPoint) {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first else { return }
        let center = NSPoint(x: point.x, y: primary.frame.height - point.y)
        window.setFrame(NSRect(x: center.x - Self.size / 2, y: center.y - Self.size / 2,
                               width: Self.size, height: Self.size), display: false)
        window.orderFrontRegardless()

        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for ring in rings {
            ring.removeAllAnimations()
            let small = circle(radius: 16), large = circle(radius: Self.size / 2 - 8)
            ring.path = small

            let closing = CABasicAnimation(keyPath: "path")
            closing.fromValue = still ? circle(radius: 34) : large
            closing.toValue = still ? circle(radius: 34) : small
            closing.timingFunction = CAMediaTimingFunction(name: .easeOut)

            let fading = CAKeyframeAnimation(keyPath: "opacity")
            fading.values = [0, 1, 1, 0]
            fading.keyTimes = [0, 0.15, 0.7, 1]

            let group = CAAnimationGroup()
            group.animations = [closing, fading]
            group.duration = Self.duration
            ring.add(group, forKey: "highlight")
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.window.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration + 0.05, execute: work)
    }

    private func circle(radius: CGFloat) -> CGPath {
        let c = Self.size / 2
        return CGPath(ellipseIn: CGRect(x: c - radius, y: c - radius, width: radius * 2, height: radius * 2), transform: nil)
    }
}
