import Foundation
import Testing
@testable import MuninnCore

struct ProcessingDisplayTests {
    private let a = MeetingID(rawValue: "a")
    private let b = MeetingID(rawValue: "b")
    private let c = MeetingID(rawValue: "c")
    private let t = Date(timeIntervalSince1970: 1_800_000_000)

    private func meeting(_ id: MeetingID, _ status: ProcessingStatus, title: String = "Sync", engineNotice: Problem? = nil) -> Meeting {
        Meeting(
            id: id, title: title, startedAt: t, endedAt: t.addingTimeInterval(600),
            captureMode: .micOnly, language: "en", accountID: nil, association: nil, client: nil, candidateEvents: [],
            attendees: [], recipients: [], flags: [], speakerNames: [:], status: status, summaryEngine: nil,
            engineNotice: engineNotice, exportedNotePath: nil, draftWebLink: nil, metrics: ProcessingMetrics()
        )
    }

    private func work(_ id: MeetingID, _ stage: PipelineStage, engine: EngineKind? = nil) -> PipelineWork {
        PipelineWork(meetingID: id, stage: stage, engine: engine, stageStartedAt: t)
    }

    private func progress(_ meeting: Meeting, _ snapshot: PipelineSnapshot, speechModel: SpeechModelPreparation? = nil) -> MeetingProgress {
        ProcessingDisplay.progress(for: meeting, snapshot: snapshot, speechModel: speechModel)
    }

    private var busy: PipelineSnapshot {
        PipelineSnapshot(current: work(a, .transcribing), queued: [b, c])
    }

    @Test func queuedMeetingShowsItsPosition() {
        #expect(progress(meeting(c, .transcribing), busy) == .queued(ahead: 2))
        #expect(progress(meeting(b, .ready), busy) == .queued(ahead: 1))
    }

    @Test func retriedFailureShowsAsQueued() {
        let problem = Problems.claudeBusy()
        #expect(progress(meeting(c, .failed(problem)), busy) == .queued(ahead: 2))
        #expect(progress(meeting(MeetingID(rawValue: "d"), .failed(problem)), busy) == .failed(problem))
    }

    @Test func waitWinsOverQueue() {
        #expect(progress(meeting(c, .waiting(.thisMacUnreachable)), busy) == .waiting(.thisMacUnreachable))
    }

    @Test func aClearedWaitShowsItsQueuePosition() {
        #expect(progress(meeting(c, .waiting(.queued)), busy) == .queued(ahead: 2))
        let other = meeting(MeetingID(rawValue: "d"), .waiting(.queued))
        #expect(progress(other, busy) == .queued(ahead: 3))
    }

    @Test func currentWorkShowsTheStage() {
        let current = work(a, .writingRecap, engine: .claude)
        let snapshot = PipelineSnapshot(current: current, queued: [])
        #expect(progress(meeting(a, .summarizing), snapshot) == .working(current))
    }

    @Test func speechModelPreparationShowsWhileTranscribing() {
        let preparation = SpeechModelPreparation(model: "Parakeet v3", fraction: 0.4)
        #expect(progress(meeting(a, .transcribing), busy, speechModel: preparation) == .preparingSpeechModel(preparation))
        let writing = PipelineSnapshot(current: work(a, .writingRecap), queued: [])
        #expect(progress(meeting(a, .summarizing), writing, speechModel: preparation) == .working(work(a, .writingRecap)))
    }

    @Test func processingStatusOutsideTheQueueReadsAsWaitingItsTurn() {
        #expect(progress(meeting(a, .transcribing), .idle) == .queued(ahead: 0))
    }

    @Test func readyAndRecordingShowNothing() {
        #expect(progress(meeting(a, .ready), .idle) == .none)
        #expect(progress(meeting(a, .recording), .idle) == .none)
    }

    @Test func menuLines() {
        let snapshot = PipelineSnapshot(current: work(a, .writingRecap), queued: [])
        #expect(ProcessingDisplay.workLine(meetings: [meeting(a, .summarizing, title: "Supplier call")], snapshot: snapshot) == "Writing the recap · Supplier call · step 4 of 4")
        #expect(ProcessingDisplay.workLine(meetings: [], snapshot: snapshot) == nil)
        #expect(ProcessingDisplay.workLine(meetings: [meeting(a, .ready)], snapshot: .idle) == nil)
        #expect(ProcessingDisplay.attentionLine(count: 0) == nil)
        #expect(ProcessingDisplay.attentionLine(count: 1) == "1 meeting needs attention")
        #expect(ProcessingDisplay.attentionLine(count: 3) == "3 meetings need attention")
    }

    @Test func attentionReasonNamesTheCause() {
        #expect(ProcessingDisplay.attentionReason(meeting(a, .waiting(.thisMacUnreachable)), api: .ollama) == "Ollama isn't running on This Mac")
        #expect(ProcessingDisplay.attentionReason(meeting(a, .failed(Problems.claudeBusy())), api: .ollama) == "Claude is busy right now")
        #expect(ProcessingDisplay.attentionReason(meeting(a, .ready, engineNotice: Problems.claudeKeyMissing()), api: .ollama) == "There's no Claude API key")
        #expect(ProcessingDisplay.attentionReason(meeting(a, .ready), api: .ollama) == nil)
    }

    // MARK: Attention tracker

    private var failed: ProcessingStatus { .failed(Problems.claudeBusy()) }

    @Test func meetingsAlreadyNeedingAttentionAtLaunchAreNotAnnounced() {
        var tracker = AttentionTracker(seed: [meeting(a, failed)])
        #expect(tracker.update([meeting(a, failed)], isRecording: false).isEmpty)
    }

    @Test func enteringAttentionAnnouncesOnce() {
        var tracker = AttentionTracker(seed: [meeting(a, .ready)])
        #expect(tracker.update([meeting(a, failed)], isRecording: false) == [a])
        #expect(tracker.update([meeting(a, failed)], isRecording: false).isEmpty)
        #expect(tracker.update([meeting(a, .ready)], isRecording: false).isEmpty)
        #expect(tracker.update([meeting(a, failed)], isRecording: false) == [a])
    }

    @Test func aWaitRewrittenEvery15SecondsIsNotRepeated() {
        var tracker = AttentionTracker(seed: [meeting(a, .summarizing)])
        let waiting = [meeting(a, .waiting(.thisMacUnreachable))]
        #expect(tracker.update(waiting, isRecording: false) == [a])
        for _ in 0..<4 {
            #expect(tracker.update(waiting, isRecording: false).isEmpty)
        }
    }

    @Test func announcementsWaitForTheRecordingToStop() {
        var tracker = AttentionTracker(seed: [meeting(a, .ready)])
        #expect(tracker.update([meeting(a, failed)], isRecording: true).isEmpty)
        #expect(tracker.update([meeting(a, failed)], isRecording: true).isEmpty)
        #expect(tracker.update([meeting(a, failed)], isRecording: false) == [a])
    }

    @Test func aMeetingThatRecoversDuringTheRecordingIsNotAnnounced() {
        var tracker = AttentionTracker(seed: [meeting(a, .ready)])
        #expect(tracker.update([meeting(a, failed)], isRecording: true).isEmpty)
        #expect(tracker.update([meeting(a, .ready)], isRecording: true).isEmpty)
        #expect(tracker.update([meeting(a, .ready)], isRecording: false).isEmpty)
    }
}
