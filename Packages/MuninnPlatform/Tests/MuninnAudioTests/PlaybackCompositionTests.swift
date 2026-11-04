import AVFoundation
import MuninnCore
import Testing
@testable import MuninnAudio

private func makeURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("playback-\(name)-\(UUID().uuidString).caf")
}

private func writeSine(sampleRate: Double, channels: Int, seconds: Double, interleaved: Bool = false) throws -> URL {
    let url = makeURL("sine")
    let writer = try TrackWriter(url: url, sampleRate: sampleRate, channels: channels, interleaved: interleaved)
    let frames = Int(sampleRate * seconds)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for channel in 0..<channels {
        for frame in 0..<frames {
            buffer.floatChannelData![channel][frame] = 0.5 * sin(Float(frame) * 2 * .pi * 440 / Float(sampleRate))
        }
    }
    try writer.append(buffer)
    writer.close()
    return url
}

private func writeMic(seconds: Double = 2.0) throws -> URL {
    try writeSine(sampleRate: 16_000, channels: 1, seconds: seconds)
}

private func writeSystem(seconds: Double = 1.0) throws -> URL {
    try writeSine(sampleRate: 48_000, channels: 2, seconds: seconds, interleaved: true)
}

private func writeEmpty() throws -> URL {
    let url = makeURL("empty")
    let writer = try TrackWriter(url: url, sampleRate: 16_000, channels: 1)
    writer.close()
    return url
}

private func writeGarbage() throws -> URL {
    let url = makeURL("garbage")
    try Data((0..<4_096).map { _ in UInt8.random(in: 0...255) }).write(to: url)
    return url
}

private func remove(_ urls: URL?...) {
    for url in urls.compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
}

private func volume(of track: Track, in playback: PlaybackComposition, mix: PlaybackMix) throws -> Float? {
    let trackID = try #require(playback.trackIDs[track])
    let match = playback.audioMix(mix).inputParameters.first { $0.trackID == trackID }
    var start: Float = -1
    var end: Float = -1
    var range = CMTimeRange.invalid
    guard let match, match.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range) else { return nil }
    return start
}

@Test func bothTracksStartAtZero() async throws {
    let mic = try writeMic()
    let system = try writeSystem()
    defer { remove(mic, system) }

    let playback = try #require(try await PlaybackComposition.load(mic: mic, system: system))
    #expect(playback.tracks == [.mic, .system])
    #expect(playback.skipped.isEmpty)
    let compositionTracks = playback.composition.tracks(withMediaType: .audio)
    #expect(compositionTracks.count == 2)
    for track in compositionTracks {
        let segment = try #require(track.segments.first)
        #expect(segment.timeMapping.target.start == .zero)
    }
}

@Test func shorterTrackDoesNotShortenPlayback() async throws {
    let mic = try writeMic()
    let system = try writeSystem()
    defer { remove(mic, system) }

    let playback = try #require(try await PlaybackComposition.load(mic: mic, system: system))
    #expect(abs(playback.duration - 2.0) < 0.01)
}

@Test func micOnlyMeetingPlaysOneTrack() async throws {
    let mic = try writeMic()
    defer { remove(mic) }

    let playback = try #require(try await PlaybackComposition.load(mic: mic, system: nil))
    #expect(playback.tracks == [.mic])
    #expect(playback.composition.tracks(withMediaType: .audio).count == 1)
}

@Test func missingFilesMeanNoRecording() async throws {
    let playback = try await PlaybackComposition.load(mic: makeURL("absent"), system: makeURL("absent"))
    #expect(playback == nil)
}

@Test func emptyFileCountsAsMissing() async throws {
    let mic = try writeEmpty()
    let system = try writeSystem()
    defer { remove(mic, system) }

    let playback = try #require(try await PlaybackComposition.load(mic: mic, system: system))
    #expect(playback.tracks == [.system])
    #expect(playback.skipped.isEmpty)
}

@Test func unreadableFileIsSkipped() async throws {
    let mic = try writeGarbage()
    let system = try writeSystem()
    defer { remove(mic, system) }

    let playback = try #require(try await PlaybackComposition.load(mic: mic, system: system))
    #expect(playback.tracks == [.system])
    #expect(playback.skipped == [.mic])
}

@Test func allUnreadableThrows() async throws {
    let mic = try writeGarbage()
    let system = try writeGarbage()
    defer { remove(mic, system) }

    await #expect(throws: (any Error).self) {
        _ = try await PlaybackComposition.load(mic: mic, system: system)
    }
}

@Test func unchangedFilesGiveEqualPlaybackFiles() throws {
    let mic = try writeMic()
    let system = try writeSystem()
    defer { remove(mic, system) }

    #expect(PlaybackFiles(mic: mic, system: system) == PlaybackFiles(mic: mic, system: system))
    #expect(PlaybackFiles(mic: nil, system: makeURL("absent")) == PlaybackFiles(mic: nil, system: nil))
}

@Test func restoredTrackFileChangesPlaybackFiles() throws {
    let mic = try writeMic()
    let restored = makeURL("restored")
    defer { remove(mic, restored) }

    let before = PlaybackFiles(mic: mic, system: restored)
    try FileManager.default.moveItem(at: try writeSystem(), to: restored)
    #expect(PlaybackFiles(mic: mic, system: restored) != before)
}

@Test func replacedTrackFileChangesPlaybackFiles() throws {
    let mic = try writeMic(seconds: 2.0)
    defer { remove(mic) }

    let before = PlaybackFiles(mic: mic, system: nil)
    let longer = try writeMic(seconds: 3.0)
    _ = try FileManager.default.replaceItemAt(mic, withItemAt: longer)
    #expect(PlaybackFiles(mic: mic, system: nil) != before)
}

@Test func mixSilencesTheOtherTrack() async throws {
    let mic = try writeMic()
    let system = try writeSystem()
    defer { remove(mic, system) }

    let playback = try #require(try await PlaybackComposition.load(mic: mic, system: system))
    #expect(try volume(of: .mic, in: playback, mix: .callOnly) == 0)
    #expect(try volume(of: .system, in: playback, mix: .callOnly) == 1)
    #expect(try volume(of: .mic, in: playback, mix: .meOnly) == 1)
    #expect(try volume(of: .system, in: playback, mix: .meOnly) == 0)
}
