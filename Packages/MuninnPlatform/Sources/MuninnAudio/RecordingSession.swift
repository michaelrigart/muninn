import AVFoundation
import CoreAudio
import MuninnCore

public enum TapTarget: Equatable, Sendable {
    /// Every audio process of the watched app. `bundleID` is the watch-list entry the call was detected under
    /// (`CallEvent.started`'s `bundleID`); `pid` is the detected process, used only when the process list can't be read.
    case app(bundleID: String, pid: pid_t)
    case allSystemAudio
}

public struct RecordingConfig: Sendable {
    public var micURL: URL
    public var systemURL: URL?
    public var tap: TapTarget?
    public var voiceProcessing: Bool

    public init(micURL: URL, systemURL: URL? = nil, tap: TapTarget? = nil, voiceProcessing: Bool = false) {
        self.micURL = micURL
        self.systemURL = systemURL
        self.tap = tap
        self.voiceProcessing = voiceProcessing
    }
}

public enum RecordingError: Error, Equatable, LocalizedError {
    case tapUnavailable(String)
    case micUnavailable(String)
    case fileUnavailable(String)
    case alreadyStarted

    public var errorDescription: String? {
        switch self {
        case .tapUnavailable(let reason): "System audio capture is unavailable: \(reason)"
        case .micUnavailable(let reason): "Microphone capture is unavailable: \(reason)"
        case .fileUnavailable(let reason): "The recording file cannot be created: \(reason)"
        case .alreadyStarted: "The recording was already started."
        }
    }
}

/// A track that stopped or is recovering during a recording. Cleared when the track recovers.
public enum RecordingInterruption: Equatable, Sendable {
    case configurationChanged(Track)
    case restartFailed(Track, String)
    case deviceStopped(Track)
    case writeFailed(Track, String)

    public var track: Track {
        switch self {
        case .configurationChanged(let track), .restartFailed(let track, _), .deviceStopped(let track), .writeFailed(let track, _): track
        }
    }
}

public final class RecordingSession: @unchecked Sendable {
    public let liveAudio: AsyncStream<LiveAudioChunk>

    private enum Phase { case idle, recording, stopped }

    enum SystemFault { case deviceStopped, stalled, layoutMismatch }

    private let config: RecordingConfig
    private let continuation: AsyncStream<LiveAudioChunk>.Continuation
    private let clock = HostClock()
    private let control = DispatchQueue(label: "muninn.recording.control")
    private let lock = NSLock()
    private var phase = Phase.idle
    private var finalDuration: TimeInterval = 0
    private var micPipeline: TrackPipeline?
    private var systemPipeline: TrackPipeline?
    private var engine: AVAudioEngine?
    private var tap: ProcessTap?
    private var configurationObserver: NSObjectProtocol?
    private var dropped = 0
    private var failures: [Track: Error] = [:]
    private var trackInterruptions: [Track: RecordingInterruption] = [:]
    private var systemFaults: Set<SystemFault> = []

    public init(config: RecordingConfig) {
        self.config = config
        let (stream, continuation) = AsyncStream<LiveAudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.liveAudio = stream
        self.continuation = continuation
    }

    deinit {
        guard phase != .stopped else { return }
        clock.finish(at: HostClock.now())
        let engine = self.engine, tap = self.tap, observer = configurationObserver
        let pipelines = [micPipeline, systemPipeline]
        let continuation = self.continuation
        // The last reference can be released on a capture callback queue, where the tap must not be torn down.
        control.async {
            Self.release(engine: engine, tap: tap, observer: observer, pipelines: pipelines)
            continuation.finish()
        }
    }

    public var elapsed: TimeInterval {
        let running = lock.withLock { phase == .recording }
        return running ? clock.seconds(at: HostClock.now()) : lock.withLock { finalDuration }
    }

    public var micLevel: Float { level(of: lock.withLock { micPipeline }) }

    public var systemLevel: Float { level(of: lock.withLock { systemPipeline }) }

    public var droppedLiveChunks: Int { lock.withLock { dropped } }

    public var writeErrors: [Track: Error] { lock.withLock { failures } }

    public var writeError: Error? { lock.withLock { failures[.mic] ?? failures[.system] } }

    public var interruptions: [Track: RecordingInterruption] { lock.withLock { merged() } }

    public var interruption: RecordingInterruption? {
        lock.withLock {
            let all = merged()
            let failed = [Track.system, .mic].compactMap { track in all[track].flatMap { Self.isWriteFailure($0) ? $0 : nil } }
            return failed.first ?? all[.system] ?? all[.mic]
        }
    }

    public func start() async throws {
        try lock.withLock {
            guard phase == .idle else { throw RecordingError.alreadyStarted }
            phase = .recording
            clock.begin(at: HostClock.now())
        }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            control.async {
                do {
                    try self.performStart()
                    done.resume()
                } catch {
                    self.abortStart()
                    done.resume(throwing: error)
                }
            }
        }
    }

    public func pause() {
        guard lock.withLock({ phase == .recording }) else { return }
        clock.pause(at: HostClock.now())
    }

    public func resume() {
        guard lock.withLock({ phase == .recording }) else { return }
        clock.resume(at: HostClock.now())
    }

    public func stop() async throws -> TimeInterval {
        let outcome: (duration: TimeInterval, wasRecording: Bool) = lock.withLock {
            switch phase {
            case .idle:
                phase = .stopped
                return (0, false)
            case .stopped:
                return (finalDuration, false)
            case .recording:
                let now = HostClock.now()
                clock.finish(at: now)
                phase = .stopped
                finalDuration = clock.seconds(at: now)
                return (finalDuration, true)
            }
        }
        if outcome.wasRecording {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                control.async {
                    self.teardown()
                    done.resume()
                }
            }
        }
        continuation.finish()
        return outcome.duration
    }

    private var isStopped: Bool { lock.withLock { phase == .stopped } }

    private func performStart() throws {
        guard !isStopped else { return }
        if let target = config.tap { try startSystem(target) }
        guard !isStopped else { return }
        try startMic()
    }

    private func abortStart() {
        clock.finish(at: HostClock.now())
        lock.withLock { phase = .stopped }
        teardown()
        continuation.finish()
    }

    private func startSystem(_ target: TapTarget) throws {
        let tap = try ProcessTap(target: target)
        var writer: TrackWriter?
        if let url = config.systemURL {
            do {
                writer = try TrackWriter(
                    url: url, sampleRate: tap.format.sampleRate, channels: Int(tap.format.channelCount), interleaved: true
                )
            } catch {
                tap.stop()
                throw RecordingError.fileUnavailable("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let pipeline = makePipeline(.system, writer: writer, sampleRate: tap.format.sampleRate, mode: .average)
        tap.onEvent = { [weak self] event in
            switch event {
            case .deviceStopped: self?.setSystemFault(.deviceStopped, raised: true)
            case .stalled: self?.setSystemFault(.stalled, raised: true)
            case .layoutMismatch: self?.setSystemFault(.layoutMismatch, raised: true)
            case .layoutCleared: self?.setSystemFault(.layoutMismatch, raised: false)
            case .stallCleared: self?.setSystemFault(.stalled, raised: false)
            case .formatChanged: break
            }
        }
        tap.isActive = { [weak self] in
            guard let self else { return false }
            return self.lock.withLock { self.phase == .recording } && !self.clock.isPaused(at: HostClock.now())
        }
        lock.withLock {
            self.tap = tap
            systemPipeline = pipeline
        }
        try tap.start { buffer, hostTime in pipeline.process(buffer, hostTime: hostTime) }
    }

    private func startMic() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(config.voiceProcessing)
        if config.voiceProcessing, input.isVoiceProcessingEnabled {
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false, duckingLevel: .min
            )
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecordingError.micUnavailable("no input device")
        }
        let writer: TrackWriter
        do {
            writer = try TrackWriter(url: config.micURL, sampleRate: format.sampleRate, channels: 1)
        } catch {
            throw RecordingError.fileUnavailable("\(config.micURL.lastPathComponent): \(error.localizedDescription)")
        }
        let pipeline = makePipeline(.mic, writer: writer, sampleRate: format.sampleRate, mode: .channelZero)
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.control.async { self?.restartMic() }
        }
        lock.withLock {
            self.engine = engine
            micPipeline = pipeline
            configurationObserver = observer
        }
        installMicTap(on: input, format: format, pipeline: pipeline)
        do {
            try engine.start()
        } catch {
            throw RecordingError.micUnavailable(error.localizedDescription)
        }
    }

    private func installMicTap(on input: AVAudioInputNode, format: AVAudioFormat, pipeline: TrackPipeline) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            pipeline.process(buffer, hostTime: when.isHostTimeValid ? when.hostTime : HostClock.now())
        }
    }

    private func restartMic() {
        let (engine, pipeline) = lock.withLock { (phase == .recording ? self.engine : nil, micPipeline) }
        guard let engine, let pipeline else { return }
        recoverMic {
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw RecordingError.micUnavailable("no input device")
            }
            self.installMicTap(on: input, format: format, pipeline: pipeline)
            try engine.start()
        }
    }

    func recoverMic(_ restart: () throws -> Void) {
        setInterruption(.configurationChanged(.mic), for: .mic)
        do {
            try restart()
            setInterruption(nil, for: .mic)
        } catch {
            setInterruption(.restartFailed(.mic, error.localizedDescription), for: .mic)
        }
    }

    private func makePipeline(_ track: Track, writer: TrackWriter?, sampleRate: Double, mode: MonoMode) -> TrackPipeline {
        TrackPipeline(
            track: track, writer: writer, sampleRate: sampleRate, monoMode: mode, clock: clock, continuation: continuation,
            onDrop: { [weak self] in self?.lock.withLock { self?.dropped += 1 } },
            onFailure: { [weak self] track, error in self?.noteWriteFailure(track, error) }
        )
    }

    func noteWriteFailure(_ track: Track, _ error: Error) {
        lock.withLock { if failures[track] == nil { failures[track] = error } }
    }

    /// Caller holds the lock. A write failure is permanent, since nothing reopens a closed writer, so it outranks the track's other state.
    private func merged() -> [Track: RecordingInterruption] {
        var all = trackInterruptions
        for (track, error) in failures { all[track] = .writeFailed(track, error.localizedDescription) }
        return all
    }

    private static func isWriteFailure(_ interruption: RecordingInterruption) -> Bool {
        if case .writeFailed = interruption { return true }
        return false
    }

    func setInterruption(_ value: RecordingInterruption?, for track: Track) {
        lock.withLock { trackInterruptions[track] = value }
    }

    func setSystemFault(_ fault: SystemFault, raised: Bool) {
        lock.withLock {
            if raised { systemFaults.insert(fault) } else { systemFaults.remove(fault) }
            if systemFaults.contains(.deviceStopped) || systemFaults.contains(.stalled) {
                trackInterruptions[.system] = .deviceStopped(.system)
            } else if systemFaults.contains(.layoutMismatch) {
                trackInterruptions[.system] = .restartFailed(.system, "unexpected tap buffer layout")
            } else {
                trackInterruptions[.system] = nil
            }
        }
    }

    private func teardown() {
        let (engine, tap, observer, pipelines) = lock.withLock {
            let state = (self.engine, self.tap, configurationObserver, [micPipeline, systemPipeline])
            self.engine = nil
            self.tap = nil
            configurationObserver = nil
            return state
        }
        Self.release(engine: engine, tap: tap, observer: observer, pipelines: pipelines)
    }

    private static func release(
        engine: AVAudioEngine?, tap: ProcessTap?, observer: NSObjectProtocol?, pipelines: [TrackPipeline?]
    ) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        tap?.stop()
        for pipeline in pipelines { pipeline?.close() }
    }

    private func level(of pipeline: TrackPipeline?) -> Float {
        guard let pipeline, !clock.isPaused(at: HostClock.now()) else { return LevelMeter.floor }
        return pipeline.currentLevel
    }
}
