import AVFoundation
import CoreAudio
import os

final class ProcessTap {
    enum Event {
        case formatChanged
        case deviceStopped
        case stalled
        case layoutMismatch
        case layoutCleared
        case stallCleared
    }

    let format: AVAudioFormat
    var onEvent: ((Event) -> Void)?
    var isActive: () -> Bool = { true }

    private static let listenerKey = DispatchSpecificKey<Void>()
    private static let log = Logger(subsystem: "be.netronix.muninn", category: "process-tap")

    private let queue = DispatchQueue(label: "muninn.process-tap", qos: .userInteractive)
    private let listenerQueue = DispatchQueue(label: "muninn.process-tap.events")
    private let stateLock = NSLock()
    private var liveFormat: AVAudioFormat
    private let skippedInputStreams: Int
    private var mismatched = false
    private var watchdog = StallWatchdog(now: ProcessInfo.processInfo.systemUptime)
    private var watchdogTimer: DispatchSourceTimer?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var started = false
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    init(target: TapTarget, processes: () throws -> [AudioProcessInfo] = { try CoreAudioProcessList().processes() }) throws {
        let uuid = UUID()
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = noErr
        for attempt in try Self.attempts(for: target, processes: processes) {
            let description = attempt.description
            description.uuid = uuid
            description.name = "Muninn tap"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            status = AudioHardwareCreateProcessTap(description, &tapID)
            if status == noErr { break }
            Self.log.error("AudioHardwareCreateProcessTap failed (OSStatus \(status)) \(attempt.label, privacy: .public)")
        }
        guard status == noErr else {
            throw RecordingError.tapUnavailable("AudioHardwareCreateProcessTap failed (OSStatus \(status))")
        }

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Muninn tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var skipped = 0
        if let output = Self.defaultOutputDevice() {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = output.uid
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output.uid]]
            skipped = Self.inputStreamCount(output.id)
        }
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw RecordingError.tapUnavailable("AudioHardwareCreateAggregateDevice failed (OSStatus \(status))")
        }

        guard let format = Self.readFormat(tapID), format.commonFormat == .pcmFormatFloat32, format.channelCount > 0 else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw RecordingError.tapUnavailable("unsupported tap format")
        }
        self.tapID = tapID
        self.aggregateID = aggregateID
        self.format = format
        self.liveFormat = format
        self.skippedInputStreams = skipped
        listenerQueue.setSpecific(key: Self.listenerKey, value: ())
    }

    private struct TapAttempt {
        var description: CATapDescription
        var label: String
    }

    /// The descriptions to try in order. The first also carries the bundle IDs and process restore, so a helper that
    /// restarts rejoins the tap; the next is the plain process list, for when CoreAudio refuses that tap. The last taps only the detected
    /// process, for when a helper in the list has since exited and CoreAudio rejects the stale object.
    private static func attempts(for target: TapTarget, processes: () throws -> [AudioProcessInfo]) throws -> [TapAttempt] {
        switch target {
        case .allSystemAudio:
            let own = AudioProcessList.objectID(forPID: getpid()).map { [$0] } ?? []
            return [TapAttempt(description: CATapDescription(stereoGlobalTapButExcludeProcesses: own), label: "(all system audio)")]
        case .app(let bundleID, let pid):
            var resolved = (try? processes()).map {
                TapResolver.resolve(entry: bundleID, processes: $0, ownPID: getpid(), ignoredBundleIDs: CallDiff.ignoredBundleIDs)
            } ?? ResolvedTap(objectIDs: [], bundleIDs: [])
            let detected = pid == getpid() ? nil : AudioProcessList.objectID(forPID: pid)
            if resolved.objectIDs.isEmpty, let detected {
                resolved = ResolvedTap(objectIDs: [detected], bundleIDs: [])
            }
            guard !resolved.objectIDs.isEmpty else {
                throw RecordingError.tapUnavailable("\(bundleID) has no audio process")
            }
            log.info("Tapping \(resolved.objectIDs.count) audio process(es) of \(bundleID, privacy: .public)")
            let plain = TapAttempt(
                description: CATapDescription(stereoMixdownOfProcesses: resolved.objectIDs.map { AudioObjectID($0) }),
                label: "(processes only)"
            )
            var attempts = [plain]
            if !resolved.bundleIDs.isEmpty {
                let restoring = CATapDescription(stereoMixdownOfProcesses: resolved.objectIDs.map { AudioObjectID($0) })
                restoring.bundleIDs = resolved.bundleIDs
                restoring.isProcessRestoreEnabled = true
                attempts.insert(TapAttempt(description: restoring, label: "(with bundle IDs)"), at: 0)
            }
            if let detected, resolved.objectIDs != [detected] {
                attempts.append(TapAttempt(
                    description: CATapDescription(stereoMixdownOfProcesses: [AudioObjectID(detected)]),
                    label: "(detected process only)"
                ))
            }
            return attempts
        }
    }

    static func tapBufferRange(bufferCount: Int, skipping: Int, tapChannels: Int, interleaved: Bool) -> Range<Int>? {
        let needed = interleaved ? 1 : tapChannels
        guard skipping >= 0, needed > 0, bufferCount >= skipping + needed else { return nil }
        return skipping..<(skipping + needed)
    }

    func start(handler: @escaping (AVAudioPCMBuffer, UInt64) -> Void) throws {
        addListeners()
        startWatchdog()
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, inputTime, _, _ in
            guard let self, let (buffer, selected) = self.tapBuffer(from: input) else { return }
            defer { if let selected { free(selected) } }
            let hostTime = inputTime.pointee.mFlags.contains(.hostTimeValid) ? inputTime.pointee.mHostTime : mach_absolute_time()
            handler(buffer, hostTime)
        }
        guard status == noErr, let procID else {
            stop()
            throw RecordingError.tapUnavailable("AudioDeviceCreateIOProcIDWithBlock failed (OSStatus \(status))")
        }
        ioProcID = procID
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            stop()
            throw RecordingError.tapUnavailable("AudioDeviceStart failed (OSStatus \(status))")
        }
        started = true
    }

    func stop() {
        stopWatchdog()
        removeListeners()
        if started, let ioProcID { AudioDeviceStop(aggregateID, ioProcID) }
        if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
        started = false
        ioProcID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func tapBuffer(from input: UnsafePointer<AudioBufferList>) -> (AVAudioPCMBuffer, UnsafeMutablePointer<AudioBufferList>?)? {
        let format = stateLock.withLock {
            watchdog.noteCallback(at: ProcessInfo.processInfo.systemUptime)
            return liveFormat
        }
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let perBuffer = format.isInterleaved ? Int(format.channelCount) : 1
        guard let range = Self.tapBufferRange(
            bufferCount: source.count, skipping: skippedInputStreams,
            tapChannels: Int(format.channelCount), interleaved: format.isInterleaved
        ), source[range].allSatisfy({ Int($0.mNumberChannels) == perBuffer }) else {
            noteMismatch(buffers: source.count, format: format)
            return nil
        }
        if stateLock.withLock({ defer { mismatched = false }; return mismatched }) { onEvent?(.layoutCleared) }
        if skippedInputStreams == 0, range.count == source.count {
            return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil).map { ($0, nil) }
        }
        let selected = AudioBufferList.allocate(maximumBuffers: range.count)
        for (slot, index) in range.enumerated() { selected[slot] = source[index] }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: selected.unsafePointer, deallocator: nil) else {
            free(selected.unsafeMutablePointer)
            return nil
        }
        return (buffer, selected.unsafeMutablePointer)
    }

    private func noteMismatch(buffers: Int, format: AVAudioFormat) {
        let first = stateLock.withLock {
            defer { mismatched = true }
            return !mismatched
        }
        guard first else { return }
        Self.log.error("No tap buffers: \(buffers) input buffers, skipping \(self.skippedInputStreams), expecting \(format.channelCount) channels")
        onEvent?(.layoutMismatch)
    }

    private func startWatchdog() {
        stateLock.withLock { watchdog = StallWatchdog(now: ProcessInfo.processInfo.systemUptime) }
        let timer = DispatchSource.makeTimerSource(queue: listenerQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let active = self.isActive()
            let change = self.stateLock.withLock {
                self.watchdog.check(now: ProcessInfo.processInfo.systemUptime, active: active)
            }
            switch change {
            case .stalled: self.onEvent?(.stalled)
            case .resumed: self.onEvent?(.stallCleared)
            case nil: break
            }
        }
        watchdogTimer = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    private func addListeners() {
        let tapID = self.tapID
        let aggregateID = self.aggregateID
        let watched: [(AudioObjectID, AudioObjectPropertySelector, Bool)] = [
            (tapID, kAudioTapPropertyFormat, true),
            (aggregateID, kAudioDevicePropertyNominalSampleRate, true),
            (aggregateID, kAudioDevicePropertyDeviceIsAlive, false),
        ]
        for (object, selector, isFormat) in watched {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                if isFormat {
                    self.refreshFormat(tapID)
                } else if !Self.isAlive(aggregateID) {
                    self.onEvent?(.deviceStopped)
                }
            }
            if AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block) == noErr {
                listeners.append((object, address, block))
            }
        }
    }

    private func removeListeners() {
        for var listener in listeners {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, listenerQueue, listener.block)
        }
        listeners = []
        if DispatchQueue.getSpecific(key: Self.listenerKey) == nil { listenerQueue.sync {} }
    }

    private func refreshFormat(_ tapID: AudioObjectID) {
        guard let format = Self.readFormat(tapID), format.commonFormat == .pcmFormatFloat32, format.channelCount > 0 else { return }
        let changed = stateLock.withLock {
            defer { liveFormat = format }
            return liveFormat != format
        }
        if changed { onEvent?(.formatChanged) }
    }

    private static func isAlive(_ aggregateID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &alive) == noErr else { return false }
        return alive != 0
    }

    private static func readFormat(_ tapID: AudioObjectID) -> AVAudioFormat? {
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &description) == noErr else { return nil }
        return AVAudioFormat(streamDescription: &description)
    }

    private static func inputStreamCount(_ device: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioObjectID>.size
    }

    private static func defaultOutputDevice() -> (id: AudioObjectID, uid: String)? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
            device != AudioObjectID(kAudioObjectUnknown)
        else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return (device, uid.takeRetainedValue() as String)
    }
}
