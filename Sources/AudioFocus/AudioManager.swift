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
        let playing: Bool?
        let lastFocusedAt: Double?
        let lastAudibleAt: Double?
    }
    let browserBundleID: String
    let contextID: String
    let activeTabID: Int?
    let windowFocused: Bool
    let tabs: [Tab]?
}

/// All state-changing inputs funnel through this event type so ownership,
/// candidate, and recovery transitions stay on one serialized path.
private enum AudioEvent {
    case foregroundCandidate
    case recheckSilentCandidate(remainingAttempts: Int)
    case completeCandidateSwitch
    case ownerTerminated
    case browserOwnerActive
    case browserOwnerClosed
    case muteAllExcept
    case switchDelayChanged
    case whitelistChanged
    case poll
    case unmuteAll
}

@available(macOS 14.2, *)
final class AudioManager {
    private static let log = OSLog(subsystem: "com.audiofocus.app", category: "AudioManager")

    weak var delegate: AudioManagerDelegate?

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var pollTimer: DispatchSourceTimer?
    private var currentFocusBundleID: String?
    private var pendingForegroundBundleID: String?
    private var mutedObjectIDs = Set<AudioObjectID>()
    private var whitelistBundleIDs = Set<String>()
    private var switchDelay: TimeInterval = 0.5
    private var candidateGeneration = 0
    private var scheduledGeneration: Int?
    private var recentForegroundBundleIDs: [String] = []
    private var audibleOwnerHistory: [String] = []
    private var silentRecheckRemaining = 0
    private var pendingEventBundleID: String?
    private var terminatedEventBundleID: String?
    private var browserEventBundleID: String?
    private var tabContextStates: [String: TabContextState] = [:]

    private struct TabContextState {
        var ownerTabID: Int?
        var pendingTabID: Int?
        var pendingAt: Date?
    }

    private let ownerCloseDebounce: TimeInterval = 0.25
    private let silentCandidateRecheckInterval: TimeInterval = 0.25
    private let silentCandidateRecheckAttempts = 8

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

    // MARK: - Process selection

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
        }
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

    private func isSameFamily(_ first: String, _ second: String) -> Bool {
        first == second || first.hasPrefix(second + ".") || second.hasPrefix(first + ".")
    }

    private func rememberForeground(_ bundleID: String) {
        recentForegroundBundleIDs.removeAll { $0 == bundleID }
        recentForegroundBundleIDs.insert(bundleID, at: 0)
        if recentForegroundBundleIDs.count > 20 {
            recentForegroundBundleIDs.removeLast(recentForegroundBundleIDs.count - 20)
        }
    }

    private func rememberAudibleOwner(_ bundleID: String) {
        audibleOwnerHistory.removeAll { $0 == bundleID }
        audibleOwnerHistory.append(bundleID)
        if audibleOwnerHistory.count > 12 {
            audibleOwnerHistory.removeFirst(audibleOwnerHistory.count - 12)
        }
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

    // MARK: - Public API

    private func dispatch(_ event: AudioEvent) {
        controlQueue.async { [weak self] in
            self?.handle(event)
        }
    }

    /// Single serialized entry point for all state transitions.
    ///
    /// Every timer callback and every public API funnels through here, so the
    /// ownership, candidate, and recovery state machines cannot interleave.
    private func handle(_ event: AudioEvent) {
        switch event {
        case .foregroundCandidate:
            considerForegroundCandidateNow()

        case .recheckSilentCandidate(let remainingAttempts):
            guard let pending = pendingForegroundBundleID else { return }
            let latest = getAudioProcesses()
            if familyIsOutputting(pending, in: latest) {
                scheduleCandidate(pending, generation: candidateGeneration)
                return
            }
            guard remainingAttempts > 1 else {
                silentRecheckRemaining = 0
                return
            }
            silentRecheckRemaining = remainingAttempts - 1
            scheduleSilentCandidateRecheck(
                generation: candidateGeneration,
                remainingAttempts: silentRecheckRemaining
            )

        case .completeCandidateSwitch:
            guard let bundleID = pendingForegroundBundleID,
                  scheduledGeneration == candidateGeneration,
                  familyIsOutputting(bundleID, in: getAudioProcesses()) else {
                let owner = currentFocusBundleID ?? "none"
                updateStatus("Holding \(owner); candidate became silent")
                return
            }
            scheduledGeneration = nil
            applyFocus(bundleID)

        case .ownerTerminated:
            recoverForTerminatedOwner()

        case .browserOwnerActive:
            considerForegroundCandidateNow()

        case .browserOwnerClosed:
            guard let bundleID = browserEventBundleID,
                  let owner = currentFocusBundleID,
                  isSameFamily(bundleID, owner) else { return }

            candidateGeneration += 1
            scheduledGeneration = nil
            silentRecheckRemaining = 0
            audibleOwnerHistory.removeAll { isSameFamily($0, bundleID) }
            let all = getAudioProcesses()

            guard let previousOwner = audibleOwnerHistory.reversed().first(where: {
                familyExists($0, in: all)
            }) else {
                currentFocusBundleID = nil
                pendingForegroundBundleID = bundleID
                let muted = mutedProcesses(from: all, foreground: nil)
                _ = createPipeline(for: muted)
                updateStatus("Browser owner closed; waiting for audible foreground")
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.audioManagerDidUpdateProcessList(muted)
                }
                return
            }

            pendingForegroundBundleID = bundleID
            applyFocus(previousOwner, allProcesses: all, preservePending: true)
            updateStatus("Browser owner closed; restored \(previousOwner)")

        case .muteAllExcept:
            guard let bundleID = pendingEventBundleID ?? pendingForegroundBundleID,
                  !bundleID.isEmpty else { return }
            pendingForegroundBundleID = bundleID
            rememberForeground(bundleID)
            applyFocus(bundleID)

        case .switchDelayChanged:
            break

        case .whitelistChanged:
            guard let focus = currentFocusBundleID else { return }
            applyFocus(focus)

        case .poll:
            let all = getAudioProcesses()

            if let pending = pendingForegroundBundleID,
               familyIsOutputting(pending, in: all) {
                scheduleCandidate(pending, generation: candidateGeneration)
                return
            }

            guard let focus = currentFocusBundleID else { return }
            if !familyIsOutputting(focus, in: all) {
                recoverFromPoll(owner: focus, processes: all)
            }
            let muted = mutedProcesses(from: all, foreground: focus)
            let newIDs = Set(muted.map(\.objectID))
            if newIDs != mutedObjectIDs {
                _ = createPipeline(for: muted)
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.audioManagerDidUpdateProcessList(muted)
                }
            }

        case .unmuteAll:
            destroyPipeline()
            updateStatus("Paused")
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.audioManagerDidUpdateProcessList([])
            }
        }
    }

    /// Changes audio ownership only when the newly focused app is actually outputting audio.
    /// A silent window remains pending while the previous audible owner keeps playing.
    func considerForegroundCandidate(bundleID: String?) {
        guard let bundleID, !bundleID.isEmpty else { return }
        pendingForegroundBundleID = bundleID
        dispatch(.foregroundCandidate)
    }

    private func scheduleSilentCandidateRecheck(
        generation: Int,
        remainingAttempts: Int
    ) {
        guard remainingAttempts > 0 else { return }
        controlQueue.asyncAfter(deadline: .now() + silentCandidateRecheckInterval) { [weak self] in
            guard let self, self.candidateGeneration == generation else { return }
            self.dispatch(.recheckSilentCandidate(remainingAttempts: remainingAttempts))
        }
    }

    private func scheduleInactiveOwnerRecovery(generation: Int, force: Bool = false) {
        controlQueue.asyncAfter(deadline: .now() + ownerCloseDebounce) { [weak self] in
            guard let self, self.candidateGeneration == generation else { return }
            self.runInactiveOwnerRecovery(generation: generation, force: force)
        }
    }

    private func considerForegroundCandidateNow() {
        guard let bundleID = pendingEventBundleID ?? pendingForegroundBundleID,
              !bundleID.isEmpty else { return }
        pendingForegroundBundleID = bundleID
        rememberForeground(bundleID)
        candidateGeneration += 1
        scheduledGeneration = nil
        silentRecheckRemaining = 0
        let all = getAudioProcesses()

        if currentFocusBundleID == nil || familyIsOutputting(bundleID, in: all) {
            scheduleCandidate(bundleID, generation: candidateGeneration)
        } else {
            let owner = currentFocusBundleID ?? "none"
            updateStatus("Holding \(owner); front window is silent")
            scheduleInactiveOwnerRecovery(generation: candidateGeneration)
            silentRecheckRemaining = silentCandidateRecheckAttempts
            scheduleSilentCandidateRecheck(
                generation: candidateGeneration,
                remainingAttempts: silentRecheckRemaining
            )
        }
    }

    private func recoverForTerminatedOwner() {
        guard let owner = currentFocusBundleID,
              let terminatedBundleID = terminatedEventBundleID,
              isSameFamily(terminatedBundleID, owner) else { return }
        let all = getAudioProcesses()
        guard !familyIsOutputting(owner, in: all) else { return }
        runInactiveOwnerRecovery(generation: candidateGeneration, force: true)
    }

    private func recoverFromPoll(owner: String, processes: [AudioProcessInfo]) {
        guard !familyIsOutputting(owner, in: processes) else { return }

        if let terminatedBundleID = terminatedEventBundleID,
           !isSameFamily(terminatedBundleID, owner) {
            return
        }
        let foregroundMovedAway = pendingForegroundBundleID.map { $0 != owner } ?? false
        guard !familyExists(owner, in: processes) || foregroundMovedAway else {
            // Browsers briefly stop output while navigating. Keep their process
            // family excluded from the mute pipeline until it resumes.
            return
        }

        let savedFocus = owner
        runInactiveOwnerRecovery(generation: candidateGeneration, processes: processes)
        guard currentFocusBundleID == savedFocus else { return }
    }

    private func runInactiveOwnerRecovery(
        generation: Int,
        processes: [AudioProcessInfo]? = nil,
        force: Bool = false
    ) {
        guard candidateGeneration == generation,
              let owner = currentFocusBundleID else { return }

        let all = processes ?? getAudioProcesses()
        guard !familyIsOutputting(owner, in: all) else { return }
        let foregroundMovedAway = pendingForegroundBundleID.map { $0 != owner } ?? false
        guard force || !familyExists(owner, in: all) || foregroundMovedAway else {
            // Browsers briefly stop output while navigating. Keep their process
            // family excluded from the mute pipeline until it resumes.
            return
        }

        if let candidate = recoveryCandidate(excluding: owner, in: all) {
            let preservePending = candidate != pendingForegroundBundleID
            updateStatus("Owner closed; restoring \(candidate)")
            applyFocus(candidate, allProcesses: all, preservePending: preservePending)
            return
        }

        currentFocusBundleID = nil
        scheduledGeneration = nil
        let muted = mutedProcesses(from: all, foreground: nil)
        _ = createPipeline(for: muted)
        updateStatus("Owner closed; waiting for audible foreground")
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.audioManagerDidUpdateProcessList(muted)
        }
    }

    private func recoveryCandidate(
        excluding owner: String,
        in processes: [AudioProcessInfo]
    ) -> String? {
        if let pending = pendingForegroundBundleID,
           pending != owner,
           familyIsOutputting(pending, in: processes) {
            return pending
        }

        return recentForegroundBundleIDs.first {
            $0 != owner
                && !protectedBundleIDs.contains($0)
                && !isWhitelistedFamily($0)
                && familyIsOutputting($0, in: processes)
        }
    }

    private func scheduleCandidate(_ bundleID: String, generation: Int) {
        guard scheduledGeneration != generation else { return }
        scheduledGeneration = generation

        if switchDelay > 0 {
            updateStatus(String(format: "Switching in %.2fs if audio stays active", switchDelay))
        }

        controlQueue.asyncAfter(deadline: .now() + switchDelay) { [weak self] in
            guard let self,
                  self.candidateGeneration == generation,
                  self.pendingForegroundBundleID == bundleID else { return }
            self.dispatch(.completeCandidateSwitch)
        }
    }

    private func applyFocus(
        _ bundleID: String,
        allProcesses: [AudioProcessInfo]? = nil,
        preservePending: Bool = false
    ) {
        currentFocusBundleID = bundleID
        if !preservePending {
            pendingForegroundBundleID = nil
        }
        scheduledGeneration = nil
        let all = allProcesses ?? getAudioProcesses()
        if familyIsOutputting(bundleID, in: all) {
            rememberAudibleOwner(bundleID)
        }
        let muted = mutedProcesses(from: all, foreground: bundleID)
        _ = createPipeline(for: muted)
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.audioManagerDidUpdateProcessList(muted)
        }
    }

    func muteAllExcept(bundleID: String?) {
        guard let bundleID, !bundleID.isEmpty else { return }
        pendingForegroundBundleID = bundleID
        dispatch(.muteAllExcept)
    }

    func considerOwnerTermination(bundleID: String?) {
        guard let bundleID else { return }
        terminatedEventBundleID = bundleID
        dispatch(.ownerTerminated)
    }

    /// Restores the prior audible app after a browser confirms that its owner tab
    /// closed and the replacement active tab is still silent.
    func browserOwnerDidClose(bundleID: String?) {
        guard let bundleID else { return }
        browserEventBundleID = bundleID
        dispatch(.browserOwnerClosed)
    }

    func setSwitchDelay(_ delay: TimeInterval) {
        switchDelay = max(0, delay)
        dispatch(.switchDelayChanged)
    }

    func setWhitelist(_ bundleIDs: Set<String>) {
        whitelistBundleIDs = bundleIDs
        dispatch(.whitelistChanged)
    }

    /// Evaluates a browser tab snapshot and returns a `state_command` payload
    /// for the extension to apply. Runs on the control queue.
    func evaluateTabState(_ snapshot: TabSnapshot) -> [String: Any] {
        var result: [String: Any] = [:]
        controlQueue.sync {
            result = evaluateTabStateOnQueue(snapshot)
        }
        return result
    }

    private func evaluateTabStateOnQueue(_ snapshot: TabSnapshot) -> [String: Any] {
        var command: [String: Any] = [
            "type": "state_command",
            "contextID": snapshot.contextID
        ]
        var context = tabContextStates[snapshot.contextID] ?? TabContextState()

        let browserIsOwner = currentFocusBundleID.map {
            isSameFamily(snapshot.browserBundleID, $0)
        } ?? false
        let foregroundIsBrowser = (pendingEventBundleID ?? pendingForegroundBundleID).map {
            isSameFamily(snapshot.browserBundleID, $0)
        } ?? false

        guard browserIsOwner || foregroundIsBrowser, snapshot.windowFocused else {
            context.ownerTabID = nil
            context.pendingTabID = nil
            context.pendingAt = nil
            tabContextStates[snapshot.contextID] = context
            command["muteAll"] = true
            return command
        }

        guard let activeTabID = snapshot.activeTabID else {
            command["muteAll"] = true
            return command
        }
        let activeTab = snapshot.tabs?.first { $0.id == activeTabID }
        let activeTabIsPlaying = activeTab?.audible == true || activeTab?.playing == true

        guard activeTabIsPlaying else {
            context.ownerTabID = nil
            context.pendingTabID = nil
            context.pendingAt = nil
            tabContextStates[snapshot.contextID] = context
            command["muteAll"] = true
            return command
        }

        if context.ownerTabID == activeTabID {
            command["actions"] = [
                ["kind": "unmute", "tabID": activeTabID, "fade": true]
            ]
            return command
        }

        if context.pendingTabID == activeTabID,
           let pendingAt = context.pendingAt,
           Date().timeIntervalSince(pendingAt) >= switchDelay {
            context.ownerTabID = activeTabID
            context.pendingTabID = nil
            context.pendingAt = nil
            tabContextStates[snapshot.contextID] = context
            command["actions"] = [
                ["kind": "unmute", "tabID": activeTabID, "fade": true]
            ]
            return command
        }

        if context.pendingTabID != activeTabID {
            context.pendingTabID = activeTabID
            context.pendingAt = Date()
            tabContextStates[snapshot.contextID] = context
        }
        command["muteAll"] = true
        return command
    }

    func unmuteAll() {
        dispatch(.unmuteAll)
    }

    // MARK: - Polling

    func startPolling(interval: TimeInterval = 3.0) {
        pollTimer = DispatchSource.makeTimerSource(queue: controlQueue)
        pollTimer?.schedule(deadline: .now() + interval, repeating: interval)
        pollTimer?.setEventHandler { [weak self] in
            guard let self else { return }
            self.dispatch(.poll)
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
