import Foundation
import Testing
@testable import MuninnCore

struct ActivityTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("muninn-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func log(in folder: URL, now: Date = ActivityTests.now) -> ActivityLog {
        ActivityLog(file: folder.appendingPathComponent("state/activity.jsonl"), clock: { now })
    }

    private func entry(_ message: String, at time: Date = ActivityTests.now, details: ProblemDetails? = nil) -> ActivityEntry {
        ActivityEntry(time: time, level: .info, area: .app, message: message, details: details)
    }

    private func size(of file: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int) ?? 0
    }

    // MARK: Paths

    @Test func pathsFollowXDGState() {
        let home = URL(fileURLWithPath: "/Users/test")
        let custom = MuninnPaths(home: home, environment: ["XDG_STATE_HOME": "/s"])
        #expect(custom.state.path == "/s/muninn")
        #expect(custom.activityFile.path == "/s/muninn/activity.jsonl")
        let plain = MuninnPaths(home: home, environment: [:])
        #expect(plain.activityFile.path == "/Users/test/.local/state/muninn/activity.jsonl")
        let relative = MuninnPaths(home: home, environment: ["XDG_STATE_HOME": "relative"])
        #expect(relative.activityFile.path == "/Users/test/.local/state/muninn/activity.jsonl")
    }

    // MARK: Log

    @Test func recordAppendsAndListsNewestFirst() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = log(in: folder)
        for (index, name) in ["first", "second", "third"].enumerated() {
            log.record(entry(name, at: Self.now.addingTimeInterval(Double(index))))
        }
        #expect(log.entries().map(\.message) == ["third", "second", "first"])
    }

    @Test func entriesRoundTripThroughTheFile() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = log(in: folder)
        let original = ActivityEntry(
            time: Self.now.addingTimeInterval(0.25), level: .warning, area: .recap,
            meeting: ActivityMeeting(id: MeetingID(rawValue: "m1"), title: "Sync"), message: "Hello",
            details: ProblemDetails(httpStatus: 503, engine: .claude)
        )
        log.record(original)
        #expect(log.entries() == [original])
    }

    @Test func pruneDropsEntriesOlderThan14Days() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = log(in: folder)
        log.record(entry("old", at: Self.now.addingTimeInterval(-15 * 24 * 3600)))
        log.record(entry("recent", at: Self.now.addingTimeInterval(-13 * 24 * 3600)))
        log.prune()
        #expect(log.entries().map(\.message) == ["recent"])
    }

    @Test func fileStaysUnderTheCap() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = log(in: folder)
        let filler = String(repeating: "x ", count: 500)
        var newest = ""
        var oldest = ""
        for index in 0..<6000 {
            let message = "entry \(index) " + filler
            if index == 0 { oldest = message }
            newest = message
            log.record(entry(message, at: Self.now.addingTimeInterval(Double(index))))
        }
        #expect(size(of: log.file) <= ActivityLog.maxBytes)
        #expect(log.entries().first?.message == newest)
        #expect(!log.entries().contains { $0.message == oldest })
    }

    @Test func unreadableLinesAreSkipped() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = log(in: folder)
        log.record(entry("valid"))
        let handle = try FileHandle(forWritingTo: log.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("garbage\n{partial".utf8))
        try handle.close()
        #expect(log.entries().map(\.message) == ["valid"])
    }

    @Test func recordAfterATornLineStillReadsBack() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = log(in: folder)
        try FileManager.default.createDirectory(at: log.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{partial".utf8).write(to: log.file)
        log.record(entry("after"))
        #expect(log.entries().map(\.message) == ["after"])
    }

    @Test func recordRedactsBeforeWriting() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = log(in: folder)
        let details = ProblemDetails(request: RequestFacts(method: "GET", path: "/sk-ant-api03-PATHSECRET/api"))
        log.record(entry("key sk-ant-api03-SECRETSECRET leaked", details: details))
        let text = try String(contentsOf: log.file, encoding: .utf8)
        #expect(!text.contains("SECRETSECRET"))
        #expect(!text.contains("PATHSECRET"))
        #expect(text.contains(Redaction.marker))
    }

    @Test func observerSeesRecordedEntries() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = log(in: folder)
        let seen = LockedBox<[String]>([])
        log.setObserver { entry in seen.update { $0.append(entry.message) } }
        log.record(entry("key sk-ant-api03-SECRETSECRET"))
        #expect(seen.get() == ["key \(Redaction.marker)"])
        log.setObserver(nil)
        log.record(entry("unseen"))
        #expect(seen.get().count == 1)
    }

    @Test func entriesOfAMissingFileAreEmpty() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(log(in: folder).entries().isEmpty)
    }

    // MARK: Duration text

    @Test func durationText() {
        #expect(DurationText.short(12) == "12 s")
        #expect(DurationText.short(190) == "3 min 10 s")
        #expect(DurationText.short(2520) == "42 min")
        #expect(DurationText.short(3900) == "1 h 5 min")
    }

    // MARK: Meeting transitions

    private func meeting(_ status: ProcessingStatus, engineNotice: Problem? = nil, transcriptNotice: Problem? = nil) -> Meeting {
        Meeting(
            id: MeetingID(rawValue: "m1"), title: "Sync", startedAt: Self.now, endedAt: Self.now.addingTimeInterval(42 * 60),
            captureMode: .micOnly, language: "en", accountID: nil, association: nil, client: nil, candidateEvents: [],
            attendees: [], recipients: [], flags: [], speakerNames: [:], status: status, summaryEngine: nil,
            engineNotice: engineNotice, exportedNotePath: nil, metrics: ProcessingMetrics(),
            transcriptNotice: transcriptNotice
        )
    }

    private func entries(from old: Meeting?, to new: Meeting) -> [ActivityEntry] {
        MeetingActivity.entries(from: old, to: new, settings: .defaults, time: Self.now)
    }

    @Test func noEntriesWithoutAnEarlierState() {
        #expect(entries(from: nil, to: meeting(.failed(Problems.claudeBusy()))).isEmpty)
    }

    @Test func failureBecomesAProblemEntry() throws {
        let problem = Problems.claudeBusy(details: ProblemDetails(stage: .writingRecap))
        let result = entries(from: meeting(.summarizing), to: meeting(.failed(problem)))
        let entry = try #require(result.first)
        #expect(result.count == 1)
        #expect(entry.level == .problem)
        #expect(entry.area == .recap)
        #expect(entry.message == "Claude is busy right now")
        #expect(entry.meeting == ActivityMeeting(id: MeetingID(rawValue: "m1"), title: "Sync"))
        #expect(entry.time == Self.now)
    }

    @Test func failureWithoutAStageIsAnAppEntry() throws {
        let result = entries(from: meeting(.summarizing), to: meeting(.failed(Problems.claudeBusy())))
        #expect(result.first?.area == .app)
    }

    @Test func enteringAWaitIsRecordedOnce() throws {
        let waiting = meeting(.waiting(.thisMacUnreachable))
        let entered = entries(from: meeting(.summarizing), to: waiting)
        #expect(entered.count == 1)
        #expect(entered.first?.level == .warning)
        #expect(entered.first?.area == .engines)
        #expect(entered.first?.message == "Ollama isn't running on This Mac")
        #expect(entries(from: waiting, to: waiting).isEmpty)
        #expect(entries(from: waiting, to: meeting(.waiting(.queued))).isEmpty)
        #expect(entries(from: meeting(.summarizing), to: meeting(.waiting(.queued))).isEmpty)
    }

    @Test func waitingForARecordingIsARecordingEntry() {
        let result = entries(from: meeting(.transcribing), to: meeting(.waiting(.recording)))
        #expect(result.first?.area == .recording)
    }

    @Test func recapWrittenNamesEngineModelAndTime() throws {
        var done = meeting(.ready)
        done.summaryEngine = .claude
        done.metrics.summarizeSeconds = 42
        let result = entries(from: meeting(.summarizing), to: done)
        #expect(result.count == 1)
        #expect(result.first?.level == .info)
        #expect(result.first?.area == .recap)
        #expect(result.first?.message == "Recap written by Claude · claude-opus-5-5 · 42 s")
    }

    @Test func failedRegenerationRecordsOnlyTheProblem() {
        var kept = meeting(.ready, engineNotice: Problems.regenerationFailed(Problems.claudeBusy()))
        kept.summaryEngine = .claude
        kept.metrics.summarizeSeconds = 42
        let result = entries(from: meeting(.summarizing), to: kept)
        #expect(result.count == 1)
        #expect(result.first?.level == .problem)
        #expect(result.first?.area == .recap)
    }

    @Test func recapWrittenOnAnEndpointNamesItsModel() {
        var done = meeting(.ready)
        done.summaryEngine = .macbook
        done.metrics.summarizeSeconds = 5
        let result = entries(from: meeting(.summarizing), to: done)
        #expect(result.first?.message == "Recap written by This Mac · \(Settings.defaults.macbook.model) · 5 s")
    }

    @Test func transcriptionDoneNamesTheDuration() {
        var diarizing = meeting(.diarizing)
        diarizing.metrics.transcribeSeconds = 190
        let result = entries(from: meeting(.transcribing), to: diarizing)
        #expect(result.count == 1)
        #expect(result.first?.area == .transcription)
        #expect(result.first?.message == "Transcribed 42 min of audio in 3 min 10 s")
    }

    @Test func transcriptionWithoutTimingsIsNotRecorded() {
        #expect(entries(from: meeting(.transcribing), to: meeting(.diarizing)).isEmpty)
    }

    @Test func newNoticesAreRecorded() throws {
        let kept = Problems.keptRecap(.studioUnreachable, api: .ollama)
        let withNotice = meeting(.ready, engineNotice: kept)
        let result = entries(from: meeting(.ready), to: withNotice)
        #expect(result.count == 1)
        #expect(result.first?.level == .problem)
        #expect(result.first?.area == .recap)
        #expect(result.first?.message == kept.title)
        #expect(entries(from: withNotice, to: withNotice).isEmpty)

        let degraded = Problems.diarisationDegraded(mode: .micOnly)
        let transcript = entries(from: meeting(.ready), to: meeting(.ready, transcriptNotice: degraded))
        #expect(transcript.count == 1)
        #expect(transcript.first?.area == .transcription)
        #expect(transcript.first?.message == degraded.title)
    }
}

final class RecordingActivity: ActivityRecording, @unchecked Sendable {
    private let box = LockedBox<[ActivityEntry]>([])

    var entries: [ActivityEntry] { box.get() }

    func record(_ entry: ActivityEntry) {
        box.update { $0.append(entry) }
    }
}
