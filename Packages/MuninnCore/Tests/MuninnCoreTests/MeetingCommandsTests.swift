import Foundation
import Testing
@testable import MuninnCore

struct MeetingCommandsTests {
    private static let t = Date(timeIntervalSince1970: 1_800_000_000)
    private static let work = PipelineWork(meetingID: MeetingID(rawValue: "a"), stage: .transcribing, engine: nil, stageStartedAt: t)
    private static let notReady = "The recap isn't ready yet"
    private static let wait = "Wait until Muninn has finished this meeting"
    private static let save = "Save your recap edits first"
    private static let eventChange = "Wait for the event change"

    private static func meeting(
        _ status: ProcessingStatus = .ready, association: EventAssociation? = nil,
        candidates: [CalendarEventRef] = [], attendees: [Attendee] = []
    ) -> Meeting {
        Meeting(
            id: MeetingID(rawValue: "a"), title: "Sync", startedAt: t, endedAt: t.addingTimeInterval(600),
            captureMode: .micOnly, language: "en", accountID: nil, association: association, client: nil,
            candidateEvents: candidates, attendees: attendees, recipients: [], flags: [], speakerNames: [:],
            status: status, summaryEngine: nil, engineNotice: nil, exportedNotePath: nil, metrics: ProcessingMetrics()
        )
    }

    private static func context(
        _ meeting: Meeting = meeting(), progress: MeetingProgress = .none, hasRecap: Bool = true, hasPreviousRecap: Bool = true,
        unsavedEdits: Bool = false, eventChanging: Bool = false
    ) -> MeetingCommandContext {
        MeetingCommandContext(
            meeting: meeting, progress: progress, hasRecap: hasRecap, hasPreviousRecap: hasPreviousRecap,
            unsavedEdits: unsavedEdits, eventChanging: eventChanging
        )
    }

    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var context: MeetingCommandContext
        var reason: String?
        var testDescription: String { name }
    }

    private static let candidate = CalendarEventRef(accountID: "work", eventID: "e", subject: "Sync", start: t)
    private static let preparing = MeetingProgress.preparingSpeechModel(SpeechModelPreparation(model: "m", fraction: nil))

    static let regenerate: [Case] = [
        Case(name: "ready", context: context(), reason: nil),
        Case(name: "recording", context: context(meeting(.recording)), reason: "Choose an engine once the recording has ended"),
        Case(name: "waiting for the recording", context: context(meeting(.waiting(.recording))), reason: "Choose an engine once the recording has ended"),
        Case(name: "summarizing", context: context(meeting(.summarizing)), reason: wait),
        Case(name: "working", context: context(progress: .working(work)), reason: wait),
        Case(name: "preparing the model", context: context(progress: preparing), reason: wait),
        Case(name: "queued", context: context(progress: .queued(ahead: 1)), reason: wait),
        Case(name: "unsaved", context: context(unsavedEdits: true), reason: save),
        Case(name: "event changing", context: context(eventChanging: true), reason: eventChange),
        Case(name: "busy before unsaved", context: context(meeting(.cleaning), unsavedEdits: true), reason: wait),
        Case(name: "failed", context: context(meeting(.failed(Problems.claudeBusy()))), reason: nil),
    ]

    @Test(arguments: regenerate) func regenerateReasons(_ c: Case) {
        #expect(MeetingCommands.disabledReason(.regenerate, c.context) == c.reason)
    }

    static let export: [Case] = [
        Case(name: "ready with a recap", context: context(), reason: nil),
        Case(name: "recording", context: context(meeting(.recording)), reason: notReady),
        Case(name: "diarizing", context: context(meeting(.diarizing)), reason: notReady),
        Case(name: "failed", context: context(meeting(.failed(Problems.claudeBusy()))), reason: notReady),
        Case(name: "waiting", context: context(meeting(.waiting(.claudeKeyMissing))), reason: notReady),
        Case(name: "ready but queued", context: context(progress: .queued(ahead: 0)), reason: notReady),
        Case(name: "ready but working", context: context(progress: .working(work)), reason: notReady),
        Case(name: "no recap", context: context(hasRecap: false), reason: "There's no recap yet"),
        Case(name: "unsaved", context: context(unsavedEdits: true), reason: save),
        Case(name: "event changing", context: context(eventChanging: true), reason: eventChange),
        Case(name: "candidate events", context: context(meeting(candidates: [candidate])), reason: "Choose the event first"),
        Case(name: "no recap before unsaved", context: context(hasRecap: false, unsavedEdits: true), reason: "There's no recap yet"),
    ]

    @Test(arguments: export, [MeetingCommand.emailRecap, .obsidian])
    func exportReasons(_ c: Case, _ command: MeetingCommand) {
        #expect(MeetingCommands.disabledReason(command, c.context) == c.reason)
    }

    static let previous: [Case] = [
        Case(name: "has one", context: context(), reason: nil),
        Case(name: "none", context: context(hasPreviousRecap: false), reason: "There's no previous version"),
        Case(name: "busy", context: context(progress: .queued(ahead: 0)), reason: wait),
        Case(name: "unsaved", context: context(unsavedEdits: true), reason: save),
        Case(name: "none before busy", context: context(progress: .queued(ahead: 0), hasPreviousRecap: false), reason: "There's no previous version"),
        Case(name: "recording is not busy here", context: context(meeting(.recording)), reason: nil),
    ]

    @Test(arguments: previous) func previousVersionReasons(_ c: Case) {
        #expect(MeetingCommands.disabledReason(.previousVersion, c.context) == c.reason)
    }

    static let trash: [Case] = [
        Case(name: "ready", context: context(), reason: nil),
        Case(name: "failed", context: context(meeting(.failed(Problems.claudeBusy()))), reason: nil),
        Case(name: "waiting", context: context(meeting(.waiting(.claudeKeyMissing))), reason: nil),
        Case(name: "recording", context: context(meeting(.recording)), reason: "Stop the recording first"),
        Case(name: "transcribing", context: context(meeting(.transcribing)), reason: wait),
        Case(name: "ready but working", context: context(progress: .working(work)), reason: wait),
        Case(name: "ready but queued", context: context(progress: .queued(ahead: 2)), reason: wait),
    ]

    @Test(arguments: trash) func moveToTrashReasons(_ c: Case) {
        #expect(MeetingCommands.disabledReason(.moveToTrash, c.context) == c.reason)
    }

    @Test func accountChangeDropsOnlyAnotherAccountsEvent() {
        let withEvent = Self.meeting(association: EventAssociation(accountID: "work", eventID: "e", iCalUID: nil))
        #expect(!MeetingActions.accountChangeDropsEvent(withEvent, to: "work"))
        #expect(MeetingActions.accountChangeDropsEvent(withEvent, to: "other"))
        #expect(MeetingActions.accountChangeDropsEvent(withEvent, to: nil))
        #expect(!MeetingActions.accountChangeDropsEvent(Self.meeting(), to: "other"))
    }

    @Test func speakerChangesWaitForProcessing() {
        #expect(MeetingCommands.speakerChangeRefusal(status: .recording, progress: .none, hasJob: false) == "Stop the recording first")
        for status: ProcessingStatus in [.transcribing, .diarizing, .cleaning, .summarizing, .waiting(.studioUnreachable), .waiting(.queued), .waiting(.recording)] {
            #expect(MeetingCommands.speakerChangeRefusal(status: status, progress: .none, hasJob: false) == Self.wait)
        }
        for progress: MeetingProgress in [.working(Self.work), .preparingSpeechModel(SpeechModelPreparation(model: "m", fraction: nil)), .queued(ahead: 0), .waiting(.memoryPressure)] {
            #expect(MeetingCommands.speakerChangeRefusal(status: .ready, progress: progress, hasJob: false) == Self.wait)
        }
        #expect(MeetingCommands.speakerChangeRefusal(status: .ready, progress: .none, hasJob: true) == Self.wait)
        #expect(MeetingCommands.speakerChangeRefusal(status: .ready, progress: .none, hasJob: false) == nil)
        let problem = Problems.claudeBusy()
        #expect(MeetingCommands.speakerChangeRefusal(status: .failed(problem), progress: .failed(problem), hasJob: false) == nil)
    }

    @Test func clearingAsksOnlyWhenSomethingIsLost() {
        let person = Attendee(name: "Sam", email: "sam@example.com")
        #expect(MeetingActions.clearingEventLosesDetails(Self.meeting(association: EventAssociation(accountID: "work", eventID: "e", iCalUID: nil))))
        #expect(MeetingActions.clearingEventLosesDetails(Self.meeting(attendees: [person])))
        #expect(!MeetingActions.clearingEventLosesDetails(Self.meeting()))
    }
}
