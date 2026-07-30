import AppKit

if #available(macOS 14.2, *) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
} else {
    print("AudioFocus requires macOS 14.2 or newer.")
    exit(1)
}
