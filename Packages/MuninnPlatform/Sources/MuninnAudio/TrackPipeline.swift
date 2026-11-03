import AVFoundation
import MuninnCore

final class TrackPipeline {
    static let liveChunkSamples = 4_800
    static let gapTolerance = 0.05

    private let track: Track
    private let rate: Double
    private let monoMode: MonoMode
    private let clock: HostClock
    private let continuation: AsyncStream<LiveAudioChunk>.Continuation
    private let onDrop: () -> Void
    private let onFailure: (Track, Error) -> Void
    private let lock = NSLock()
    private let resampler = MonoResampler()
    private var writer: TrackWriter?
    private var position = 0
    private var pending: [Float] = []
    private var pendingStart = 0.0
    private var level = LevelMeter.floor
    private var closed = false

    init(
        track: Track,
        writer: TrackWriter?,
        sampleRate: Double,
        monoMode: MonoMode,
        clock: HostClock,
        continuation: AsyncStream<LiveAudioChunk>.Continuation,
        onDrop: @escaping () -> Void = {},
        onFailure: @escaping (Track, Error) -> Void = { _, _ in }
    ) {
        self.track = track
        self.writer = writer
        self.rate = sampleRate
        self.monoMode = monoMode
        self.clock = clock
        self.continuation = continuation
        self.onDrop = onDrop
        self.onFailure = onFailure
    }

    var currentLevel: Float { lock.withLock { level } }

    var framesWritten: Int { lock.withLock { position } }

    var isClosed: Bool { lock.withLock { closed } }

    func process(_ incoming: AVAudioPCMBuffer, hostTime: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, incoming.frameLength > 0 else { return }
        let sourceRate = incoming.format.sampleRate
        let frames = Int(incoming.frameLength)
        let end = hostTime + AVAudioTime.hostTime(forSeconds: Double(frames) / sourceRate)
        let active = clock.activeIntervals(from: hostTime, to: end)
        if active == [HostClock.Interval(from: hostTime, to: end)] {
            append(incoming, hostTime: hostTime)
            return
        }
        for interval in active {
            let first = Int((AVAudioTime.seconds(forHostTime: interval.from - hostTime) * sourceRate).rounded())
            let last = interval.to >= end
                ? frames : Int((AVAudioTime.seconds(forHostTime: interval.to - hostTime) * sourceRate).rounded())
            if let part = AudioSamples.slice(incoming, from: first, to: last) { append(part, hostTime: interval.from) }
        }
    }

    /// Writes one stretch of audio that lies wholly in the recorded part of the timeline. Caller holds the lock.
    private func append(_ incoming: AVAudioPCMBuffer, hostTime: UInt64) {
        var buffer = incoming
        let gap = Int((clock.seconds(at: hostTime) * rate).rounded()) - position
        if Double(gap) > Self.gapTolerance * rate {
            flushPending()
            pad(frames: gap)
        } else if Double(-gap) > Self.gapTolerance * rate {
            let ahead = Int((Double(-gap) * incoming.format.sampleRate / rate).rounded())
            guard ahead < Int(incoming.frameLength) else { return }
            if let trimmed = AudioSamples.dropHead(incoming, frames: ahead) { buffer = trimmed }
        }
        let start = Double(position) / rate
        let sourceRate = buffer.format.sampleRate
        let mono = AudioSamples.mono(buffer, mode: monoMode)
        level = mono.withUnsafeBufferPointer { LevelMeter.dbfs($0) }
        var written = Int((Double(buffer.frameLength) * rate / sourceRate).rounded())
        if let writer {
            do {
                written = try writer.append(buffer)
            } catch {
                self.writer?.close()
                self.writer = nil
                onFailure(track, error)
            }
        }
        position += written
        let samples = resampler.convert(mono, sampleRate: sourceRate)
        guard !samples.isEmpty else { return }
        if pending.isEmpty { pendingStart = start }
        pending.append(contentsOf: samples)
        if pending.count >= Self.liveChunkSamples { flushPending() }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        flushPending()
        closed = true
        writer?.close()
        writer = nil
    }

    private func pad(frames: Int) {
        if let writer {
            do {
                try writer.appendSilence(frames: frames)
            } catch {
                self.writer?.close()
                self.writer = nil
                onFailure(track, error)
            }
        }
        position += frames
    }

    private func flushPending() {
        guard !pending.isEmpty else { return }
        let chunk = LiveAudioChunk(track: track, samples: pending, time: pendingStart)
        pending = []
        if case .dropped = continuation.yield(chunk) { onDrop() }
    }
}
