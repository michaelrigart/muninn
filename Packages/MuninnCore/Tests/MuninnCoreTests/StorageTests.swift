import Foundation
import Testing
@testable import MuninnCore

struct StorageTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("muninn-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func meeting(_ id: String, title: String = "Acme sync", startedAt: Date = Date(timeIntervalSince1970: 1_792_000_000)) -> Meeting {
        Meeting(
            id: MeetingID(rawValue: id), title: title, startedAt: startedAt, endedAt: nil,
            captureMode: .call(appBundleID: "us.zoom.xos"), language: "en", accountID: "work",
            association: nil, client: "Acme", candidateEvents: [], attendees: [Attendee(name: "Ada", email: "ada@acme.test")],
            recipients: [], flags: [Flag(offset: 5)], speakerNames: ["S1": "Ada"], status: .ready,
            summaryEngine: .macbook, engineNotice: nil, exportedNotePath: nil, draftWebLink: nil,
            metrics: ProcessingMetrics()
        )
    }

    @Test func xdgOverrides() {
        let paths = MuninnPaths(
            home: URL(fileURLWithPath: "/Users/test"),
            environment: ["XDG_DATA_HOME": "/x", "XDG_CONFIG_HOME": "/y", "XDG_CACHE_HOME": "/z"]
        )
        #expect(paths.data.path == "/x/muninn")
        #expect(paths.config.path == "/y/muninn")
        #expect(paths.cache.path == "/z/muninn")
        #expect(paths.meetings.path == "/x/muninn/meetings")
        #expect(paths.settingsFile.path == "/y/muninn/settings.json")
    }

    @Test func relativeOverrideIgnored() {
        let paths = MuninnPaths(home: URL(fileURLWithPath: "/Users/test"), environment: ["XDG_DATA_HOME": "relative"])
        #expect(paths.data.path == "/Users/test/.local/share/muninn")
    }

    @Test func defaultsUnderHome() {
        let paths = MuninnPaths(home: URL(fileURLWithPath: "/Users/test"), environment: [:])
        #expect(paths.data.path == "/Users/test/.local/share/muninn")
        #expect(paths.config.path == "/Users/test/.config/muninn")
        #expect(paths.cache.path == "/Users/test/.cache/muninn")
        #expect(paths.meetings.path == "/Users/test/.local/share/muninn/meetings")
        #expect(paths.settingsFile.path == "/Users/test/.config/muninn/settings.json")
    }

    @Test func meetingRoundTripOnDisk() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let original = meeting("2026-10-22-1400-acme")
        try store.create(original)
        #expect(FileManager.default.fileExists(atPath: store.directory(original.id).appendingPathComponent("audio").path))
        #expect(try store.load(original.id) == original)

        var changed = original
        changed.title = "Renamed"
        try store.save(changed)
        #expect(try store.load(original.id).title == "Renamed")
        #expect(store.audioURL(original.id, track: .mic).path.hasSuffix("2026-10-22-1400-acme/audio/mic.caf"))
        #expect(store.audioURL(original.id, track: .system).lastPathComponent == "system.caf")
    }

    @Test func transcriptMarkdownURLsMatchWhatIsWritten() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("md")
        try store.create(m)
        let transcript = Transcript(segments: [
            Segment(id: 0, track: .mic, speaker: "S1", start: 1, end: 2, text: "hello", words: [])
        ], language: "en")
        try store.saveTranscript(transcript, for: m.id, speakerNames: [:])
        #expect(FileManager.default.fileExists(atPath: store.transcriptMarkdownURL(m.id).path))
        #expect(store.transcriptMarkdownURL(m.id).lastPathComponent == "transcript.md")
        #expect(store.cleanTranscriptMarkdownURL(m.id).lastPathComponent == "transcript.clean.md")
    }

    @Test func deleteRemovesTheMeetingFolder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        try store.create(meeting("keep"))
        try store.create(meeting("drop"))
        try Data("x".utf8).write(to: store.audioURL(MeetingID(rawValue: "drop"), track: .mic))

        try store.delete(MeetingID(rawValue: "drop"))

        #expect(!FileManager.default.fileExists(atPath: store.directory(MeetingID(rawValue: "drop")).path))
        #expect(try store.list().map(\.id.rawValue) == ["keep"])
        try store.delete(MeetingID(rawValue: "drop"))
    }

    @Test func listNewestFirst() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        try store.create(meeting("old", startedAt: Date(timeIntervalSince1970: 1_000)))
        try store.create(meeting("new", startedAt: Date(timeIntervalSince1970: 3_000)))
        try store.create(meeting("mid", startedAt: Date(timeIntervalSince1970: 2_000)))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("broken"), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: root.appendingPathComponent("broken/meeting.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)

        #expect(try store.list().map(\.id.rawValue) == ["new", "mid", "old"])
    }

    @Test func listOnMissingRootIsEmpty() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try MeetingStore(root: root.appendingPathComponent("nothing")).list().isEmpty)
    }

    @Test func transcriptCleanAndSummaryPersist() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("m1")
        try store.create(m)
        let id = m.id
        #expect(try store.loadTranscript(id) == nil)
        #expect(try store.loadClean(id) == nil)
        #expect(try store.loadSummary(id) == nil)

        let transcript = Transcript(segments: [
            Segment(id: 0, track: .mic, speaker: "you", start: 3, end: 5, text: "um hello", words: []),
            Segment(id: 1, track: .system, speaker: "S1", start: 3725, end: 3730, text: "hi there", words: []),
        ], language: "en")
        try store.saveTranscript(transcript, for: id, speakerNames: ["S1": "Ada"])
        #expect(try store.loadTranscript(id) == transcript)
        let md = try String(contentsOf: store.directory(id).appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(md.contains("**[00:03] Me:** um hello"))
        #expect(md.contains("**[1:02:05] Ada:** hi there"))

        let clean = CleanTranscript(segments: [CleanSegment(id: 0, text: "Hello."), CleanSegment(id: 1, text: "Hi there.")])
        try store.saveClean(clean, transcript: transcript, for: id, speakerNames: ["S1": "Ada"])
        #expect(try store.loadClean(id) == clean)
        let cleanMD = try String(contentsOf: store.directory(id).appendingPathComponent("transcript.clean.md"), encoding: .utf8)
        #expect(cleanMD.contains("**[00:03] Me:** Hello."))

        let summary = Summary(language: "en", subjects: [
            Subject(title: "Pricing", bullets: [Bullet(text: "Agreed on a discount", sources: [1])],
                    actions: [ActionPoint(owner: "Ada", text: "Send quote", due: "2026-11-01", sources: [1]),
                              ActionPoint(owner: "You", text: "Review", due: nil, sources: [0])]),
        ], engine: .macbook, generatedAt: Date(timeIntervalSince1970: 1_792_000_000))
        try store.saveSummary(summary, for: id)
        #expect(try store.loadSummary(id) == summary)
        let summaryMD = try String(contentsOf: store.directory(id).appendingPathComponent("summary.md"), encoding: .utf8)
        #expect(summaryMD.contains("## Pricing"))
        #expect(summaryMD.contains("- Agreed on a discount"))
        #expect(summaryMD.contains("- [ ] Ada: Send quote (due 2026-11-01)"))
        #expect(summaryMD.contains("- [ ] You: Review\n"))
    }

    @Test func transcriptMarkdownLine() {
        let markdown = TranscriptMarkdown.render(
            segments: [(id: 0, start: 62, speaker: "Jan", text: "Hello"), (id: 1, start: 3600, speaker: "Ada", text: "Hi")],
            title: "Sync"
        )
        #expect(markdown == "# Sync\n\n**[01:02] Jan:** Hello\n\n**[1:00:00] Ada:** Hi\n")
    }

    @Test func settingsMissingFileGivesDefaults() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        #expect(SettingsStore(file: file).load() == Settings.defaults)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func editedFlagRoundTripsAndDefaultsToFalse() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let id = MeetingID(rawValue: "m")
        try FileManager.default.createDirectory(at: store.directory(id), withIntermediateDirectories: true)
        let summary = Summary(language: "en", subjects: [], engine: .macbook, generatedAt: Date(timeIntervalSince1970: 0))
        try store.saveSummary(summary, for: id)
        #expect(try store.loadSummary(id)?.edited == false)
        try store.saveEditedSummary(summary, for: id)
        #expect(try store.loadSummary(id)?.edited == true)

        let legacy = #"{"language":"nl","subjects":[],"engine":"studio","generatedAt":"1970-01-01T00:00:00Z"}"#
        try Data(legacy.utf8).write(to: store.directory(id).appendingPathComponent("summary.json"))
        #expect(try store.loadSummary(id)?.edited == false)
    }

    @Test func restoreWithoutAPreviousSummaryFails() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let id = MeetingID(rawValue: "m")
        try FileManager.default.createDirectory(at: store.directory(id), withIntermediateDirectories: true)
        #expect(throws: MeetingStoreError.noPreviousSummary) { try store.restorePreviousSummary(id) }
    }

    private func titled(_ title: String, edited: Bool = false) -> Summary {
        Summary(
            language: "en",
            subjects: [Subject(title: title, bullets: [], actions: [])],
            engine: .macbook, generatedAt: Date(timeIntervalSince1970: 0), edited: edited
        )
    }

    @Test func editedPreviousSummaryIsNotReplacedByAnUneditedOne() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let id = MeetingID(rawValue: "m")
        try FileManager.default.createDirectory(at: store.directory(id), withIntermediateDirectories: true)
        try store.saveSummary(titled("first"), for: id)
        try store.saveEditedSummary(titled("edit"), for: id)
        try store.replaceSummary(titled("second"), for: id)
        try store.replaceSummary(titled("third"), for: id)
        #expect(try store.loadSummary(id)?.subjects.first?.title == "third")
        #expect(try store.loadPreviousSummary(id)?.subjects.first?.title == "edit")

        try store.saveEditedSummary(titled("second edit"), for: id)
        try store.replaceSummary(titled("fourth"), for: id)
        #expect(try store.loadPreviousSummary(id)?.subjects.first?.title == "second edit")
    }

    @Test func restoreRacingARegenerateLosesNoVersion() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let id = MeetingID(rawValue: "m")
        try FileManager.default.createDirectory(at: store.directory(id), withIntermediateDirectories: true)
        for round in 0..<200 {
            try? FileManager.default.removeItem(at: store.directory(id).appendingPathComponent("summary.previous.json"))
            try store.saveSummary(titled("P"), for: id)
            try store.replaceSummary(titled("C"), for: id)
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 {
                    _ = try? store.restorePreviousSummary(id)
                } else {
                    try? store.replaceSummary(titled("N"), for: id)
                }
            }
            let current = try #require(try store.loadSummary(id)).subjects.first?.title
            let previous = try #require(try store.loadPreviousSummary(id)).subjects.first?.title
            let outcome = "\(current ?? "")/\(previous ?? "")"
            #expect(["N/P", "C/N"].contains(outcome), "round \(round): \(outcome)")
        }
    }

    private struct InjectedFailure: Error {}

    private func storeWithEditAsPrevious() throws -> (store: MeetingStore, id: MeetingID, root: URL) {
        let root = try temporaryDirectory()
        let store = MeetingStore(root: root)
        let id = MeetingID(rawValue: "m")
        try FileManager.default.createDirectory(at: store.directory(id), withIntermediateDirectories: true)
        try store.saveEditedSummary(titled("edit"), for: id)
        try store.replaceSummary(titled("generated"), for: id)
        return (store, id, root)
    }

    private func titles(_ store: MeetingStore, _ id: MeetingID) throws -> String {
        let current = try store.loadSummary(id)?.subjects.first?.title ?? "-"
        let previous = try store.loadPreviousSummary(id)?.subjects.first?.title ?? "-"
        return "\(current)/\(previous)"
    }

    private func markdownTitle(_ store: MeetingStore, _ id: MeetingID) throws -> String {
        try String(contentsOf: store.directory(id).appendingPathComponent("summary.md"), encoding: .utf8)
    }

    @Test func restoreSwapsTheTwoFilesAndRewritesTheMarkdown() throws {
        let (store, id, root) = try storeWithEditAsPrevious()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try store.restorePreviousSummary(id).subjects.first?.title == "edit")
        #expect(try titles(store, id) == "edit/generated")
        #expect(try markdownTitle(store, id).contains("## edit"))
        #expect(!FileManager.default.fileExists(atPath: store.directory(id).appendingPathComponent("summary.swap.json").path))
    }

    @Test func restoringTwiceInARowLeavesTheOriginalArrangement() throws {
        let (store, id, root) = try storeWithEditAsPrevious()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try titles(store, id) == "generated/edit")
        try store.restorePreviousSummary(id)
        try store.restorePreviousSummary(id)
        #expect(try titles(store, id) == "generated/edit")
        #expect(try store.loadPreviousSummary(id)?.edited == true)
        #expect(try markdownTitle(store, id).contains("## generated"))
    }

    @Test func restoringTwiceKeepsTheEditWhenTheVolumeCannotSwap() throws {
        let (store, id, root) = try storeWithEditAsPrevious()
        defer { try? FileManager.default.removeItem(at: root) }
        store.swapFiles = { _, _ in ENOTSUP }
        try store.restorePreviousSummary(id)
        #expect(try titles(store, id) == "edit/generated")
        try store.restorePreviousSummary(id)
        #expect(try titles(store, id) == "generated/edit")
        store.swapFiles = { _, _ in EINVAL }
        try store.restorePreviousSummary(id)
        #expect(try titles(store, id) == "edit/generated")
        #expect(!FileManager.default.fileExists(atPath: store.directory(id).appendingPathComponent("summary.swap.json").path))
    }

    @Test func everyUnsupportedSwapErrorTakesTheFallback() throws {
        for code in [ENOTSUP, EOPNOTSUPP, EINVAL, ENOSYS] {
            let (store, id, root) = try storeWithEditAsPrevious()
            defer { try? FileManager.default.removeItem(at: root) }
            store.swapFiles = { _, _ in code }
            try store.restorePreviousSummary(id)
            #expect(try titles(store, id) == "edit/generated")
        }
    }

    @Test func aSwapFailureOtherThanUnsupportedChangesNothing() throws {
        let (store, id, root) = try storeWithEditAsPrevious()
        defer { try? FileManager.default.removeItem(at: root) }
        store.swapFiles = { _, _ in EACCES }
        #expect(throws: (any Error).self) { try store.restorePreviousSummary(id) }
        #expect(try titles(store, id) == "generated/edit")
    }

    @Test func aFailedStepOfTheFallbackSwapIsRolledBack() throws {
        let (store, id, root) = try storeWithEditAsPrevious()
        defer { try? FileManager.default.removeItem(at: root) }
        store.swapFiles = { _, _ in ENOTSUP }
        var writes = 0
        store.beforeRestoreWrite = { _ in
            writes += 1
            if writes == 3 { throw InjectedFailure() }
        }
        #expect(throws: InjectedFailure.self) { try store.restorePreviousSummary(id) }
        store.beforeRestoreWrite = nil
        #expect(try titles(store, id) == "generated/edit")
        #expect(!FileManager.default.fileExists(atPath: store.directory(id).appendingPathComponent("summary.swap.json").path))
    }

    @Test func aFailedRollbackKeepsTheSwapFileSoTheNextLoadFinishesTheRestore() throws {
        let (store, id, root) = try storeWithEditAsPrevious()
        defer { try? FileManager.default.removeItem(at: root) }
        store.swapFiles = { _, _ in ENOTSUP }
        var writes = 0
        store.beforeRestoreWrite = { _ in
            writes += 1
            if writes >= 3 { throw InjectedFailure() }
        }
        #expect(throws: InjectedFailure.self) { try store.restorePreviousSummary(id) }
        store.beforeRestoreWrite = nil
        #expect(FileManager.default.fileExists(atPath: store.directory(id).appendingPathComponent("summary.swap.json").path))
        #expect(try titles(store, id) == "edit/generated")
        #expect(!FileManager.default.fileExists(atPath: store.directory(id).appendingPathComponent("summary.swap.json").path))
        #expect(try markdownTitle(store, id).contains("## edit"))
    }

    @Test func restoreWithNoCurrentSummaryLeavesOnlyTheRestoredOne() throws {
        let (store, id, root) = try storeWithEditAsPrevious()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: store.directory(id).appendingPathComponent("summary.json"))
        try store.restorePreviousSummary(id)
        #expect(try store.loadSummary(id)?.subjects.first?.title == "edit")
        #expect(!store.hasPreviousSummary(id))
    }

    private func leaveSwapState(_ store: MeetingStore, _ id: MeetingID, current: String, previous: String, swap: String) throws {
        let directory = store.directory(id)
        try StorageJSON.encoder().encode(titled(current)).write(to: directory.appendingPathComponent("summary.json"))
        try StorageJSON.encoder().encode(titled(previous)).write(to: directory.appendingPathComponent("summary.previous.json"))
        try StorageJSON.encoder().encode(titled(swap)).write(to: directory.appendingPathComponent("summary.swap.json"))
    }

    @Test func aLeftoverSwapFileIsFinishedOnLoad() throws {
        let (store, id, root) = try storeWithEditAsPrevious()
        defer { try? FileManager.default.removeItem(at: root) }
        try leaveSwapState(store, id, current: "edit", previous: "edit", swap: "generated")
        #expect(try titles(store, id) == "edit/generated")
        #expect(!FileManager.default.fileExists(atPath: store.directory(id).appendingPathComponent("summary.swap.json").path))
        #expect(try markdownTitle(store, id).contains("## edit"))
    }

    @Test func aLeftoverSwapFileFromBeforeTheFirstCopyIsDropped() throws {
        let (store, id, root) = try storeWithEditAsPrevious()
        defer { try? FileManager.default.removeItem(at: root) }
        try leaveSwapState(store, id, current: "generated", previous: "edit", swap: "generated")
        #expect(try titles(store, id) == "generated/edit")
        #expect(!FileManager.default.fileExists(atPath: store.directory(id).appendingPathComponent("summary.swap.json").path))
    }

    @Test func aLeftoverSwapFileIsFinishedBeforeANewSummaryIsSaved() throws {
        let (store, id, root) = try storeWithEditAsPrevious()
        defer { try? FileManager.default.removeItem(at: root) }
        try leaveSwapState(store, id, current: "edit", previous: "edit", swap: "generated")
        try store.replaceSummary(titled("new"), for: id)
        #expect(try titles(store, id) == "new/edit")
        #expect(!FileManager.default.fileExists(atPath: store.directory(id).appendingPathComponent("summary.swap.json").path))
    }

    @Test func aSwapFileThatCannotBeFinishedDoesNotBlockLoading() throws {
        let (store, id, root) = try storeWithEditAsPrevious()
        defer { try? FileManager.default.removeItem(at: root) }
        let swapURL = store.directory(id).appendingPathComponent("summary.swap.json")
        try FileManager.default.createDirectory(at: swapURL, withIntermediateDirectories: false)
        #expect(try store.loadSummary(id)?.subjects.first?.title == "generated")
        #expect(try store.loadPreviousSummary(id)?.subjects.first?.title == "edit")
        #expect(store.hasPreviousSummary(id))
        #expect(FileManager.default.fileExists(atPath: swapURL.path))
    }

    @Test func anUnreadableSummaryFileKeepsTheSwapFileInsteadOfDeletingIt() throws {
        let (store, id, root) = try storeWithEditAsPrevious()
        defer { try? FileManager.default.removeItem(at: root) }
        try leaveSwapState(store, id, current: "edit", previous: "edit", swap: "generated")
        let directory = store.directory(id)
        let swapURL = directory.appendingPathComponent("summary.swap.json")
        let previousURL = directory.appendingPathComponent("summary.previous.json")
        chmod(previousURL.path, 0)
        defer { chmod(previousURL.path, 0o644) }
        #expect(throws: (any Error).self) { try store.saveSummary(titled("new"), for: id) }
        #expect(try store.loadSummary(id)?.subjects.first?.title == "edit")
        #expect(FileManager.default.fileExists(atPath: swapURL.path))
        chmod(previousURL.path, 0o644)
        #expect(try titles(store, id) == "edit/generated")
        #expect(!FileManager.default.fileExists(atPath: swapURL.path))
    }

    @Test func aMissingPreviousFileLetsRecoveryDropTheSwapFile() throws {
        let (store, id, root) = try storeWithEditAsPrevious()
        defer { try? FileManager.default.removeItem(at: root) }
        try leaveSwapState(store, id, current: "edit", previous: "edit", swap: "generated")
        let directory = store.directory(id)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("summary.previous.json"))
        #expect(try store.loadSummary(id)?.subjects.first?.title == "edit")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("summary.swap.json").path))
    }

    @Test func aStuckSwapFileLogsItsFailureOncePerMeeting() throws {
        let (store, id, root) = try storeWithEditAsPrevious()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: store.directory(id).appendingPathComponent("summary.swap.json"), withIntermediateDirectories: false)
        var logged: [MeetingID] = []
        store.recoveryFailureLogged = { logged.append($0) }
        for _ in 0..<3 {
            _ = store.hasPreviousSummary(id)
            _ = try store.loadSummary(id)
            _ = try store.loadPreviousSummary(id)
        }
        #expect(logged == [id])
    }

    @Test func concurrentUpdatesToDifferentFieldsAllLand() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let meeting = ModelTests.meeting(status: .ready)
        try store.create(meeting)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            _ = try? store.update(meeting.id) { current in
                if index.isMultiple(of: 2) {
                    current.speakerNames["k\(index)"] = "v"
                } else {
                    current.flags.append(Flag(offset: Double(index)))
                }
            }
        }
        let loaded = try store.load(meeting.id)
        #expect(loaded.speakerNames.count == 51)
        #expect(loaded.flags.count == 52)
    }

    @Test func updateReturnsTheSavedMeetingAndPropagatesErrors() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let meeting = ModelTests.meeting(status: .ready)
        try store.create(meeting)
        let updated = try store.update(meeting.id) { $0.title = "Renamed" }
        #expect(updated.title == "Renamed")
        #expect(try store.load(meeting.id).title == "Renamed")
        struct Boom: Error {}
        #expect(throws: Boom.self) { try store.update(meeting.id) { _ in throw Boom() } }
        #expect(try store.load(meeting.id).title == "Renamed")
        #expect(throws: (any Error).self) { try store.update(MeetingID(rawValue: "missing")) { _ in } }
    }

    @Test func failedMarkdownWriteLeavesNoTranscriptJSON() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let meeting = ModelTests.meeting(status: .ready)
        try store.create(meeting)
        let transcript = Transcript(segments: [Segment(id: 0, track: .mic, speaker: "you", start: 0, end: 1, text: "Hello", words: [])], language: "en")
        let clean = CleanTranscript(segments: [CleanSegment(id: 0, text: "Hello.")])
        try FileManager.default.createDirectory(at: store.transcriptMarkdownURL(meeting.id), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: store.cleanTranscriptMarkdownURL(meeting.id), withIntermediateDirectories: false)

        #expect(throws: (any Error).self) { try store.saveTranscript(transcript, for: meeting.id, speakerNames: [:]) }
        #expect(try store.loadTranscript(meeting.id) == nil)
        #expect(throws: (any Error).self) { try store.saveClean(clean, transcript: transcript, for: meeting.id, speakerNames: [:]) }
        #expect(try store.loadClean(meeting.id) == nil)

        try FileManager.default.removeItem(at: store.transcriptMarkdownURL(meeting.id))
        try FileManager.default.removeItem(at: store.cleanTranscriptMarkdownURL(meeting.id))
        try store.saveTranscript(transcript, for: meeting.id, speakerNames: [:])
        try store.saveClean(clean, transcript: transcript, for: meeting.id, speakerNames: [:])
        #expect(try store.loadTranscript(meeting.id) == transcript)
        #expect(try store.loadClean(meeting.id) == clean)
    }

    @Test func defaultValues() {
        let d = Settings.defaults
        #expect(d.defaultEngine == .macbook)
        #expect(d.macbook == EngineEndpoint(api: .ollama, baseURL: "http://127.0.0.1:11434", model: "qwen3:8b", keepAlive: "0"))
        #expect(d.studio == EngineEndpoint(api: .ollama, baseURL: "", model: "gpt-oss:20b", keepAlive: "10m"))
        #expect(d.accounts == [AccountSettings(id: "work", displayName: "Work", vaultArea: "Work", tenant: "organizations", clientID: "", selfAddresses: [])])
        #expect(d.vaultPath == "")
        #expect(d.inboxFolder == "Inbox")
        #expect(d.notePattern == "Meetings/{client}/{date} {title}.md")
        #expect(d.flagHotkey == Hotkey(key: "F", modifiers: ["control", "option", "command"]))
        #expect(d.watchList.count == 12)
        #expect(d.dictionary.isEmpty)
        #expect(d.userName == "")
        #expect(d.recording == RecordingSettings(voiceProcessing: false))
    }

    @Test func vaultIsUnsetUntilChosen() {
        var settings = Settings.defaults
        #expect(!settings.hasVault)
        settings.vaultPath = "  \n"
        #expect(!settings.hasVault)
        settings.vaultPath = "/Users/you/Notes"
        #expect(settings.hasVault)
        #expect(MeetingActions.vaultNotChosenNotice == "Choose your Obsidian vault in Settings first")
    }

    private func readyMeeting() -> Meeting {
        Meeting(
            id: MeetingID(rawValue: "m"), title: "Sync", startedAt: Date(timeIntervalSince1970: 0), endedAt: nil,
            captureMode: .micOnly, language: "en", accountID: nil, association: nil, client: nil,
            candidateEvents: [], attendees: [], recipients: [], flags: [], speakerNames: [:], status: .ready,
            summaryEngine: nil, engineNotice: nil, exportedNotePath: nil, draftWebLink: nil, metrics: ProcessingMetrics()
        )
    }

    private func decide(
        _ m: Meeting, _ settings: Settings, unsaved: Bool = false, changing: Bool = false, unsourced: Int = 0, noticeShown: Bool = false
    ) -> AutoFileDecision {
        MeetingActions.autoFileDecision(
            m, settings: settings, hasUnsavedEdits: unsaved, eventChangeInFlight: changing, unsourcedItems: unsourced, vaultNoticeShown: noticeShown
        )
    }

    @Test func exportRefusesWithoutAVault() {
        var settings = Settings.defaults
        #expect(MeetingActions.exportRefusal(settings: settings) == "Choose your Obsidian vault in Settings first")
        settings.vaultPath = "  "
        #expect(MeetingActions.exportRefusal(settings: settings) != nil)
        settings.vaultPath = "/Users/you/Notes"
        #expect(MeetingActions.exportRefusal(settings: settings) == nil)
    }

    @Test func autoFileWithoutAVaultNoticesOncePerSession() {
        var settings = Settings.defaults
        settings.autoFileToObsidian = true
        #expect(decide(readyMeeting(), settings) == .vaultNotChosen(showNotice: true))
        #expect(decide(readyMeeting(), settings, noticeShown: true) == .vaultNotChosen(showNotice: false))
        settings.vaultPath = "/Users/you/Notes"
        #expect(decide(readyMeeting(), settings) == .file)
        settings.autoFileToObsidian = false
        #expect(decide(readyMeeting(), settings) == .skip)
    }

    @Test func autoFileChecksEligibilityBeforeTheVault() {
        var settings = Settings.defaults
        settings.autoFileToObsidian = true
        var unsettled = readyMeeting()
        unsettled.candidateEvents = [CalendarEventRef(accountID: "work", eventID: "e", subject: "S", start: Date(timeIntervalSince1970: 0))]
        var exported = readyMeeting()
        exported.exportedNotePath = "Inbox/x.md"
        var waiting = readyMeeting()
        waiting.status = .waiting(.recording)
        for m in [unsettled, exported, waiting] {
            #expect(decide(m, settings) == .skip)
        }
        #expect(decide(readyMeeting(), settings, unsaved: true) == .skip)
        #expect(decide(readyMeeting(), settings, changing: true) == .skip)
        #expect(decide(readyMeeting(), settings, unsourced: 2) == .unsourced(2))
        #expect(decide(readyMeeting(), settings, unsourced: 2, noticeShown: true) == .unsourced(2))
    }

    @Test func recordingSettingsDecodeLossily() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        try Data(#"{"recording":{"voiceProcessing":true}}"#.utf8).write(to: file)
        #expect(SettingsStore(file: file).load().recording.voiceProcessing == true)
        try Data(#"{"recording":{"voiceProcessing":"yes"},"showPill":false}"#.utf8).write(to: file)
        let wrongType = SettingsStore(file: file).load()
        #expect(wrongType.recording.voiceProcessing == false)
        #expect(wrongType.showPill == false)
        try Data(#"{"recording":7}"#.utf8).write(to: file)
        #expect(SettingsStore(file: file).load().recording == RecordingSettings())
    }

    @Test func settingsPartialFileKeepsGivenAndDefaultsRest() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        try Data(#"{"defaultEngine":"studio"}"#.utf8).write(to: file)
        var expected = Settings.defaults
        expected.defaultEngine = .studio
        #expect(SettingsStore(file: file).load() == expected)
    }

    @Test func settingsUnknownKeysIgnored() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        try Data(#"{"showPill":false,"somethingNew":{"a":1}}"#.utf8).write(to: file)
        var expected = Settings.defaults
        expected.showPill = false
        #expect(SettingsStore(file: file).load() == expected)
    }

    @Test func settingsSaveRoundTripsAndCreatesDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config/muninn/settings.json")
        var settings = Settings.defaults
        settings.userName = "Ada"
        settings.clientDomains = ["acme.test": "Acme"]
        settings.autoFileToObsidian = true
        let store = SettingsStore(file: file)
        try store.save(settings)
        #expect(store.load() == settings)
    }

    @Test func corruptSettingsNotOverwritten() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let bytes = Data("{ this is not json".utf8)
        try bytes.write(to: file)
        #expect(SettingsStore(file: file).load() == Settings.defaults)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func partialNestedEndpointMergesDefaults() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        try Data(#"{"macbook":{"model":"llama3"},"studio":{"baseURL":"http://studio:11434"},"flagHotkey":{"key":"G"},"accounts":[{"id":"acme"}]}"#.utf8).write(to: file)
        let loaded = SettingsStore(file: file).load()
        #expect(loaded.macbook == EngineEndpoint(api: .ollama, baseURL: "http://127.0.0.1:11434", model: "llama3", keepAlive: "0"))
        #expect(loaded.studio == EngineEndpoint(api: .ollama, baseURL: "http://studio:11434", model: "gpt-oss:20b", keepAlive: "10m"))
        #expect(loaded.flagHotkey == Hotkey(key: "G", modifiers: ["control", "option", "command"]))
        #expect(loaded.accounts == [AccountSettings(id: "acme", displayName: "acme", vaultArea: "acme", tenant: "organizations", clientID: "", selfAddresses: [])])
        #expect(loaded.userName == "")
    }

    @Test func accountWithoutIDDropped() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        try Data(#"{"accounts":[{"displayName":"No id"},{"id":"acme","displayName":"Acme"}],"showPill":false}"#.utf8).write(to: file)
        let loaded = SettingsStore(file: file).load()
        #expect(loaded.accounts.map(\.id) == ["acme"])
        #expect(loaded.accounts.first?.vaultArea == "Acme")
        #expect(loaded.showPill == false)
    }

    @Test func storedAccountsWithoutADefaultAreKept() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        try Data(#"{"accounts":[{"id":"work","clientID":"abc"},{"id":"acme","displayName":"Acme","vaultArea":"Clients","clientID":"def","selfAddresses":["me@example.com"]}]}"#.utf8).write(to: file)
        let loaded = SettingsStore(file: file).load()
        #expect(loaded.accounts.map(\.id) == ["work", "acme"])
        #expect(loaded.accounts[0] == AccountSettings(id: "work", displayName: "Work", vaultArea: "Work", tenant: "organizations", clientID: "abc", selfAddresses: []))
        #expect(loaded.accounts[1] == AccountSettings(id: "acme", displayName: "Acme", vaultArea: "Clients", tenant: "organizations", clientID: "def", selfAddresses: ["me@example.com"]))
    }

    @Test func retiredAccountIDsRoundTripAndDecodeLossily() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file)
        #expect(Settings.defaults.retiredAccountIDs == [])
        var settings = Settings.defaults
        settings.retiredAccountIDs = ["acme", "globex"]
        try store.save(settings)
        #expect(store.load().retiredAccountIDs == ["acme", "globex"])

        try Data(#"{"showPill":false}"#.utf8).write(to: file)
        #expect(store.load().retiredAccountIDs == [])
        try Data(#"{"retiredAccountIDs":"acme","showPill":false}"#.utf8).write(to: file)
        let wrong = store.load()
        #expect(wrong.retiredAccountIDs == [])
        #expect(wrong.showPill == false)
    }

    @Test func corruptFilePreservedAcrossSave() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let bytes = Data("{ \"defaultEngine\": \"studio\", oops".utf8)
        try bytes.write(to: file)
        let store = SettingsStore(file: file)
        var settings = store.load()
        #expect(settings == Settings.defaults)
        settings.showPill = false
        try store.save(settings)

        let moved = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("settings.json.unreadable-") }
        #expect(moved.count == 1)
        #expect(try Data(contentsOf: root.appendingPathComponent(moved[0])) == bytes)
        #expect(store.load() == settings)
    }

    @Test func validFileNotMovedAsideOnSave() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file)
        try store.save(.defaults)
        try store.save(.defaults)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["settings.json"])
    }

    @Test func wronglyTypedFieldKeepsOthers() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        try Data(#"{"defaultEngine":"studio","showPill":"no","macbook":{"model":5,"keepAlive":"5m"},"flagHotkey":"F"}"#.utf8).write(to: file)
        let loaded = SettingsStore(file: file).load()
        #expect(loaded.defaultEngine == .studio)
        #expect(loaded.showPill == Settings.defaults.showPill)
        #expect(loaded.macbook == EngineEndpoint(api: .ollama, baseURL: "http://127.0.0.1:11434", model: "qwen3:8b", keepAlive: "5m"))
        #expect(loaded.flagHotkey == Settings.defaults.flagHotkey)
    }

    @Test func partialAccountMergesOntoMatchingDefault() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        try Data(#"{"accounts":[{"id":"work","clientID":"abc"}]}"#.utf8).write(to: file)
        let account = try #require(SettingsStore(file: file).load().accounts.first)
        #expect(account == AccountSettings(id: "work", displayName: "Work", vaultArea: "Work", tenant: "organizations", clientID: "abc", selfAddresses: []))
    }

    @Test func subSecondDatesRoundTripAndSlashesUnescaped() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var m = meeting("precise", startedAt: Date())
        m.exportedNotePath = "Work/Clients/Acme/note.md"
        try store.create(m)
        let loaded = try store.load(m.id)
        #expect(abs(loaded.startedAt.timeIntervalSince(m.startedAt)) < 0.001)
        let json = try String(contentsOf: store.directory(m.id).appendingPathComponent("meeting.json"), encoding: .utf8)
        #expect(json.contains("Work/Clients/Acme/note.md"))
        #expect(json.range(of: #"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z"#, options: .regularExpression) != nil)
    }

    @Test func wholeSecondDatesStillDecode() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("whole")
        try store.create(m)
        let url = store.directory(m.id).appendingPathComponent("meeting.json")
        let json = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: ".000Z", with: "Z")
        try Data(json.utf8).write(to: url)
        #expect(try store.load(m.id) == m)
    }

    @Test func listBreaksStartTieById() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let date = Date(timeIntervalSince1970: 5_000)
        for id in ["b", "c", "a"] { try store.create(meeting(id, startedAt: date)) }
        #expect(try store.list().map(\.id.rawValue) == ["a", "b", "c"])
    }

    @Test func existingIDsComeFromFolderNames() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        #expect(store.existingIDs() == [])
        for id in ["a", "b"] { try store.create(meeting(id)) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("broken"), withIntermediateDirectories: true)
        #expect(store.existingIDs() == ["a", "b", "broken"])
        #expect(MeetingStore(root: root.appendingPathComponent("missing")).existingIDs() == [])
    }

    @Test(arguments: ["localhost:11434", "studio.local", "http://", "ftp://studio", "   ", ""])
    func parseBaseRejectsInvalidURLs(_ input: String) {
        #expect(EndpointURL.parseBase(input) == nil)
    }

    @Test func parseBaseTrimsAndAcceptsHTTP() {
        #expect(EndpointURL.parseBase("  http://studio:11434/\n")?.absoluteString == "http://studio:11434/")
        #expect(EndpointURL.parseBase("HTTPS://studio.local")?.host == "studio.local")
    }
}
