import AppKit
import ApplicationServices
import Foundation
import os.log

@available(macOS 14.2, *)
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let log = OSLog(subsystem: "com.audiofocus.app", category: "AppDelegate")

    private var statusItem: NSStatusItem!
    private let audioManager = AudioManager()
    private let foregroundMonitor = ForegroundMonitor()
    private var activity: NSObjectProtocol?

    private var isEnabled = true
    private var mutedProcesses: [AudioProcessInfo] = []
    private var audioStatus = "Starting…"
    private var switchDelay: TimeInterval = 0.5
    private var whitelistBundleIDs = Set<String>()

    private let switchDelayKey = "AudioFocus.switchDelay"
    private let whitelistKey = "AudioFocus.whitelistBundleIDs"

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.automaticTerminationDisabled, .suddenTerminationDisabled, .userInitiated],
            reason: "AudioFocus continuously manages foreground audio"
        )

        loadPreferences()
        audioManager.setSwitchDelay(switchDelay)
        audioManager.setWhitelist(whitelistBundleIDs)

        requestAccessibilityPermissionIfNeeded()
        setupMenuBar()
        audioManager.delegate = self
        foregroundMonitor.delegate = self
        audioManager.startPolling(interval: 3.0)
        audioManager.muteAllExcept(bundleID: foregroundMonitor.currentForegroundBundleID)
        os_log(.info, log: Self.log, "AudioFocus ready")
    }

    private func loadPreferences() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: switchDelayKey) != nil {
            switchDelay = max(0, defaults.double(forKey: switchDelayKey))
        }
        whitelistBundleIDs = Set(defaults.stringArray(forKey: whitelistKey) ?? [])
    }

    private func requestAccessibilityPermissionIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🔊"
        statusItem.button?.toolTip = "AudioFocus"

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        populateMenu(menu)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populateMenu(menu)
    }

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addDisabledItem(isEnabled ? "🟢 Active" : "🔴 Paused")
        menu.addDisabledItem("  Audio: \(audioStatus)")

        let appName = foregroundMonitor.currentForegroundAppName ?? "?"
        let bundleID = foregroundMonitor.currentForegroundBundleID ?? "?"
        menu.addDisabledItem("  Front: \(appName)")
        menu.addDisabledItem("  Bundle: \(bundleID)")
        menu.addDisabledItem("  PID: \(foregroundMonitor.currentForegroundPID)")

        menu.addItem(.separator())
        addWindowItems(to: menu)

        menu.addItem(.separator())
        addMutedItems(to: menu)

        menu.addItem(.separator())
        addSwitchDelayItem(to: menu)
        addWhitelistItem(to: menu)

        menu.addItem(.separator())
        let toggle = NSMenuItem(
            title: isEnabled ? "⏸  Pause" : "▶️  Resume",
            action: #selector(toggleEnabled),
            keyEquivalent: "t"
        )
        toggle.target = self
        menu.addItem(toggle)

        let refresh = NSMenuItem(title: "🔄 Refresh", action: #selector(refreshMuteState), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())
        menu.addDisabledItem("Build: \(BUILD_TIMESTAMP)")

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func addWindowItems(to menu: NSMenu) {
        let titles = foregroundWindowTitles()
        menu.addDisabledItem("Windows (\(titles.count)):")
        if titles.isEmpty {
            let reason = AXIsProcessTrusted() ? "(none)" : "(Accessibility permission required)"
            menu.addDisabledItem("  \(reason)")
            return
        }

        for title in titles {
            let display = title.count > 75 ? String(title.prefix(72)) + "…" : title
            menu.addDisabledItem("  📄 \(display)")
        }
    }

    private func addMutedItems(to menu: NSMenu) {
        let grouped = Dictionary(grouping: mutedProcesses, by: \.bundleID)
        let runningCount = mutedProcesses.filter(\.isRunning).count
        let parent = NSMenuItem(
            title: "Muted list: \(grouped.count) apps / \(mutedProcesses.count) processes",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if grouped.isEmpty {
            submenu.addDisabledItem("(none)")
        } else {
            for bundleID in grouped.keys.sorted() {
                let processes = grouped[bundleID] ?? []
                let isRunning = processes.contains(where: \.isRunning)
                let icon = isRunning ? "🔇" : "💤"
                let name = displayName(for: processes.first)
                let suffix = processes.count > 1 ? " ×\(processes.count)" : ""
                let item = NSMenuItem(
                    title: "\(icon) \(name)\(suffix) — click to whitelist",
                    action: #selector(toggleWhitelist(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = bundleID
                item.toolTip = bundleID
                submenu.addItem(item)
            }
        }

        parent.submenu = submenu
        menu.addItem(parent)
        menu.addDisabledItem("  Currently outputting: \(runningCount)")
    }

    private func addSwitchDelayItem(to menu: NSMenu) {
        let parent = NSMenuItem(
            title: String(format: "Switch delay: %.2fs", switchDelay),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        for delay in [0.0, 0.25, 0.5, 1.0, 2.0, 3.0] {
            let title = delay == 0 ? "Immediate" : String(format: "%.2f seconds", delay)
            let item = NSMenuItem(title: title, action: #selector(selectSwitchDelay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: delay)
            item.state = abs(delay - switchDelay) < 0.001 ? .on : .off
            submenu.addItem(item)
        }

        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func addWhitelistItem(to menu: NSMenu) {
        let parent = NSMenuItem(
            title: "Whitelist: \(whitelistBundleIDs.count) apps",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let detected = audioManager.getAudioProcesses().filter {
            !$0.bundleID.isEmpty && $0.bundleID != "com.audiofocus.app"
        }
        let grouped = Dictionary(grouping: detected, by: \.bundleID)
        let bundleIDs = Set(grouped.keys).union(whitelistBundleIDs).sorted()

        if bundleIDs.isEmpty {
            submenu.addDisabledItem("(no audio apps detected)")
        } else {
            for bundleID in bundleIDs {
                let process = grouped[bundleID]?.first
                let name = process.map { displayName(for: $0) } ?? bundleID
                let item = NSMenuItem(title: name, action: #selector(toggleWhitelist(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = bundleID
                item.toolTip = bundleID
                item.state = whitelistBundleIDs.contains(bundleID) ? .on : .off
                submenu.addItem(item)
            }
        }

        submenu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear whitelist", action: #selector(clearWhitelist), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !whitelistBundleIDs.isEmpty
        submenu.addItem(clear)

        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func displayName(for process: AudioProcessInfo?) -> String {
        guard let process else { return "Unknown" }
        if let app = NSRunningApplication(processIdentifier: process.pid),
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: process.bundleID),
           let bundle = Bundle(url: url),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }
        return process.bundleID
    }

    // Accessibility returns every application window, including minimized Chrome windows.
    private func foregroundWindowTitles() -> [String] {
        let pid = foregroundMonitor.currentForegroundPID
        guard pid > 0 else { return [] }

        if AXIsProcessTrusted() {
            let app = AXUIElementCreateApplication(pid)
            var windowsValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
               let windows = windowsValue as? [AXUIElement] {
                let titles = windows.compactMap { window -> String? in
                    var titleValue: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success else {
                        return nil
                    }
                    return titleValue as? String
                }.filter { !$0.isEmpty }
                if !titles.isEmpty { return unique(titles) }
            }
        }

        // Fallback for systems where Accessibility has not been granted yet.
        let options = CGWindowListOption(arrayLiteral: .optionAll, .excludeDesktopElements)
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let titles = list
            .filter {
                ($0[kCGWindowOwnerPID as String] as? pid_t) == pid
                    && ($0[kCGWindowLayer as String] as? Int ?? 0) == 0
            }
            .compactMap { $0[kCGWindowName as String] as? String }
            .filter { !$0.isEmpty }
        return unique(titles)
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    @objc private func selectSwitchDelay(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        switchDelay = max(0, number.doubleValue)
        UserDefaults.standard.set(switchDelay, forKey: switchDelayKey)
        audioManager.setSwitchDelay(switchDelay)
        if let menu = statusItem.menu { populateMenu(menu) }
    }

    @objc private func toggleWhitelist(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String, !bundleID.isEmpty else { return }
        if whitelistBundleIDs.contains(bundleID) {
            whitelistBundleIDs.remove(bundleID)
        } else {
            whitelistBundleIDs.insert(bundleID)
        }
        saveWhitelist()
        audioManager.setWhitelist(whitelistBundleIDs)
        if let menu = statusItem.menu { populateMenu(menu) }
    }

    @objc private func clearWhitelist() {
        whitelistBundleIDs.removeAll()
        saveWhitelist()
        audioManager.setWhitelist(whitelistBundleIDs)
        if let menu = statusItem.menu { populateMenu(menu) }
    }

    private func saveWhitelist() {
        UserDefaults.standard.set(whitelistBundleIDs.sorted(), forKey: whitelistKey)
    }

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        statusItem.button?.title = isEnabled ? "🔊" : "🔈"
        if isEnabled {
            audioManager.considerForegroundCandidate(bundleID: foregroundMonitor.currentForegroundBundleID)
        } else {
            audioManager.unmuteAll()
        }
        if let menu = statusItem.menu { populateMenu(menu) }
    }

    @objc private func refreshMuteState() {
        guard isEnabled else { return }
        audioManager.considerForegroundCandidate(bundleID: foregroundMonitor.currentForegroundBundleID)
    }

    @objc private func quitApp() {
        audioManager.unmuteAll()
        audioManager.stopPolling()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        audioManager.unmuteAll()
        audioManager.stopPolling()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }
}

@available(macOS 14.2, *)
extension AppDelegate: ForegroundMonitorDelegate {
    func foregroundAppDidChange(bundleID: String?, appName: String?, pid: pid_t) {
        guard isEnabled else { return }
        os_log(.info, log: Self.log, "Foreground → %{public}@", appName ?? "?")
        audioManager.considerForegroundCandidate(bundleID: bundleID)
    }
}

@available(macOS 14.2, *)
extension AppDelegate: AudioManagerDelegate {
    func audioManagerDidUpdateProcessList(_ mutedProcesses: [AudioProcessInfo]) {
        self.mutedProcesses = mutedProcesses
    }

    func audioManagerDidChangeStatus(_ status: String) {
        audioStatus = status
    }
}

extension NSMenu {
    func addDisabledItem(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }
}
