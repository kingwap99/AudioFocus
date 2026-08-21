import AppKit
import CoreAudio
import AudioToolbox
import Foundation
import os.log

struct AudioProcessInfo: Equatable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let appName: String?
    var isRunning: Bool
}

protocol AudioManagerDelegate: AnyObject {
    func audioManagerDidUpdateProcessList(_ mutedProcesses: [AudioProcessInfo])
    func audioManagerDidChangeStatus(_ status: String)
}

struct TabSnapshot: Decodable {
    struct Tab: Decodable {
        let id: Int
        let audible: Bool?
        let muted: Bool?
        let mutedByUs: Bool?
        let playing: Bool?
    }
    let browserBundleID: String
    let contextID: String
    let activeTabID: Int?
    let windowFocused: Bool
    let tabs: [Tab]?
}

/// All state-changing inputs funnel through this serialized event type. Every
/// event re-runs the decision procedure; transitions follow rules T1–T7 of the
/// decision-core design doc.
private enum AudioEvent {
    case poll
    case delayExpired(generation: Int)
    case settingsChanged
    case unmuteAll
}

@available(macOS 14.2, *)
final class AudioManager {
    private static let log = OSLog(subsystem: "com.audiofocus.app", category: "AudioManager")

    // MARK: - Sound sources (design doc §3.1)

    private enum Source: Equatable, CustomStringConvertible {
        case app(String)
        case tab(browser: String, tabID: Int)

        var family: String {
            switch self {
            case .app(let bundleID): return bundleID
            case .tab(let browser, _): return browser
            }
        }

        var description: String {
            switch self {
            case .app(let bundleID): return "app(\(bundleID))"
            case .tab(let browser, let tabID): return "tab(\(browser)#\(tabID))"
            }
        }
    }

    private struct TabFact {
        var audible: Bool
        var playing: Bool?
        var mutedByUs: Bool
    }

    private struct BrowserFacts {
        var receivedAt: Date
        var windowFocused: Bool
        var activeTabID: Int?
        var tabs: [Int: TabFact]
    }

    weak var delegate: AudioManagerDelegate?

    // MARK: - Decision state (design doc §3.2 — the ONLY decision state)

    private var owner: Source?
    private var pending: Source?
    private var pendingGeneration = 0
    private var history: [Source] = []

    // MARK: - Facts (design doc §2)

    private var foregroundBundleID: String?
    private var terminatedBundleID: String?
    private var browserFacts: [String: BrowserFacts] = [:]
    private var extensionSeen = Set<String>()

    // MARK: - Settings & pipeline state

    private var whitelistBundleIDs = Set<String>()
    private var switchDelay: TimeInterval = 0.5
    private var mutedObjectIDs = Set<AudioObjectID>()

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var pollTimer: DispatchSourceTimer?

    private let tabStateFreshness: TimeInterval = 2.5
    private let tabExistenceFreshness: TimeInterval = 10
    private let historyLimit = 16
    private let extensionBrowsers: Set<String> = ["com.google.Chrome", "org.mozilla.firefox"]

    private let controlQueue = DispatchQueue(label: "com.audiofocus.audio-control", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "com.audiofocus.audio-io", qos: .userInteractive)

    private let protectedBundleIDs: Set<String> = [
        "com.apple.audio.coreaudiod",
        "com.apple.audio.AudioUIServer",
        "com.apple.audiomxd",
        "com.apple.coreaudiod",
        "com.apple.loginwindow",
        "com.audiofocus.app",
        ""
    ]

    // MARK: - Process enumeration

    func getAudioProcesses() -> [AudioProcessInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objectIDs
        ) == noErr else { return [] }

        return objectIDs.compactMap { objectID in
            guard let bundleID = getBundleID(objectID) else { return nil }
            let pid = getPID(objectID)
            return AudioProcessInfo(
                objectID: objectID,
                pid: pid,
                bundleID: bundleID,
                appName: NSRunningApplication(processIdentifier: pid)?.localizedName,
                isRunning: isRunning(objectID)
            )
        }
    }

    private func getBundleID(_ objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value as String? : nil
    }

    private func getPID(_ objectID: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = pid_t(-1)
        var size = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return value
    }

    private func isRunning(_ objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr && value == 1
    }

    // MARK: - Family helpers

    private func isForegroundFamily(_ candidate: String, foreground: String?) -> Bool {
        guard let foreground, !foreground.isEmpty else { return false }
        return candidate == foreground || candidate.hasPrefix(foreground + ".")
    }

    private func isSafariWebKitHelper(_ process: AudioProcessInfo) -> Bool {
        let allowedBundleIDs = [
            "com.apple.WebKit.GPU",
            "com.apple.WebKit.WebContent",
            "com.apple.WebKit.Networking"
        ]
        guard allowedBundleIDs.contains(where: {
            process.bundleID == $0 || process.bundleID.hasPrefix($0 + ".")
        }) else { return false }

        guard let appName = process.appName?.lowercased() else { return false }
        return appName == "safari" || appName.hasPrefix("safari ")
    }

    private func isForegroundFamily(_ process: AudioProcessInfo, foreground: String?) -> Bool {
        if isForegroundFamily(process.bundleID, foreground: foreground) {
            return true
        }
        return foreground == "com.apple.Safari" && isSafariWebKitHelper(process)
    }

   private func mutedProcesses(from all: [AudioProcessInfo], foreground: String?) -> [AudioProcessInfo] {
       all.filter {
           !protectedBundleIDs.contains($0.bundleID)
               && !isWhitelistedProcess($0)
               && !isForegroundFamily($0, foreground: foreground)
               && !isExtensionBrowserProcess($0)
       }
   }

    // Extension-managed browsers are muted per-tab by their extension; muting
    // their CoreAudio process would also silence the very owner tab we are
    // trying to hand audio to (and corrupt the extension's `audible` signal).
    private func isExtensionBrowserProcess(_ process: AudioProcessInfo) -> Bool {
        extensionBrowsers.contains { isForegroundFamily(process, foreground: $0) }
    }

    private func isWhitelistedFamily(_ candidate: String) -> Bool {
        whitelistBundleIDs.contains {
            candidate == $0 || candidate.hasPrefix($0 + ".")
        }
    }

    private func isWhitelistedProcess(_ process: AudioProcessInfo) -> Bool {
        whitelistBundleIDs.contains {
            isForegroundFamily(process, foreground: $0)
        }
    }

    private func familyIsOutputting(_ bundleID: String, in processes: [AudioProcessInfo]) -> Bool {
        processes.contains {
            isForegroundFamily($0, foreground: bundleID) && $0.isRunning
        }
    }

    private func familyExists(_ bundleID: String, in processes: [AudioProcessInfo]) -> Bool {
        processes.contains {
            isForegroundFamily($0, foreground: bundleID)
        }
    }

    // MARK: - Decision procedure (design doc §4)

    /// Fact: does this source still exist? (Tab existence is authoritative from
    /// the extension; app existence from the CoreAudio process list.)
    private func exists(_ source: Source, in all: [AudioProcessInfo]) -> Bool {
        switch source {
        case .app(let bundleID):
            return familyExists(bundleID, in: all)
        case .tab(let browser, let tabID):
            guard let facts = browserFacts[browser],
                  Date().timeIntervalSince(facts.receivedAt) <= tabExistenceFreshness else { return false }
            return facts.tabs[tabID] != nil
        }
    }

    /// Fact: is this source confirmed producing sound? Our own muting never
    /// counts against eligibility (design doc §5).
    private func eligible(_ source: Source, in all: [AudioProcessInfo]) -> Bool {
        switch source {
        case .app(let bundleID):
            return familyIsOutputting(bundleID, in: all)
        case .tab(let browser, let tabID):
            guard let facts = browserFacts[browser],
                  Date().timeIntervalSince(facts.receivedAt) <= tabExistenceFreshness,
                  let tab = facts.tabs[tabID] else { return false }
            if tab.playing == true { return true }
            return tab.audible && !tab.mutedByUs
        }
    }

    /// Fact: which source is the user operating right now? Returns nil when the
    /// focus is unknown (stale tab state) or whitelisted — never guesses from
    /// process-level output for extension-managed browsers.
    private func focusedSource(in all: [AudioProcessInfo]) -> Source? {
        guard let foreground = foregroundBundleID,
              !foreground.isEmpty,
              !isWhitelistedFamily(foreground) else { return nil }
        guard extensionBrowsers.contains(foreground) else { return .app(foreground) }
        guard let facts = browserFacts[foreground] else {
            // Extension never connected → plain app. Connected before but no
            // data → unknown, do not fall back to process-level guessing.
            return extensionSeen.contains(foreground) ? nil : .app(foreground)
        }
        guard Date().timeIntervalSince(facts.receivedAt) <= tabStateFreshness,
              facts.windowFocused,
              let activeID = facts.activeTabID,
              facts.tabs[activeID] != nil else { return nil }
        return .tab(browser: foreground, tabID: activeID)
    }

    /// Recomputes owner/pending from current facts. Called once per event.
   private func runDecision(trigger: String, processes: [AudioProcessInfo]? = nil) {
       let all = processes ?? getAudioProcesses()
        let focused = focusedSource(in: all)
        os_log(.info, log: Self.log,
               "runDecision %{public}@ fg=%{public}@ owner=%{public}@ pending=%{public}@",
               trigger,
               foregroundBundleID ?? "nil",
               owner?.description ?? "nil",
               pending?.description ?? "nil")

        // T1: owner disappeared → restore the most recent living, eligible
        // history entry; if none, owner = nil (mute all, wait).
        if let current = owner, !exists(current, in: all) {
            os_log(.info, log: Self.log,
                   "Decision T1 (%{public}@): owner %{public}@ gone",
                   trigger, current.description)
            history.removeAll { $0 == current }
            history = history.filter { exists($0, in: all) }
            owner = history.first { eligible($0, in: all) }
            pending = nil
            if let restored = owner {
                os_log(.info, log: Self.log,
                       "Decision T1: restored %{public}@", restored.description)
                updateStatus("Owner closed; restored \(restored.description)")
            } else {
                os_log(.info, log: Self.log, "Decision T1: no restorable owner")
                updateStatus("Owner closed; waiting for audible focus")
            }
        }


        // T4: candidate lost focus or eligibility → drop it. Owner unchanged.
        if let candidate = pending, candidate != focused || !eligible(candidate, in: all) {
            os_log(.info, log: Self.log,
                   "Decision T4 (%{public}@): candidate %{public}@ dropped (focused=%{public}@)",
                   trigger, candidate.description, focused?.description ?? "nil")
            pending = nil
        }

       // T2/T3: focused, eligible, non-owner source becomes the candidate and
       // starts the (single) switch delay.
       if let focused, focused != owner, eligible(focused, in: all), pending != focused {
            // T2: no current owner to protect → take the first audible focused
            // source immediately. The switch delay only exists to avoid yanking
            // audio from a *living* owner on brief focus blips.
            if owner == nil {
                history.removeAll { $0 == focused }
                owner = focused
                pending = nil
                os_log(.info, log: Self.log,
                       "Decision T2 (%{public}@): owner=%{public}@ (immediate, no current owner)",
                       trigger, focused.description)
                updateStatus("Owner: \(focused.description)")
            } else if pending != focused {
                pending = focused
                pendingGeneration += 1
                os_log(.info, log: Self.log,
                       "Decision T3 (%{public}@): candidate %{public}@ (owner=%{public}@, delay=%.2fs)",
                       trigger, focused.description, owner?.description ?? "nil", switchDelay)
                if switchDelay > 0 {
                    updateStatus(String(format: "Switching to %@ in %.2fs", focused.description, switchDelay))
                }
                scheduleDelayExpired(generation: pendingGeneration)
            }
        }

        // T6: focus silent or unknown → keep the current owner playing.
        if trigger == "focus", pending == nil {
            if focused == nil {
                updateStatus("Holding \(owner?.description ?? "none"); focus unknown")
            } else if let focused, !eligible(focused, in: all), focused != owner {
                updateStatus("Holding \(owner?.description ?? "none"); focus is silent")
            }
        }

        rebuildMuteSet(all)
    }

    private func scheduleDelayExpired(generation: Int) {
        controlQueue.asyncAfter(deadline: .now() + switchDelay) { [weak self] in
            self?.dispatch(.delayExpired(generation: generation))
        }
    }

    /// T5: delay expired with the candidate still focused and eligible →
    /// hand over ownership, pushing the old owner onto the history stack.
    private func completePendingSwitch(generation: Int) {
        guard generation == pendingGeneration, let candidate = pending else { return }
        let all = getAudioProcesses()
        guard candidate == focusedSource(in: all), eligible(candidate, in: all) else {
            os_log(.info, log: Self.log,
                   "Decision T4 (delayExpired): candidate %{public}@ no longer valid",
                   candidate.description)
            pending = nil
            rebuildMuteSet(all)
            return
        }

        history.removeAll { $0 == candidate }
        if let old = owner, old != candidate {
            history.insert(old, at: 0)
            if history.count > historyLimit {
                history.removeLast(history.count - historyLimit)
            }
        }
        owner = candidate
        pending = nil
        os_log(.info, log: Self.log,
               "Decision T5: owner=%{public}@ history=%{public}@",
               candidate.description,
               history.map(\.description).joined(separator: ", "))
        updateStatus("Owner: \(candidate.description)")
        rebuildMuteSet(all)
    }

    /// Derives the process-level mute set from the owner (design doc §6).
    private func rebuildMuteSet(_ all: [AudioProcessInfo]) {
        let muted = mutedProcesses(from: all, foreground: owner?.family)
        let newIDs = Set(muted.map(\.objectID))
        guard newIDs != mutedObjectIDs else { return }
        _ = createPipeline(for: muted)
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.audioManagerDidUpdateProcessList(muted)
        }
    }

    // MARK: - Event dispatch

    private func dispatch(_ event: AudioEvent) {
        controlQueue.async { [weak self] in
            self?.handle(event)
        }
    }

    private func handle(_ event: AudioEvent) {
        switch event {
        case .poll:
            let all = getAudioProcesses()
            runDecision(trigger: "poll", processes: all)

        case .delayExpired(let generation):
            completePendingSwitch(generation: generation)

        case .settingsChanged:
            runDecision(trigger: "settings")

        case .unmuteAll:
            owner = nil
            pending = nil
            history.removeAll()
            destroyPipeline()
            updateStatus("Paused")
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.audioManagerDidUpdateProcessList([])
            }
        }
    }

    // MARK: - Public API

    /// E1: the foreground app changed.
    func focusChanged(bundleID: String?) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.foregroundBundleID = bundleID
            self.runDecision(trigger: "focus")
        }
    }

    /// E3: an app terminated. Drops its browser facts so tab owners are
    /// reclaimed immediately instead of waiting for facts to go stale.
    func appTerminated(bundleID: String?) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            if let bundleID {
                self.browserFacts.removeValue(forKey: bundleID)
                self.extensionSeen.remove(bundleID)
            }
            self.runDecision(trigger: "terminated")
        }
    }

    /// E2 (browser): stores the extension's tab facts, re-runs the decision
    /// procedure, and returns the command for the extension to execute.
    /// Called from the main thread; serialized onto the control queue.
    func evaluateTabState(_ snapshot: TabSnapshot) -> [String: Any] {
        var command: [String: Any] = [:]
        controlQueue.sync {
            extensionSeen.insert(snapshot.browserBundleID)
            var tabs: [Int: TabFact] = [:]
            for tab in snapshot.tabs ?? [] {
                tabs[tab.id] = TabFact(
                    audible: tab.audible ?? false,
                    playing: tab.playing,
                    mutedByUs: tab.mutedByUs ?? false
                )
            }
            browserFacts[snapshot.browserBundleID] = BrowserFacts(
                receivedAt: Date(),
                windowFocused: snapshot.windowFocused,
                activeTabID: snapshot.activeTabID.flatMap { $0 >= 0 ? $0 : nil },
                tabs: tabs
            )
           runDecision(trigger: "tab_state")
           command = tabCommand(for: snapshot.browserBundleID, contextID: snapshot.contextID)
            let active = snapshot.activeTabID.flatMap { $0 >= 0 ? $0 : nil }
            let audibleCount = tabs.values.filter { $0.audible }.count
            let activeAudible = active.flatMap { tabs[$0]?.audible } ?? false
            os_log(.info, log: Self.log,
                   "tabCmd %{public}@ active=%d activeAudible=%d audibleTabs=%d cmd=%{public}@",
                   snapshot.browserBundleID, active ?? -1, activeAudible ? 1 : 0, audibleCount,
                   command["muteAll"] as? Bool == true ? "muteAll"
                   : (command["noAction"] as? Bool == true ? "noAction" : "unmute+muteOthers"))
       }
       return command
   }

    /// Tab-level commands derived from the owner (design doc §6): only the
   /// owner browser gets actions; everyone else is handled at process level.
    private func tabCommand(for browser: String, contextID: String) -> [String: Any] {
        var command: [String: Any] = ["type": "state_command", "contextID": contextID]
        if case .tab(let ownerBrowser, let ownerTabID) = owner, ownerBrowser == browser {
            // This browser owns: restore its owner tab, mute the rest.
            command["actions"] = [
                ["kind": "unmute", "tabID": ownerTabID, "fade": true],
                ["kind": "muteOthers", "tabID": ownerTabID, "fade": true]
            ]
            return command
        }
        // Browsers are never muted at the CoreAudio process level (Fix A), so a
        // non-owner browser must mute all of its own tabs here. When there is no
        // owner at all, an audible focused tab is taken immediately (T2) before
        // this command is built, so muteAll never silences the tab we want.
        command["muteAll"] = true
        return command
    }

    func setSwitchDelay(_ delay: TimeInterval) {
        controlQueue.async { [weak self] in
            self?.switchDelay = max(0, delay)
            self?.dispatch(.settingsChanged)
        }
    }

    func setWhitelist(_ bundleIDs: Set<String>) {
        controlQueue.async { [weak self] in
            self?.whitelistBundleIDs = bundleIDs
            self?.dispatch(.settingsChanged)
        }
    }

    func unmuteAll() {
        dispatch(.unmuteAll)
    }

    // MARK: - CoreAudio pipeline

    private func getTapUID(_ tapID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value as String? : nil
    }

    private func createPipeline(for muted: [AudioProcessInfo]) -> Bool {
        destroyPipeline()
        guard !muted.isEmpty else {
            updateStatus("No background audio clients")
            return true
        }

        let tapDescription = CATapDescription(
            __stereoMixdownOfProcesses: muted.map(\.objectID) as [NSNumber]
        )
        tapDescription.name = "AudioFocus Background Tap"
        tapDescription.muteBehavior = .muted

        var newTapID: AudioObjectID = kAudioObjectUnknown
        var status = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard status == noErr else {
            fail("Tap create failed", status)
            return false
        }
        tapID = newTapID

        guard let tapUID = getTapUID(newTapID) else {
            fail("Tap UID unavailable", -1)
            destroyPipeline()
            return false
        }

        let subTap: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: true
        ]
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioFocus Private Aggregate",
            kAudioAggregateDeviceUIDKey: "com.audiofocus.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [subTap],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceIsPrivateKey: true
        ]

        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr else {
            fail("Aggregate device create failed", status)
            destroyPipeline()
            return false
        }
        aggregateDeviceID = newAggregateID

        var newIOProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(
            &newIOProcID,
            newAggregateID,
            ioQueue
        ) { _, _, _, _, _ in
            // Reading the aggregate device activates the process tap. Audio is discarded.
        }
        guard status == noErr, let newIOProcID else {
            fail("IOProc create failed", status)
            destroyPipeline()
            return false
        }
        ioProcID = newIOProcID

        status = AudioDeviceStart(newAggregateID, newIOProcID)
        guard status == noErr else {
            fail("Aggregate device start failed", status)
            destroyPipeline()
            return false
        }

        mutedObjectIDs = Set(muted.map(\.objectID))
        updateStatus("Active: \(muted.count) muted processes")
        os_log(.info, log: Self.log, "Pipeline active: tap=%u aggregate=%u muted=%d",
               newTapID, newAggregateID, muted.count)
        return true
    }

    private func destroyPipeline() {
        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        ioProcID = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        mutedObjectIDs.removeAll()
    }

    private func fail(_ message: String, _ status: OSStatus) {
        let text = "\(message) (\(status))"
        os_log(.error, log: Self.log, "%{public}@", text)
        updateStatus(text)
    }

    private func updateStatus(_ status: String) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.audioManagerDidChangeStatus(status)
        }
    }

    // MARK: - Polling

    func startPolling(interval: TimeInterval = 3.0) {
        pollTimer = DispatchSource.makeTimerSource(queue: controlQueue)
        pollTimer?.schedule(deadline: .now() + interval, repeating: interval)
        pollTimer?.setEventHandler { [weak self] in
            self?.dispatch(.poll)
        }
        pollTimer?.resume()
    }

    func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    deinit {
        stopPolling()
        destroyPipeline()
    }
}
