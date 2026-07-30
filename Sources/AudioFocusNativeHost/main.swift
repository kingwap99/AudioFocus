import Foundation

struct SharedSettings: Codable {
    let version: Int
    let switchDelay: TimeInterval
    let whitelistBundleIDs: [String]
}

struct NativeRequest: Decodable {
    let type: String
}

let input = FileHandle.standardInput
let output = FileHandle.standardOutput

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
        send([
            "type": "config",
            "version": settings.version,
            "switchDelay": settings.switchDelay,
            "whitelistBundleIDs": settings.whitelistBundleIDs
        ])
    case "ping":
        send(["type": "pong"])
    default:
        send(["type": "error", "message": "unsupported request"])
    }
}
