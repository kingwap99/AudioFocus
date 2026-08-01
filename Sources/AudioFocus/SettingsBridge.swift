import Foundation

struct SharedAudioFocusSettings: Codable {
    let version: Int
    let switchDelay: TimeInterval
    let whitelistBundleIDs: [String]
}

enum SettingsBridge {
    static let nativeHostName = "com.audiofocus.nativehost"
    static let browserAudioEventNotification = Notification.Name("com.audiofocus.browserAudioEvent")
    static let browserAudioEventKey = "event"
    static let browserBundleIDKey = "browserBundleID"
    static let chromeExtensionID = "pijagplcjlcnlgafkcegnbdjkgeoheak"
    static let firefoxExtensionID = "audiofocus-tab-controller@local"

    private static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioFocus", isDirectory: true)
    }

    static var settingsURL: URL {
        applicationSupportDirectory.appendingPathComponent("settings.json")
    }

    static func write(switchDelay: TimeInterval, whitelistBundleIDs: Set<String>) {
        let settings = SharedAudioFocusSettings(
            version: 1,
            switchDelay: max(0, switchDelay),
            whitelistBundleIDs: whitelistBundleIDs.sorted()
        )
        do {
            try FileManager.default.createDirectory(
                at: applicationSupportDirectory,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(settings)
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            NSLog("AudioFocus settings bridge write failed: %@", error.localizedDescription)
        }
    }

    static func installNativeMessagingHosts() {
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/AudioFocusNativeHost")
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            NSLog("AudioFocus native host helper is missing at %@", helperURL.path)
            return
        }

        let chromeManifest: [String: Any] = [
            "name": nativeHostName,
            "description": "AudioFocus browser settings bridge",
            "path": helperURL.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(chromeExtensionID)/"]
        ]
        let firefoxManifest: [String: Any] = [
            "name": nativeHostName,
            "description": "AudioFocus browser settings bridge",
            "path": helperURL.path,
            "type": "stdio",
            "allowed_extensions": [firefoxExtensionID]
        ]

        let home = FileManager.default.homeDirectoryForCurrentUser
        install(
            manifest: chromeManifest,
            directory: home.appendingPathComponent(
                "Library/Application Support/Google/Chrome/NativeMessagingHosts",
                isDirectory: true
            )
        )
        install(
            manifest: firefoxManifest,
            directory: home.appendingPathComponent(
                "Library/Application Support/Mozilla/NativeMessagingHosts",
                isDirectory: true
            )
        )
    }

    private static func install(manifest: [String: Any], directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            let destination = directory.appendingPathComponent("\(nativeHostName).json")
            try data.write(to: destination, options: .atomic)
        } catch {
            NSLog("AudioFocus native host manifest install failed: %@", error.localizedDescription)
        }
    }
}
