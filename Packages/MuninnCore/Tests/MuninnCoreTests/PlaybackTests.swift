import Foundation
import Testing
@testable import MuninnCore

struct PlaybackTests {
    private func segment(_ id: Int, _ track: Track, _ speaker: String, _ start: TimeInterval, _ end: TimeInterval) -> Segment {
        Segment(id: id, track: track, speaker: speaker, start: start, end: end, text: "", words: [])
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("muninn-playback-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("playback.json")
    }

    @Test func lanesMergeASpeakersCloseSpans() {
        let transcript = Transcript(segments: [
            segment(0, .system, "S1", 3, 8),
            segment(1, .mic, "you", 0, 4),
            segment(2, .system, "S2", 10, 14),
            segment(3, .system, "S1", 8.3, 9),
        ], language: nil)
        #expect(PlaybackLanes.lanes(for: transcript) == [
            PlaybackLane(track: .mic, spans: [LaneSpan(start: 0, end: 4, speaker: "you")]),
            PlaybackLane(track: .system, spans: [
                LaneSpan(start: 3, end: 9, speaker: "S1"),
                LaneSpan(start: 10, end: 14, speaker: "S2"),
            ]),
        ])
    }

    @Test func micOnlyMeetingHasOneLane() {
        let transcript = Transcript(segments: [segment(0, .mic, "you", 0, 4)], language: nil)
        #expect(PlaybackLanes.lanes(for: transcript).map(\.track) == [.mic])
        #expect(PlaybackLanes.lanes(for: Transcript(segments: [], language: nil)).isEmpty)
    }

    @Test func mixVolumes() {
        #expect(PlaybackMix.both.volume(for: .mic) == 1 && PlaybackMix.both.volume(for: .system) == 1)
        #expect(PlaybackMix.callOnly.volume(for: .mic) == 0 && PlaybackMix.callOnly.volume(for: .system) == 1)
        #expect(PlaybackMix.meOnly.volume(for: .mic) == 1 && PlaybackMix.meOnly.volume(for: .system) == 0)
        #expect(PlaybackMix.allCases.map(\.label) == ["Both", "Call only", "Me only"])
    }

    @Test func speedLabels() {
        #expect(Playback.speeds.map(Playback.speedLabel) == ["1×", "1.25×", "1.5×", "2×"])
    }

    @Test func skipClamps() {
        #expect(Playback.skip(from: 5, by: -15, duration: 100) == 0)
        #expect(Playback.skip(from: 95, by: 15, duration: 100) == 100)
        #expect(Playback.skip(from: 50, by: Playback.skipInterval, duration: 100) == 65)
    }

    @Test func positionsPersistAcrossInstances() {
        let file = temporaryFile()
        PlaybackPositions(file: file).set(42, for: MeetingID(rawValue: "a"))
        #expect(PlaybackPositions(file: file).position(for: MeetingID(rawValue: "a")) == 42)
        #expect(PlaybackPositions(file: file).position(for: MeetingID(rawValue: "b")) == nil)
    }

    @Test func removeForgetsAPosition() {
        let file = temporaryFile()
        let positions = PlaybackPositions(file: file)
        positions.set(10, for: MeetingID(rawValue: "a"))
        positions.set(20, for: MeetingID(rawValue: "b"))
        positions.remove(MeetingID(rawValue: "a"))
        #expect(positions.position(for: MeetingID(rawValue: "a")) == nil)
        let reread = PlaybackPositions(file: file)
        #expect(reread.position(for: MeetingID(rawValue: "a")) == nil)
        #expect(reread.position(for: MeetingID(rawValue: "b")) == 20)
    }

    @Test func damagedFileReadsEmpty() throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: file)
        let positions = PlaybackPositions(file: file)
        #expect(positions.position(for: MeetingID(rawValue: "a")) == nil)
        positions.set(5, for: MeetingID(rawValue: "a"))
        #expect(PlaybackPositions(file: file).position(for: MeetingID(rawValue: "a")) == 5)
    }

    @Test func resumeRule() {
        #expect(PlaybackPositions.resumeTime(stored: 50, duration: 100) == 50)
        #expect(PlaybackPositions.resumeTime(stored: 99, duration: 100) == 0)
        #expect(PlaybackPositions.resumeTime(stored: 120, duration: 100) == 0)
        #expect(PlaybackPositions.resumeTime(stored: -4, duration: 100) == 0)
        #expect(PlaybackPositions.resumeTime(stored: nil, duration: 100) == 0)
    }

    @Test func playbackFileIsInTheStateDirectory() {
        let home = URL(fileURLWithPath: "/Users/test")
        #expect(MuninnPaths(home: home, environment: ["XDG_STATE_HOME": "/s"]).playbackFile.path == "/s/muninn/playback.json")
        #expect(MuninnPaths(home: home, environment: [:]).playbackFile.path == "/Users/test/.local/state/muninn/playback.json")
    }
}
