import CoreAudio
import AudioToolbox
import Foundation
import os.log

struct AudioProcessInfo: Equatable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    var isRunning: Bool
}

protocol AudioManagerDelegate: AnyObject {
    func audioManagerDidUpdateProcessList(_ mutedProcesses: [AudioProcessInfo])
    func audioManagerDidChangeStatus(_ status: String)
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
            return AudioProcessInfo(
                objectID: objectID,
                pid: getPID(objectID),
                bundleID: bundleID,
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

    private func mutedProcesses(from all: [AudioProcessInfo], foreground: String?) -> [AudioProcessInfo] {
        all.filter {
            !protectedBundleIDs.contains($0.bundleID)
                && !isWhitelistedFamily($0.bundleID)
                && !isForegroundFamily($0.bundleID, foreground: foreground)
        }
    }

    private func isWhitelistedFamily(_ candidate: String) -> Bool {
        whitelistBundleIDs.contains {
            candidate == $0 || candidate.hasPrefix($0 + ".")
        }
    }

    private func familyIsOutputting(_ bundleID: String, in processes: [AudioProcessInfo]) -> Bool {
        processes.contains {
            isForegroundFamily($0.bundleID, foreground: bundleID) && $0.isRunning
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

    /// Changes audio ownership only when the newly focused app is actually outputting audio.
    /// A silent window remains pending while the previous audible owner keeps playing.
    func considerForegroundCandidate(bundleID: String?) {
        controlQueue.async { [weak self] in
            guard let self, let bundleID, !bundleID.isEmpty else { return }
            self.pendingForegroundBundleID = bundleID
            self.candidateGeneration += 1
            self.scheduledGeneration = nil
            let all = self.getAudioProcesses()

            if self.currentFocusBundleID == nil || self.familyIsOutputting(bundleID, in: all) {
                self.scheduleCandidate(bundleID, generation: self.candidateGeneration)
            } else {
                let owner = self.currentFocusBundleID ?? "none"
                self.updateStatus("Holding \(owner); front window is silent")
            }
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
            self.scheduledGeneration = nil

            let latest = self.getAudioProcesses()
            guard self.currentFocusBundleID == nil || self.familyIsOutputting(bundleID, in: latest) else {
                let owner = self.currentFocusBundleID ?? "none"
                self.updateStatus("Holding \(owner); candidate became silent")
                return
            }
            self.applyFocus(bundleID, allProcesses: latest)
        }
    }

    private func applyFocus(_ bundleID: String, allProcesses: [AudioProcessInfo]? = nil) {
        currentFocusBundleID = bundleID
        pendingForegroundBundleID = nil
        scheduledGeneration = nil
        let all = allProcesses ?? getAudioProcesses()
        let muted = mutedProcesses(from: all, foreground: bundleID)
        _ = createPipeline(for: muted)
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.audioManagerDidUpdateProcessList(muted)
        }
    }

    func muteAllExcept(bundleID: String?) {
        controlQueue.async { [weak self] in
            guard let self, let bundleID, !bundleID.isEmpty else { return }
            self.applyFocus(bundleID)
        }
    }

    func setSwitchDelay(_ delay: TimeInterval) {
        controlQueue.async { [weak self] in
            self?.switchDelay = max(0, delay)
        }
    }

    func setWhitelist(_ bundleIDs: Set<String>) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.whitelistBundleIDs = bundleIDs
            guard let focus = self.currentFocusBundleID else { return }
            self.applyFocus(focus)
        }
    }

    func unmuteAll() {
        controlQueue.sync {
            destroyPipeline()
        }
        updateStatus("Paused")
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.audioManagerDidUpdateProcessList([])
        }
    }

    // MARK: - Polling

    func startPolling(interval: TimeInterval = 3.0) {
        pollTimer = DispatchSource.makeTimerSource(queue: controlQueue)
        pollTimer?.schedule(deadline: .now() + interval, repeating: interval)
        pollTimer?.setEventHandler { [weak self] in
            guard let self else { return }
            let all = self.getAudioProcesses()

            if let pending = self.pendingForegroundBundleID,
               self.familyIsOutputting(pending, in: all) {
                self.scheduleCandidate(pending, generation: self.candidateGeneration)
                return
            }

            guard let focus = self.currentFocusBundleID else { return }
            let muted = self.mutedProcesses(from: all, foreground: focus)
            let newIDs = Set(muted.map(\.objectID))
            if newIDs != self.mutedObjectIDs {
                _ = self.createPipeline(for: muted)
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.audioManagerDidUpdateProcessList(muted)
                }
            }
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
