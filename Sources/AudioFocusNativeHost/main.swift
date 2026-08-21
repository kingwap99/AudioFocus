import AppKit
import Darwin
import Foundation

struct SharedSettings: Codable {
    let version: Int
    let switchDelay: TimeInterval
    let whitelistBundleIDs: [String]
}

struct NativeRequest: Decodable {
    let type: String
    let browserBundleID: String?
    let contextID: String?
    let activeTabID: Int?
    let windowFocused: Bool?
    let tabs: [NativeTab]?
}

struct NativeTab: Decodable {
    let id: Int
    let audible: Bool?
    let muted: Bool?
    let mutedByUs: Bool?
    let playing: Bool?
    let lastFocusedAt: Double?
    let lastAudibleAt: Double?
}

let input = FileHandle.standardInput
let output = FileHandle.standardOutput
var clientBundleID: String?
var clientContextID: String?

func settingsURL() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AudioFocus", isDirectory: true)
        .appendingPathComponent("settings.json")
}

func loadSettings() -> SharedSettings {
    guard let data = try? Data(contentsOf: settingsURL()),
          let settings = try? JSONDecoder().decode(SharedSettings.self, from: data) else {
        return SharedSettings(version: 1, switchDelay: 0.5, whitelistBundleIDs: [])
    }
    return settings
}

func audioFocusIsRunning() -> Bool {
    !NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.audiofocus.app"
    ).isEmpty
}

func reportBrowserEvent(_ type: String, bundleID: String?) {
    let allowedBundleIDs: Set<String> = ["com.google.Chrome", "org.mozilla.firefox"]
    guard audioFocusIsRunning(),
          let bundleID,
          allowedBundleIDs.contains(bundleID),
          ["active", "owner_closed"].contains(type) else { return }

    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.audiofocus.browserAudioEvent"),
        object: nil,
        userInfo: ["event": type, "browserBundleID": bundleID],
        deliverImmediately: true
    )
}

func forwardTabState(_ request: NativeRequest) {
    guard let browserBundleID = request.browserBundleID,
          let contextID = request.contextID else { return }
    clientBundleID = browserBundleID
    clientContextID = contextID

    guard audioFocusIsRunning() else { return }
    var payload: [String: Any] = [
        "event": "tab_state",
        "browserBundleID": browserBundleID,
        "contextID": contextID,
        "activeTabID": request.activeTabID ?? -1,
        "windowFocused": request.windowFocused ?? false
    ]
    if let tabs = request.tabs {
        payload["tabs"] = tabs.map { tab -> [String: Any] in
            var value: [String: Any] = ["id": tab.id]
            if let audible = tab.audible { value["audible"] = audible }
            if let muted = tab.muted { value["muted"] = muted }
            if let mutedByUs = tab.mutedByUs { value["mutedByUs"] = mutedByUs }
            if let playing = tab.playing { value["playing"] = playing }
            if let lastFocusedAt = tab.lastFocusedAt { value["lastFocusedAt"] = lastFocusedAt }
            if let lastAudibleAt = tab.lastAudibleAt { value["lastAudibleAt"] = lastAudibleAt }
            return value
        }
    }

    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.audiofocus.tabState"),
        object: nil,
        userInfo: ["payload": payload],
        deliverImmediately: true
    )
}

func listenForTabCommands() {
    let queue = OperationQueue()
    queue.qualityOfService = .userInitiated
    let center = DistributedNotificationCenter.default()
    let name = Notification.Name("com.audiofocus.tabCommand")
    center.addObserver(
        forName: name,
        object: nil,
        queue: queue
    ) { notification in
        guard let userInfo = notification.userInfo,
              let payload = userInfo["payload"] as? [String: Any],
              let browserBundleID = payload["browserBundleID"] as? String,
              browserBundleID == clientBundleID,
              let contextID = payload["contextID"] as? String,
              contextID == clientContextID,
              let data = try? JSONSerialization.data(withJSONObject: payload["command"] ?? [:]) else {
            return
        }
        var length = UInt32(data.count).littleEndian
        let prefix = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        output.write(prefix)
        output.write(data)
    }
}

func readExactly(_ count: Int) -> Data? {
    var data = Data()
    while data.count < count {
        let chunk = input.readData(ofLength: count - data.count)
        if chunk.isEmpty { return nil }
        data.append(chunk)
    }
    return data
}

func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    var length = UInt32(data.count).littleEndian
    let prefix = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
    output.write(prefix)
    output.write(data)
}

listenForTabCommands()

while let lengthData = readExactly(4) {
    let messageLength = lengthData.withUnsafeBytes { rawBuffer -> UInt32 in
        rawBuffer.loadUnaligned(as: UInt32.self).littleEndian
    }
    guard messageLength > 0, messageLength <= 1_048_576,
          let messageData = readExactly(Int(messageLength)),
          let request = try? JSONDecoder().decode(NativeRequest.self, from: messageData) else {
        send(["type": "error", "message": "invalid request"])
        continue
    }

    switch request.type {
    case "get_config":
        let settings = loadSettings()
        let appRunning = audioFocusIsRunning()
        send([
            "type": "config",
            "version": settings.version,
            "switchDelay": settings.switchDelay,
            "whitelistBundleIDs": settings.whitelistBundleIDs,
            "appRunning": appRunning
        ])
        if !appRunning { exit(EXIT_SUCCESS) }
    case "ping":
        send(["type": "pong"])
    case "browser_owner_active":
        reportBrowserEvent("active", bundleID: request.browserBundleID)
        send(["type": "ack"])
    case "browser_owner_closed":
        reportBrowserEvent("owner_closed", bundleID: request.browserBundleID)
        send(["type": "ack"])
    case "tab_state":
        forwardTabState(request)
        send(["type": "ack"])
    default:
        send(["type": "error", "message": "unsupported request"])
    }
}
