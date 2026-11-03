import AVFoundation
import MuninnCore
import Testing
@testable import MuninnAudio

private func makeBuffer(sampleRate: Double, frames: Int, channels: Int = 1, value: (Int) -> Float) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for channel in 0..<channels {
        let data = buffer.floatChannelData![channel]
        for frame in 0..<frames { data[frame] = value(frame) }
    }
    return buffer
}

@Test func levelMeterSilence() {
    let zeros = [Float](repeating: 0, count: 1024)
    #expect(zeros.withUnsafeBufferPointer { LevelMeter.dbfs($0) } == -160)
    #expect(LevelMeter.dbfs(UnsafeBufferPointer<Float>(start: nil, count: 0)) == -160)
}

@Test func levelMeterFullScale() {
    let ones = [Float](repeating: 1, count: 1024)
    let level = ones.withUnsafeBufferPointer { LevelMeter.dbfs($0) }
    #expect(abs(level) < 0.001)
    let half = [Float](repeating: 0.5, count: 1024)
    #expect(abs(half.withUnsafeBufferPointer { LevelMeter.dbfs($0) } + 6.02) < 0.01)
}

@Test func resamplerHalvesLength32kTo16k() {
    let buffer = makeBuffer(sampleRate: 32_000, frames: 32_000) { sin(Float($0) * 2 * .pi * 440 / 32_000) }
    let samples = Resampler.toMono16k(buffer)
    #expect(abs(samples.count - 16_000) <= 64)
}

@Test func resamplerMixesStereoToMono() {
    let buffer = makeBuffer(sampleRate: 16_000, frames: 1_600, channels: 2) { _ in 0.25 }
    let samples = Resampler.toMono16k(buffer)
    #expect(abs(samples.count - 1_600) <= 16)
    #expect(abs((samples.dropFirst(100).first ?? 0) - 0.25) < 0.01)
}

@Test func trackWriterRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("trackwriter-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try TrackWriter(url: url, sampleRate: 48_000, channels: 1)
    let buffer = makeBuffer(sampleRate: 48_000, frames: 48_000) { sin(Float($0) * 2 * .pi * 440 / 48_000) }
    try writer.append(buffer)
    writer.close()

    let file = try AVAudioFile(forReading: url)
    #expect(file.length == 48_000)
    #expect(file.processingFormat.sampleRate == 48_000)
    #expect(file.processingFormat.channelCount == 1)
    let samples = try readChannel(file)
    #expect(samples.count == 48_000)
    for frame in [0, 1, 100, 12_345, 47_999] {
        #expect(abs(samples[frame] - buffer.floatChannelData![0][frame]) < 1.0 / 16_384)
    }
}

@Test func trackWriterStoresSixteenBitIntegersAndReadsBackAsFloat() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try TrackWriter(url: url, sampleRate: 48_000, channels: 2, interleaved: true)
    try writer.append(makeBuffer(sampleRate: 48_000, frames: 4_800, channels: 2) { _ in 0.5 })
    writer.close()

    let file = try AVAudioFile(forReading: url)
    let stored = file.fileFormat.streamDescription.pointee
    #expect(stored.mBitsPerChannel == 16)
    #expect(stored.mFormatFlags & kAudioFormatFlagIsFloat == 0)
    #expect(file.fileFormat.commonFormat == .pcmFormatInt16)
    #expect(file.processingFormat.commonFormat == .pcmFormatFloat32)
    #expect(file.processingFormat.sampleRate == 48_000)
    #expect(file.length == 4_800)
    #expect(try readChannel(file, 1)[100] == 0.5)
    // 32-bit float would need 4 800 x 2 x 4 = 38 400 bytes of samples
    #expect(sizeOnDisk(url) < 4_800 * 2 * 4)
}

private func sizeOnDisk(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
}

@Test func trackWriterKeepsStereo() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("trackwriter-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try TrackWriter(url: url, sampleRate: 44_100, channels: 2)
    try writer.append(makeBuffer(sampleRate: 44_100, frames: 4_410, channels: 2) { _ in 0.1 })
    writer.close()
    let file = try AVAudioFile(forReading: url)
    #expect(file.length == 4_410)
    #expect(file.processingFormat.channelCount == 2)
}

private func ticks(_ seconds: Double) -> UInt64 { AVAudioTime.hostTime(forSeconds: seconds) }

private func readChannel(_ file: AVAudioFile, _ channel: Int = 0) throws -> [Float] {
    let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096)!
    var samples: [Float] = []
    file.framePosition = 0
    while file.framePosition < file.length {
        try file.read(into: chunk)
        guard chunk.frameLength > 0 else { break }
        let source = AudioSamples.channel(chunk, channel)
        samples += (0..<Int(chunk.frameLength)).map { source.data[$0 * source.stride] }
    }
    return samples
}

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("recording-\(UUID().uuidString).caf")
}

private func makePipeline(
    track: Track = .mic, rate: Double = 16_000, clock: HostClock, writer: TrackWriter? = nil,
    stream: AsyncStream<LiveAudioChunk>.Continuation, onDrop: @escaping () -> Void = {}
) -> TrackPipeline {
    TrackPipeline(
        track: track, writer: writer, sampleRate: rate, monoMode: .channelZero, clock: clock,
        continuation: stream, onDrop: onDrop
    )
}

@Test func hostClockExcludesPausedIntervals() {
    let clock = HostClock()
    clock.begin(at: ticks(100))
    clock.pause(at: ticks(101))
    clock.resume(at: ticks(103))
    #expect(abs(clock.seconds(at: ticks(102)) - 1) < 0.001)
    #expect(abs(clock.seconds(at: ticks(104)) - 2) < 0.001)
    #expect(clock.isPaused(at: ticks(102)))
    #expect(!clock.isPaused(at: ticks(103.5)))
    clock.finish(at: ticks(105))
    #expect(abs(clock.seconds(at: ticks(200)) - 3) < 0.001)
    #expect(clock.isPaused(at: ticks(105.1)))
}

@Test func pauseBeforeFirstBufferKeepsTracksAligned() throws {
    let clock = HostClock()
    clock.begin(at: ticks(100))
    clock.pause(at: ticks(100.1))
    clock.resume(at: ticks(101.1))
    let (_, continuation) = AsyncStream<LiveAudioChunk>.makeStream()
    let micURL = tempURL(), systemURL = tempURL()
    defer { try? FileManager.default.removeItem(at: micURL); try? FileManager.default.removeItem(at: systemURL) }
    let mic = makePipeline(track: .mic, rate: 16_000, clock: clock, writer: try TrackWriter(url: micURL, sampleRate: 16_000, channels: 1), stream: continuation)
    let system = makePipeline(track: .system, rate: 16_000, clock: clock, writer: try TrackWriter(url: systemURL, sampleRate: 16_000, channels: 1), stream: continuation)
    let buffer = makeBuffer(sampleRate: 16_000, frames: 1_600) { _ in 0.5 }

    // arrives while paused: dropped
    mic.process(buffer, hostTime: ticks(100.5))
    #expect(mic.framesWritten == 0)

    // 0.5 s into the recording on the recording clock (1.0 s of host time is paused), on both tracks
    mic.process(buffer, hostTime: ticks(101.5))
    system.process(buffer, hostTime: ticks(101.5))
    #expect(mic.framesWritten == 8_000 + 1_600)
    #expect(system.framesWritten == mic.framesWritten)
    mic.close()
    system.close()
    #expect(try AVAudioFile(forReading: micURL).length == 9_600)
}

@Test func gapMidRecordingIsPadded() throws {
    let clock = HostClock()
    clock.begin(at: ticks(100))
    let (_, continuation) = AsyncStream<LiveAudioChunk>.makeStream()
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let pipeline = makePipeline(clock: clock, writer: try TrackWriter(url: url, sampleRate: 16_000, channels: 1), stream: continuation)
    let buffer = makeBuffer(sampleRate: 16_000, frames: 1_600) { _ in 0.5 }
    pipeline.process(buffer, hostTime: ticks(100))
    pipeline.process(buffer, hostTime: ticks(100.1))
    #expect(pipeline.framesWritten == 3_200)
    // 30 ms late: below the 50 ms tolerance, not padded
    pipeline.process(buffer, hostTime: ticks(100.23))
    #expect(pipeline.framesWritten == 4_800)
    // 0.3 s gap: padded with silence
    pipeline.process(buffer, hostTime: ticks(100.8))
    #expect(pipeline.framesWritten == 12_800 + 1_600)
    pipeline.close()
    let file = try AVAudioFile(forReading: url)
    #expect(file.length == 14_400)
}

@Test func liveChunksAccumulateAndCarryTheAlignedTime() async {
    let clock = HostClock()
    clock.begin(at: ticks(100))
    let (stream, continuation) = AsyncStream<LiveAudioChunk>.makeStream()
    let pipeline = makePipeline(track: .system, clock: clock, stream: continuation)
    let buffer = makeBuffer(sampleRate: 16_000, frames: 1_600) { _ in 0.5 }
    var iterator = stream.makeAsyncIterator()

    // first buffer is 1 s late: the chunk starts at t = 1.0 and holds 300 ms or more
    for index in 0..<3 { pipeline.process(buffer, hostTime: ticks(101 + Double(index) * 0.1)) }
    let first = await iterator.next()
    #expect(first?.track == .system)
    #expect(abs((first?.time ?? 0) - 1.0) < 0.001)
    #expect(first?.samples.count == 4_800)

    pipeline.process(buffer, hostTime: ticks(101.3))
    #expect(pipeline.isClosed == false)
    #expect(abs(pipeline.currentLevel + 6.02) < 0.05)
    pipeline.close()
    #expect(pipeline.isClosed)
    let rest = await iterator.next()
    #expect(rest?.samples.count == 1_600)
    #expect(abs((rest?.time ?? 0) - 1.3) < 0.001)

    let before = pipeline.framesWritten
    pipeline.process(buffer, hostTime: ticks(101.4))
    #expect(pipeline.framesWritten == before)
}

@Test func droppedLiveChunksAreCounted() {
    let clock = HostClock()
    clock.begin(at: ticks(100))
    let (stream, continuation) = AsyncStream<LiveAudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { withExtendedLifetime(stream) {} }
    var drops = 0
    let pipeline = makePipeline(clock: clock, stream: continuation, onDrop: { drops += 1 })
    let buffer = makeBuffer(sampleRate: 16_000, frames: 4_800) { _ in 0.1 }
    for index in 0..<4 { pipeline.process(buffer, hostTime: ticks(100 + Double(index) * 0.3)) }
    #expect(drops == 3)
}

@Test func resamplerIsContinuousAcrossChunks() {
    let rate = 32_000.0
    let signal = (0..<32_000).map { sin(Float($0) * 2 * .pi * 440 / Float(rate)) }
    let whole = MonoResampler().convert(signal, sampleRate: rate)
    let chunked = MonoResampler()
    var pieces: [Float] = []
    for start in stride(from: 0, to: signal.count, by: 3_200) {
        pieces += chunked.convert(Array(signal[start..<min(start + 3_200, signal.count)]), sampleRate: rate)
    }
    #expect(abs(pieces.count - whole.count) <= 2)
    let common = min(pieces.count, whole.count)
    let worst = (0..<common).map { abs(pieces[$0] - whole[$0]) }.max() ?? 1
    #expect(worst < 0.01)
}

@Test func tapBufferRangeSkipsTheSubDeviceInputStreams() {
    #expect(ProcessTap.tapBufferRange(bufferCount: 2, skipping: 1, tapChannels: 2, interleaved: true) == 1..<2)
    #expect(ProcessTap.tapBufferRange(bufferCount: 1, skipping: 1, tapChannels: 2, interleaved: true) == nil)
    #expect(ProcessTap.tapBufferRange(bufferCount: 3, skipping: 1, tapChannels: 2, interleaved: false) == 1..<3)
    #expect(ProcessTap.tapBufferRange(bufferCount: 2, skipping: 0, tapChannels: 2, interleaved: true) == 0..<1)
}

@Test func trackWriterConvertsRateAndChannels() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try TrackWriter(url: url, sampleRate: 48_000, channels: 1)
    let stereo = makeBuffer(sampleRate: 44_100, frames: 44_100, channels: 2) { _ in 0.25 }
    let written = try writer.append(stereo)
    writer.close()
    let file = try AVAudioFile(forReading: url)
    #expect(abs(Int(file.length) - 48_000) <= 128)
    #expect(Int(file.length) == written)
}

@Test func trackWriterTakesChannelZeroForMono() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try TrackWriter(url: url, sampleRate: 16_000, channels: 1)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 2, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
    buffer.frameLength = 100
    for frame in 0..<100 {
        buffer.floatChannelData![0][frame] = 0.5
        buffer.floatChannelData![1][frame] = -0.5
    }
    try writer.append(buffer)
    writer.close()
    let file = try AVAudioFile(forReading: url)
    #expect(try readChannel(file)[10] == 0.5)
}

@Test func trackWriterInterleavedStereoFromStreamDescription() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    var description = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
        mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
    )
    let format = AVAudioFormat(streamDescription: &description)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
    buffer.frameLength = 480
    for frame in 0..<480 {
        buffer.floatChannelData![0][frame * 2] = 0.25
        buffer.floatChannelData![0][frame * 2 + 1] = -0.25
    }
    let writer = try TrackWriter(url: url, sampleRate: 48_000, channels: 2, interleaved: true)
    try writer.append(buffer)
    writer.close()
    let file = try AVAudioFile(forReading: url)
    #expect(file.length == 480)
    #expect(try readChannel(file, 0)[1] == 0.25)
    #expect(try readChannel(file, 1)[1] == -0.25)
}

@Test func trackWriterPadsWithSilence() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try TrackWriter(url: url, sampleRate: 48_000, channels: 1)
    try writer.appendSilence(frames: 100_000)
    try writer.append(makeBuffer(sampleRate: 48_000, frames: 480) { _ in 0.5 })
    #expect(writer.framesWritten == 100_480)
    writer.close()
    let file = try AVAudioFile(forReading: url)
    #expect(file.length == 100_480)
    let samples = try readChannel(file)
    #expect(samples[99_999] == 0)
    #expect(samples[100_000] == 0.5)
}

@Test func systemInterruptionSurvivesMicRestart() {
    let session = RecordingSession(config: RecordingConfig(micURL: tempURL()))
    session.setInterruption(.deviceStopped(.system), for: .system)
    session.recoverMic {}
    #expect(session.interruptions == [.system: .deviceStopped(.system)])
    #expect(session.interruption == .deviceStopped(.system))

    struct Boom: Error {}
    session.recoverMic { throw Boom() }
    #expect(session.interruptions[.system] == .deviceStopped(.system))
    #expect(session.interruptions[.mic] != nil)
    #expect(session.interruption == .deviceStopped(.system))

    session.setInterruption(nil, for: .system)
    #expect(session.interruption?.track == .mic)
    session.recoverMic {}
    #expect(session.interruption == nil)
}

@Test func trackAheadOfTheClockDropsFramesFromTheBufferHead() throws {
    let clock = HostClock()
    clock.begin(at: ticks(100))
    let (stream, continuation) = AsyncStream<LiveAudioChunk>.makeStream()
    defer { withExtendedLifetime(stream) {} }
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let pipeline = makePipeline(clock: clock, writer: try TrackWriter(url: url, sampleRate: 16_000, channels: 1), stream: continuation)
    let short = makeBuffer(sampleRate: 16_000, frames: 1_600) { _ in 0.25 }
    for index in 0..<3 { pipeline.process(short, hostTime: ticks(100 + Double(index) * 0.1)) }
    #expect(pipeline.framesWritten == 4_800)

    // clock says 0.2 s (3 200 frames) but 4 800 are written: 1 600 frames ahead, dropped from the head
    let ramp = makeBuffer(sampleRate: 16_000, frames: 3_200) { Float($0) / 10_000 }
    pipeline.process(ramp, hostTime: ticks(100.2))
    #expect(pipeline.framesWritten == 4_800 + 1_600)
    pipeline.close()
    let samples = try readChannel(try AVAudioFile(forReading: url))
    #expect(samples.count == 6_400)
    #expect(abs(samples[4_800] - 0.16) < 0.0001)

    // a whole buffer that is entirely ahead is skipped
    let clock2 = HostClock()
    clock2.begin(at: ticks(100))
    let second = makePipeline(clock: clock2, stream: continuation)
    second.process(makeBuffer(sampleRate: 16_000, frames: 3_200) { _ in 0.1 }, hostTime: ticks(100))
    second.process(short, hostTime: ticks(100.05 + 0.0))
    #expect(second.framesWritten == 3_200)
}

@Test func stallWatchdogFlagsAndClears() {
    var watchdog = StallWatchdog(timeout: 3, now: 0)
    watchdog.noteCallback(at: 0)
    #expect(watchdog.check(now: 2, active: true) == nil)
    #expect(watchdog.check(now: 3, active: true) == .stalled)
    #expect(watchdog.check(now: 4, active: true) == nil)
    watchdog.noteCallback(at: 4.5)
    #expect(watchdog.check(now: 5, active: true) == .resumed)
    #expect(watchdog.check(now: 6, active: true) == nil)

    // paused time does not count
    #expect(watchdog.check(now: 20, active: false) == nil)
    #expect(watchdog.check(now: 21, active: true) == nil)
    #expect(watchdog.check(now: 23.5, active: true) == .stalled)
}

@Test func stallWatchdogStaysQuietBeforeTheFirstCallback() {
    var watchdog = StallWatchdog(timeout: 3, now: 0)
    #expect(watchdog.check(now: 10, active: true) == nil)
    #expect(watchdog.check(now: 100, active: true) == nil)
    watchdog.noteCallback(at: 100)
    #expect(watchdog.check(now: 102, active: true) == nil)
    #expect(watchdog.check(now: 103, active: true) == .stalled)
}

@Test func stallRecoveryNeedsARealCallback() {
    var watchdog = StallWatchdog(timeout: 3, now: 0)
    watchdog.noteCallback(at: 0)
    #expect(watchdog.check(now: 4, active: true) == .stalled)
    // pausing and resuming does not clear the stall
    #expect(watchdog.check(now: 10, active: false) == nil)
    #expect(watchdog.check(now: 11, active: true) == nil)
    watchdog.noteCallback(at: 11.5)
    #expect(watchdog.check(now: 12, active: true) == .resumed)
    #expect(watchdog.check(now: 13, active: true) == nil)
}

@Test func systemFaultsClearIndependently() {
    let session = RecordingSession(config: RecordingConfig(micURL: tempURL()))
    session.setSystemFault(.layoutMismatch, raised: true)
    session.setSystemFault(.stalled, raised: true)
    #expect(session.interruption == .deviceStopped(.system))
    // clearing the stall leaves the layout mismatch raised
    session.setSystemFault(.stalled, raised: false)
    #expect(session.interruption == .restartFailed(.system, "unexpected tap buffer layout"))
    session.setSystemFault(.layoutMismatch, raised: false)
    #expect(session.interruption == nil)

    // clearing the layout leaves the stall raised
    session.setSystemFault(.stalled, raised: true)
    session.setSystemFault(.layoutMismatch, raised: true)
    session.setSystemFault(.layoutMismatch, raised: false)
    #expect(session.interruption == .deviceStopped(.system))
    session.setSystemFault(.stalled, raised: false)
    #expect(session.interruption == nil)
}

@Test func releasingASessionOnAnotherQueueFinishesTheLiveStream() async {
    var stream: AsyncStream<LiveAudioChunk>?
    DispatchQueue(label: "test.release").sync {
        var session: RecordingSession? = RecordingSession(config: RecordingConfig(micURL: tempURL()))
        stream = session?.liveAudio
        session = nil
    }
    var count = 0
    for await _ in stream! { count += 1 }
    #expect(count == 0)
}

private struct DiskFull: LocalizedError {
    var errorDescription: String? { "No space left on device" }
}

@Test func writerFailureIsReportedAndStopsWriting() throws {
    let clock = HostClock()
    clock.begin(at: ticks(100))
    let (stream, continuation) = AsyncStream<LiveAudioChunk>.makeStream()
    defer { withExtendedLifetime(stream) {} }
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    var failures: [Track] = []
    let pipeline = TrackPipeline(
        track: .system, writer: try TrackWriter(url: url, sampleRate: 16_000, channels: 1), sampleRate: 16_000,
        monoMode: .channelZero, clock: clock, continuation: continuation, onFailure: { track, _ in failures.append(track) }
    )
    let wrong = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
    let broken = AVAudioPCMBuffer(pcmFormat: wrong, frameCapacity: 1_600)!
    broken.frameLength = 1_600
    pipeline.process(broken, hostTime: ticks(100))
    pipeline.process(makeBuffer(sampleRate: 16_000, frames: 1_600) { _ in 0.5 }, hostTime: ticks(100.1))
    #expect(failures == [.system])
}

@Test func writeFailureSurfacesAsAnInterruption() {
    let session = RecordingSession(config: RecordingConfig(micURL: tempURL()))
    session.noteWriteFailure(.mic, DiskFull())
    #expect(session.interruptions[.mic] == .writeFailed(.mic, "No space left on device"))
    #expect(session.interruption == .writeFailed(.mic, "No space left on device"))
    #expect(session.interruption?.track == .mic)

    // a device fault on the call track doesn't hide it, and recovering the mic doesn't clear it
    session.setSystemFault(.stalled, raised: true)
    #expect(session.interruption == .writeFailed(.mic, "No space left on device"))
    session.recoverMic {}
    #expect(session.interruptions[.mic] == .writeFailed(.mic, "No space left on device"))
    #expect(session.interruptions[.system] == .deviceStopped(.system))
    #expect(session.writeErrors.keys.contains(.mic))
}

@Test func activeIntervalsExcludePausesAndTheEnd() {
    let clock = HostClock()
    clock.begin(at: ticks(100))
    clock.pause(at: ticks(101))
    clock.resume(at: ticks(102))
    clock.pause(at: ticks(103))
    func interval(_ from: Double, _ to: Double) -> HostClock.Interval { .init(from: ticks(from), to: ticks(to)) }

    #expect(clock.activeIntervals(from: ticks(100), to: ticks(100.5)) == [interval(100, 100.5)])
    #expect(clock.activeIntervals(from: ticks(100.5), to: ticks(101.5)) == [interval(100.5, 101)])
    #expect(clock.activeIntervals(from: ticks(101.2), to: ticks(101.8)).isEmpty)
    #expect(clock.activeIntervals(from: ticks(100.5), to: ticks(102.5)) == [interval(100.5, 101), interval(102, 102.5)])
    #expect(clock.activeIntervals(from: ticks(102.5), to: ticks(104)) == [interval(102.5, 103)])
    clock.resume(at: ticks(104))
    clock.finish(at: ticks(105))
    #expect(clock.activeIntervals(from: ticks(104.5), to: ticks(106)) == [interval(104.5, 105)])
    #expect(clock.activeIntervals(from: ticks(105.5), to: ticks(106)).isEmpty)
}

private func drain(
    _ stream: AsyncStream<LiveAudioChunk>, _ continuation: AsyncStream<LiveAudioChunk>.Continuation, from pipeline: TrackPipeline
) async -> [Float] {
    pipeline.close()
    continuation.finish()
    var samples: [Float] = []
    for await chunk in stream { samples += chunk.samples }
    return samples
}

@Test func bufferStartingBeforeAPauseKeepsOnlyTheFramesBeforeIt() throws {
    let clock = HostClock()
    clock.begin(at: ticks(100))
    clock.pause(at: ticks(100.5))
    let (stream, continuation) = AsyncStream<LiveAudioChunk>.makeStream()
    defer { withExtendedLifetime(stream) {} }
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let pipeline = makePipeline(clock: clock, writer: try TrackWriter(url: url, sampleRate: 16_000, channels: 1), stream: continuation)

    pipeline.process(makeBuffer(sampleRate: 16_000, frames: 16_000) { Float($0) / 20_000 }, hostTime: ticks(100))
    #expect(pipeline.framesWritten == 8_000)
    // a buffer that lies wholly inside the pause adds nothing
    pipeline.process(makeBuffer(sampleRate: 16_000, frames: 1_600) { _ in 0.9 }, hostTime: ticks(101))
    #expect(pipeline.framesWritten == 8_000)
    pipeline.close()
    let samples = try readChannel(try AVAudioFile(forReading: url))
    #expect(samples.count == 8_000)
    #expect(abs(samples[7_999] - 7_999.0 / 20_000) < 0.001)
}

@Test func bufferSpanningAResumeKeepsTheFramesAfterIt() throws {
    let clock = HostClock()
    clock.begin(at: ticks(100))
    clock.pause(at: ticks(100.5))
    clock.resume(at: ticks(101))
    let (stream, continuation) = AsyncStream<LiveAudioChunk>.makeStream()
    defer { withExtendedLifetime(stream) {} }
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let pipeline = makePipeline(clock: clock, writer: try TrackWriter(url: url, sampleRate: 16_000, channels: 1), stream: continuation)

    // starts at 100.7, 0.3 s into the pause; the buffer's last 0.3 s is after the resume, at 0.5 s on the recording clock
    pipeline.process(makeBuffer(sampleRate: 16_000, frames: 9_600) { Float($0) / 20_000 }, hostTime: ticks(100.7))
    #expect(pipeline.framesWritten == 8_000 + 4_800)
    pipeline.close()
    let samples = try readChannel(try AVAudioFile(forReading: url))
    #expect(samples.count == 12_800)
    #expect(samples[7_999] == 0)
    #expect(abs(samples[8_000] - 4_800.0 / 20_000) < 0.001)
}

@Test func pauseInsideABufferKeepsPositionFileAndLiveSamplesInAgreement() async throws {
    let clock = HostClock()
    clock.begin(at: ticks(100))
    clock.pause(at: ticks(100.5))
    clock.resume(at: ticks(101))
    let (stream, continuation) = AsyncStream<LiveAudioChunk>.makeStream()
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let pipeline = makePipeline(clock: clock, writer: try TrackWriter(url: url, sampleRate: 16_000, channels: 1), stream: continuation)

    pipeline.process(makeBuffer(sampleRate: 16_000, frames: 32_000) { Float($0) / 40_000 }, hostTime: ticks(100))
    #expect(pipeline.framesWritten == 8_000 + 16_000)
    let live = await drain(stream, continuation, from: pipeline)
    #expect(live.count == pipeline.framesWritten)
    let samples = try readChannel(try AVAudioFile(forReading: url))
    #expect(samples.count == pipeline.framesWritten)
    // the frame after the pause is the one from 1.0 s into the buffer
    #expect(abs(samples[8_000] - 16_000.0 / 40_000) < 0.001)
    #expect(abs(live[8_000] - 16_000.0 / 40_000) < 0.001)
}

@Test func bufferRunningPastTheEndIsTrimmedToIt() throws {
    let clock = HostClock()
    clock.begin(at: ticks(100))
    clock.finish(at: ticks(100.5))
    let (stream, continuation) = AsyncStream<LiveAudioChunk>.makeStream()
    defer { withExtendedLifetime(stream) {} }
    let pipeline = makePipeline(clock: clock, stream: continuation)
    pipeline.process(makeBuffer(sampleRate: 16_000, frames: 16_000) { _ in 0.5 }, hostTime: ticks(100))
    #expect(pipeline.framesWritten == 8_000)
}
