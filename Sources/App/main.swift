import AppKit
import ApplicationServices
import HocusFocusCore
import ServiceManagement

func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

// MARK: - Saved settings

/// Reads and writes the settings in the app's defaults (local.hocusfocus).
enum Preferences {
    private static let defaults = UserDefaults.standard

    static func load() -> Settings {
        var settings = Settings()
        if defaults.object(forKey: "enabled") != nil { settings.enabled = defaults.bool(forKey: "enabled") }
        if let raw = defaults.string(forKey: "mode"), let mode = Settings.Mode(rawValue: raw) { settings.mode = mode }
        if defaults.object(forKey: "dwellMs") != nil { settings.dwell = defaults.double(forKey: "dwellMs") / 1000 }
        if defaults.object(forKey: "typingGuardMs") != nil {
            settings.typingGuard = defaults.double(forKey: "typingGuardMs") / 1000
        }
        if let raw = defaults.string(forKey: "disableKey"), let key = Settings.DisableKey(rawValue: raw) {
            settings.disableKey = key
        }
        return settings
    }

    static func save(_ settings: Settings) {
        defaults.set(settings.enabled, forKey: "enabled")
        defaults.set(settings.mode.rawValue, forKey: "mode")
        defaults.set(settings.dwell * 1000, forKey: "dwellMs")
        defaults.set(settings.typingGuard * 1000, forKey: "typingGuardMs")
        defaults.set(settings.disableKey.rawValue, forKey: "disableKey")
    }

    /// `defaults write local.hocusfocus log -bool YES` writes each decision to
    /// ~/Library/Logs/HocusFocus.log.
    static var logEnabled: Bool { defaults.bool(forKey: "log") }
}

/// Appends lines to ~/Library/Logs/HocusFocus.log.
final class LogFile {
    private let handle: FileHandle?

    init() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/HocusFocus.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    func write(_ line: String) {
        handle?.write(Data((line + "\n").utf8))
    }
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var settings = Preferences.load()
    private lazy var watcher = Watcher(settings: settings)
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var logFile: LogFile?

    private static let autoRaiseBundleID = "com.sbmpost.AutoRaise"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        if Preferences.logEnabled {
            logFile = LogFile()
            watcher.log = { [weak self] line in self?.logFile?.write(line) }
        }
        updateIcon()
        startWhenTrusted(prompt: true)
    }

    /// Starts the watcher as soon as macOS gives Accessibility access. Asks once, then
    /// checks every 1.5 s, so the user doesn't have to relaunch the app.
    private func startWhenTrusted(prompt: Bool) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        if AXIsProcessTrustedWithOptions(options), watcher.start() {
            updateIcon()
            return
        }
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, AXIsProcessTrusted(), self.watcher.start() else { return }
            self.permissionTimer?.invalidate()
            self.permissionTimer = nil
            self.updateIcon()
        }
    }

    private func apply() {
        watcher.settings = settings
        Preferences.save(settings)
        updateIcon()
    }

    private func updateIcon() {
        let symbol = settings.enabled ? "cursorarrow.rays" : "cursorarrow"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "HocusFocus")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !watcher.isRunning || !settings.enabled
    }

    // The menu is rebuilt each time it opens, so the Accessibility, login item and
    // AutoRaise lines are always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !watcher.isRunning {
            menu.addItem(disabledItem(localized("Waiting for Accessibility access…")))
            menu.addItem(item(localized("Open Settings › Accessibility"), #selector(openAccessibility)))
            menu.addItem(.separator())
        }

        if NSRunningApplication.runningApplications(withBundleIdentifier: Self.autoRaiseBundleID).isEmpty == false {
            menu.addItem(disabledItem(localized("AutoRaise is running too")))
            menu.addItem(item(localized("Quit AutoRaise"), #selector(quitAutoRaise)))
            menu.addItem(.separator())
        }

        menu.addItem(item(localized("Focus follows mouse"), #selector(toggleEnabled), checked: settings.enabled))
        menu.addItem(.separator())

        let modes: [(String, Settings.Mode)] = [
            (localized("Focus without raising"), .focus),
            (localized("Focus and raise"), .raise),
        ]
        menu.addItem(submenu(localized("Mode"), modes.map { title, mode in
            choice(title, #selector(chooseMode(_:)), mode.rawValue, checked: settings.mode == mode)
        }))
        if !Private.focusWithoutRaiseAvailable {
            menu.addItem(disabledItem(localized("Focus without raising is not available on this macOS")))
        }

        menu.addItem(submenu(localized("Delay"), [50, 100, 150, 250, 400, 600].map { ms in
            choice(milliseconds(ms), #selector(chooseDwell(_:)), ms, checked: Int(settings.dwell * 1000) == ms)
        }))

        let guards: [(String, Int)] = [(localized("Off"), 0)] + [300, 500, 1000].map { (milliseconds($0), $0) }
        menu.addItem(submenu(localized("Pause while typing"), guards.map { title, ms in
            choice(title, #selector(chooseTypingGuard(_:)), ms, checked: Int(settings.typingGuard * 1000) == ms)
        }))

        let keys: [(String, Settings.DisableKey)] = [
            (localized("⌃ Control"), .control), (localized("⌥ Option"), .option),
            (localized("⌘ Command"), .command), (localized("None"), .none),
        ]
        menu.addItem(submenu(localized("Hold to pause"), keys.map { title, key in
            choice(title, #selector(chooseDisableKey(_:)), key.rawValue, checked: settings.disableKey == key)
        }))

        menu.addItem(.separator())
        let loginEnabled = SMAppService.mainApp.status == .enabled
        menu.addItem(item(localized("Open at login"), #selector(toggleLaunchAtLogin), checked: loginEnabled))
        menu.addItem(.separator())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        menu.addItem(disabledItem("HocusFocus \(version)"))
        menu.addItem(item(localized("Quit HocusFocus"), #selector(quit), key: "q"))
    }

    // MARK: Menu helpers

    private func item(_ title: String, _ action: Selector, checked: Bool = false, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        entry.state = checked ? .on : .off
        return entry
    }

    private func choice(_ title: String, _ action: Selector, _ value: Any, checked: Bool) -> NSMenuItem {
        let entry = item(title, action, checked: checked)
        entry.representedObject = value
        return entry
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        items.forEach(menu.addItem)
        entry.submenu = menu
        return entry
    }

    private func milliseconds(_ ms: Int) -> String {
        ms >= 1000 ? String(format: localized("%g s"), Double(ms) / 1000) : String(format: localized("%d ms"), ms)
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        apply()
    }

    @objc private func chooseMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = Settings.Mode(rawValue: raw) {
            settings.mode = mode
            apply()
        }
    }

    @objc private func chooseDwell(_ sender: NSMenuItem) {
        if let ms = sender.representedObject as? Int {
            settings.dwell = Double(ms) / 1000
            apply()
        }
    }

    @objc private func chooseTypingGuard(_ sender: NSMenuItem) {
        if let ms = sender.representedObject as? Int {
            settings.typingGuard = Double(ms) / 1000
            apply()
        }
    }

    @objc private func chooseDisableKey(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let key = Settings.DisableKey(rawValue: raw) {
            settings.disableKey = key
            apply()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            logFile?.write("launch at login failed: \(error.localizedDescription)")
        }
    }

    @objc private func quitAutoRaise() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.autoRaiseBundleID) {
            app.terminate()
        }
    }

    @objc private func openAccessibility() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
