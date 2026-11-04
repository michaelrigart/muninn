import Foundation
import Testing
@testable import MuninnCore

struct PresentationTests {
    private let t = Date(timeIntervalSince1970: 1_793_800_800)
    private let gb = Locale(identifier: "en_GB")
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func meeting(
        _ id: String = "a", title: String = "Sync", startedAt: Date? = nil, status: ProcessingStatus = .ready, client: String? = nil,
        attendees: [Attendee] = [], exportedNotePath: String? = nil, draftID: String? = nil
    ) -> Meeting {
        var meeting = Meeting(
            id: MeetingID(rawValue: id), title: title, startedAt: startedAt ?? t, endedAt: (startedAt ?? t).addingTimeInterval(600),
            captureMode: .micOnly, language: "en", accountID: nil, association: nil, client: client, candidateEvents: [],
            attendees: attendees, recipients: [], flags: [], speakerNames: [:], status: status, summaryEngine: nil,
            engineNotice: nil, exportedNotePath: exportedNotePath, draftWebLink: nil, metrics: ProcessingMetrics()
        )
        meeting.draftID = draftID
        return meeting
    }

    @Test func timestamps() {
        #expect(Timestamp.format(0) == "00:00")
        #expect(Timestamp.format(724.9) == "12:04")
        #expect(Timestamp.format(3725) == "1:02:05")
        #expect(Timestamp.format(-3) == "00:00")
    }

    @Test func nonFiniteTimesReadAsZero() {
        #expect(Timestamp.format(.nan) == "00:00")
        #expect(Timestamp.format(.infinity) == "00:00")
        #expect(DurationText.minutes(.nan) == "1 min")
        #expect(DurationText.minutes(.infinity) == "1 min")
    }

    @Test func durationInMinutes() {
        #expect(DurationText.minutes(20) == "1 min")
        #expect(DurationText.minutes(2700) == "45 min")
        #expect(DurationText.minutes(3900) == "1 h 5 min")
        #expect(DurationText.minutes(7200) == "2 h")
    }

    @Test func metaLine() {
        #expect(MeetingLabels.meta(start: t, end: t + 2700, language: "nl", calendar: utc, locale: gb) == "Wed, 4 Nov 2026 · 14:00–14:45 · 45 min · Dutch")
        #expect(MeetingLabels.meta(start: t, end: nil, language: nil, calendar: utc, locale: gb) == "Wed, 4 Nov 2026 · 14:00")
    }

    @Test func sidebarTimeSaysTheDayWhereTheGroupDoesNot() {
        let now = t + 3600
        #expect(MeetingLabels.sidebarTime(start: t, end: t + 2700, group: .today, now: now, calendar: utc, locale: gb) == "14:00 · 45 min")
        #expect(MeetingLabels.sidebarTime(start: t, end: t + 2700, group: .thisWeek, now: now, calendar: utc, locale: gb) == "Wed 14:00 · 45 min")
        #expect(MeetingLabels.sidebarTime(start: t, end: t + 2700, group: .earlier, now: now, calendar: utc, locale: gb) == "4 Nov 14:00 · 45 min")
        #expect(MeetingLabels.sidebarTime(start: t, end: t + 2700, group: .earlier, now: now + 400 * 86_400, calendar: utc, locale: gb) == "4 Nov 2026 14:00 · 45 min")
        #expect(MeetingLabels.sidebarTime(start: t, end: nil, group: .today, now: now, calendar: utc, locale: gb) == "14:00")
    }

    @Test func detailsChip() {
        #expect(MeetingLabels.detailsChip(accountName: "Work", client: "Acme") == "Work · Acme")
        #expect(MeetingLabels.detailsChip(accountName: "Work", client: nil) == "Work")
        #expect(MeetingLabels.detailsChip(accountName: nil, client: "Acme") == "Acme")
        #expect(MeetingLabels.detailsChip(accountName: nil, client: nil) == "Account and client")
    }

    @Test func personLabels() {
        #expect(PersonLabel.initials(name: "Ann van Example", email: "ann@example.com") == "AE")
        #expect(PersonLabel.initials(name: "Ann", email: "ann@example.com") == "A")
        #expect(PersonLabel.initials(name: " ", email: "bob@example.com") == "B")
        #expect(PersonLabel.shortName(name: "Ann Example", email: "ann@example.com") == "Ann")
        #expect(PersonLabel.shortName(name: "", email: "bob.example@example.com") == "bob.example")
    }

    @Test func groupingKeepsTheDayRules() {
        let now = t + 3600
        let day: TimeInterval = 86_400
        let today = meeting("today")
        let yesterday = meeting("yesterday", startedAt: t - day)
        let monday = meeting("monday", startedAt: t - 2 * day)
        let old = meeting("old", startedAt: t - 10 * day)
        let groups = MeetingGrouping.groups([old, monday, yesterday, today], now: now, calendar: utc)
        #expect(groups.map(\.group) == [.today, .yesterday, .thisWeek, .earlier])
        #expect(groups.map { $0.meetings.map(\.id.rawValue) } == [["today"], ["yesterday"], ["monday"], ["old"]])
        #expect(MeetingGrouping.groups([old], now: now, calendar: utc).map(\.group) == [.earlier])
        #expect(DayGroup.allCases.map(\.title) == ["Today", "Yesterday", "This week", "Earlier"])
    }

    @Test func sidebarSignPrecedence() {
        let work = PipelineWork(meetingID: MeetingID(rawValue: "a"), stage: .transcribing, engine: nil, stageStartedAt: t)
        let ready = meeting()
        #expect(SidebarSign.sign(for: ready, progress: .working(work), needsAttention: false) == .progress(step: 1, label: "Transcribing"))
        let preparing = MeetingProgress.preparingSpeechModel(SpeechModelPreparation(model: "m", fraction: nil))
        #expect(SidebarSign.sign(for: ready, progress: preparing, needsAttention: false) == .progress(step: 1, label: "Getting the speech model ready"))
        #expect(SidebarSign.sign(for: ready, progress: .queued(ahead: 1), needsAttention: true) == .queued)
        let problem = Problems.claudeBusy()
        #expect(SidebarSign.sign(for: meeting(status: .failed(problem)), progress: .failed(problem), needsAttention: true) == .attention)
        #expect(SidebarSign.sign(for: meeting(status: .recording), progress: .none, needsAttention: false) == .recording)
        #expect(SidebarSign.sign(for: meeting(exportedNotePath: "n.md", draftID: "d"), progress: .none, needsAttention: false) == .draftCreated)
        #expect(SidebarSign.sign(for: meeting(exportedNotePath: "n.md"), progress: .none, needsAttention: false) == .filed)
        #expect(SidebarSign.sign(for: ready, progress: .none, needsAttention: false) == .none)
    }

    @Test func searchCoversEveryField() {
        let found = meeting(title: "Budget review", client: "Acme", attendees: [Attendee(name: "Ann Example", email: "ann@example.com")])
        #expect(MeetingSearch.matches(found, term: "budget", recapText: nil, transcriptText: nil))
        #expect(MeetingSearch.matches(found, term: "acme", recapText: nil, transcriptText: nil))
        #expect(MeetingSearch.matches(found, term: "Ann", recapText: nil, transcriptText: nil))
        #expect(MeetingSearch.matches(found, term: "ann@example.com", recapText: nil, transcriptText: nil))
        #expect(MeetingSearch.matches(found, term: "roadmap", recapText: "The roadmap slips", transcriptText: nil))
        #expect(MeetingSearch.matches(found, term: "invoice", recapText: nil, transcriptText: "send the invoice"))
        #expect(MeetingSearch.matches(found, term: "  ", recapText: nil, transcriptText: nil))
        #expect(!MeetingSearch.matches(found, term: "zebra", recapText: "roadmap", transcriptText: "invoice"))
    }

    @Test func searchFoldsCaseAndAccents() {
        #expect(MeetingSearch.matches(meeting(client: "Café Noir"), term: "cafe noir", recapText: nil, transcriptText: nil))
    }

    @Test func recapTextHoldsTitlesBulletsAndActions() {
        let subject = Subject(
            title: "Budget", bullets: [Bullet(text: "Cut travel", sources: [])],
            actions: [ActionPoint(owner: "Ann", text: "Send figures", due: nil, sources: [])]
        )
        let text = MeetingSearch.recapText(Summary(language: "en", subjects: [subject], engine: .claude, generatedAt: t))
        for part in ["Budget", "Cut travel", "Ann", "Send figures"] { #expect(text.contains(part)) }
    }
}
