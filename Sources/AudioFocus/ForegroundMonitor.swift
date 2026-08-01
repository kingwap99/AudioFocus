import AppKit
import Foundation
import os.log

protocol ForegroundMonitorDelegate: AnyObject {
    func foregroundAppDidChange(bundleID: String?, appName: String?, pid: pid_t)
    func applicationDidTerminate(bundleID: String?)
}

final class ForegroundMonitor {
    private static let log = OSLog(subsystem: "com.audiofocus.app", category: "ForegroundMonitor")

    weak var delegate: ForegroundMonitorDelegate?
    private(set) var currentForegroundBundleID: String?
    private(set) var currentForegroundAppName: String?
    private(set) var currentForegroundPID: pid_t = -1

    init() {
        if let app = NSWorkspace.shared.frontmostApplication { update(app) }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil
        )
    }

    @objc private func onChange(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        update(app)
    }

    @objc private func onTerminate(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        delegate?.applicationDidTerminate(bundleID: app.bundleIdentifier)
    }

    private func update(_ app: NSRunningApplication) {
        guard app.bundleIdentifier != currentForegroundBundleID else { return }
        currentForegroundBundleID = app.bundleIdentifier
        currentForegroundAppName = app.localizedName
        currentForegroundPID = app.processIdentifier
        os_log(.info, log: Self.log, "%{public}@ → foreground", app.localizedName ?? "?")
        delegate?.foregroundAppDidChange(bundleID: app.bundleIdentifier, appName: app.localizedName, pid: app.processIdentifier)
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
}
