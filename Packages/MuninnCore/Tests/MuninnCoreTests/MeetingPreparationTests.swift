import Foundation
import Testing
@testable import MuninnCore

@Suite struct MeetingPreparationTests {
    let zone = TimeZone(identifier: "Europe/Brussels")!
    let start = Date(timeIntervalSince1970: 1_761_203_400)
    let accounts = [
        AccountSettings(id: "work", displayName: "Work", vaultArea: "Work", tenant: "organizations", clientID: "c", selfAddresses: ["me@example.com"]),
        AccountSettings(id: "other", displayName: "Other", vaultArea: "Other", tenant: "organizations", clientID: "c", selfAddresses: ["me@example.org"]),
    ]
    let domains = ["acme.be": "Acme"]

    func event(_ id: String, account: String = "work", subject: String = "Kickoff") -> CalendarEvent {
        CalendarEvent(
            accountID: account, eventID: id, iCalUID: "uid-\(id)", subject: subject,
            start: start, end: start.addingTimeInterval(3600), isAllDay: false, isCancelled: false,
            attendees: [Attendee(name: "Me", email: "me@example.com"), Attendee(name: "Jan", email: "jan@acme.be")],
            organizer: Attendee(name: "Me", email: "me@example.com")
        )
    }

    func prepare(_ match: EventMatch, appName: String? = "Teams") -> Meeting {
        MeetingPreparation.prepare(
            startedAt: start, mode: .call(appBundleID: "com.microsoft.teams2"), appName: appName, match: match,
            accounts: accounts, clientDomains: domains, timeZone: zone, existingIDs: []
        )
    }

    @Test func noEventGivesUntitledAndNoAccount() {
        let m = prepare(.none)
        #expect(m.title == RecipientBuilder.untitledTitle(appName: "Teams", at: start, timeZone: zone))
        #expect(m.accountID == nil)
        #expect(m.association == nil)
        #expect(m.recipients.isEmpty)
        #expect(m.status == .recording)
        #expect(m.captureMode == .call(appBundleID: "com.microsoft.teams2"))
    }

    @Test func theMeetingKeepsTheZoneItWasPreparedIn() {
        #expect(prepare(.none).timeZone == "Europe/Brussels")
        #expect(prepare(.single(event("e1"))).timeZone == "Europe/Brussels")
        let los = MeetingPreparation.prepare(
            startedAt: start, mode: .micOnly, appName: nil, match: .none, accounts: accounts, clientDomains: domains,
            timeZone: TimeZone(identifier: "America/Los_Angeles")!, existingIDs: []
        )
        #expect(los.timeZone == "America/Los_Angeles")
    }

    @Test func noEventWithoutAppNameUsesConversation() {
        let m = prepare(.none, appName: nil)
        #expect(m.title == RecipientBuilder.untitledTitle(appName: "Conversation", at: start, timeZone: zone))
    }

    @Test func singleEventFillsRecipientsAndClient() {
        let m = prepare(.single(event("e1")))
        #expect(m.title == "Kickoff")
        #expect(m.accountID == "work")
        #expect(m.association == EventAssociation(accountID: "work", eventID: "e1", iCalUID: "uid-e1"))
        #expect(m.client == "Acme")
        #expect(m.attendees == event("e1").attendees)
        #expect(m.recipients.map(\.attendee.email) == ["jan@acme.be"])
        #expect(m.id == MeetingID.make(startedAt: start, title: "Kickoff", timeZone: zone, existing: []))
    }

    @Test func organizerOutsideTheAttendeeListJoinsTheAttendees() {
        var organized = event("e3")
        organized.organizer = Attendee(name: "Kim", email: "Kim@Acme.be")
        let m = prepare(.single(organized))
        #expect(m.attendees.map(\.email) == ["Kim@Acme.be", "me@example.com", "jan@acme.be"])
        let again = prepare(.single(event("e1")))
        #expect(again.attendees.map(\.email) == ["me@example.com", "jan@acme.be"])

        var listed = organized
        listed.attendees.append(Attendee(name: "Kim", email: "kim@acme.be"))
        #expect(prepare(.single(listed)).attendees.filter { $0.email.lowercased() == "kim@acme.be" }.count == 1)
    }

    @Test func summaryAttendeesLineNamesTheOrganizerButNotTheUser() {
        var organized = event("e3")
        organized.organizer = Attendee(name: "Kim", email: "kim@acme.be")
        let m = prepare(.single(organized))
        let transcript = Transcript(segments: [Segment(id: 0, track: .mic, speaker: Transcript.youSpeaker, start: 0, end: 1, text: "Hello", words: [])], language: "en")
        let request = SummaryRequestBuilder.build(
            meeting: m, transcript: transcript, clean: CleanTranscript(segments: [CleanSegment(id: 0, text: "Hello")]), selfAddresses: ["me@example.com"]
        )
        #expect(request.user.contains("\nAttendees: Kim <kim@acme.be>, Jan <jan@acme.be>\n"))
    }

    @Test func clearingTheEventRestoresTheNoEventState() {
        var m = prepare(.single(event("e1")))
        m = MeetingActions.addRecipient(Attendee(name: "Pat", email: "pat@example.org"), to: m, selfAddresses: ["me@example.com"])
        #expect(m.recipients.map(\.attendee.email) == ["jan@acme.be", "pat@example.org"])

        let cleared = MeetingActions.clearEvent(m, appName: "Teams", timeZone: zone)
        #expect(cleared.title == RecipientBuilder.untitledTitle(appName: "Teams", at: start, timeZone: zone))
        #expect(cleared.association == nil)
        #expect(cleared.accountID == nil)
        #expect(cleared.client == nil)
        #expect(cleared.attendees.isEmpty)
        #expect(cleared.candidateEvents.isEmpty)
        #expect(cleared.recipients.map(\.attendee.email) == ["pat@example.org"])
        #expect(cleared.id == m.id)
    }

    @Test func aFetchedEventIsAppliedOnlyWhileNoDraftOrNoteExists() {
        let original = prepare(.single(event("e1")))
        let other = event("e2", subject: "Retro")

        let changed = MeetingActions.changeEvent(original, to: other, accounts: accounts, clientDomains: domains)
        #expect(changed?.title == "Retro")
        #expect(changed?.association?.eventID == "e2")

        var drafted = original
        drafted.draftID = "d1"
        #expect(MeetingActions.changeEvent(drafted, to: other, accounts: accounts, clientDomains: domains) == nil)

        var linked = original
        linked.draftWebLink = "https://outlook.test/d1"
        #expect(MeetingActions.changeEvent(linked, to: other, accounts: accounts, clientDomains: domains) == nil)

        var exported = original
        exported.exportedNotePath = "Work/note.md"
        #expect(MeetingActions.changeEvent(exported, to: other, accounts: accounts, clientDomains: domains) == nil)
    }

    @Test func clearingTheEventOfAMicOnlyMeetingUsesTheConversationTitle() {
        let m = MeetingPreparation.prepare(
            startedAt: start, mode: .micOnly, appName: nil, match: .single(event("e1")),
            accounts: accounts, clientDomains: domains, timeZone: zone, existingIDs: []
        )
        let cleared = MeetingActions.clearEvent(m, appName: nil, timeZone: zone)
        #expect(cleared.title == RecipientBuilder.untitledTitle(appName: "Conversation", at: start, timeZone: zone))
        #expect(cleared.recipients.isEmpty)
    }

    @Test func clearingAnUnassociatedMeetingKeepsAHandChosenAccount() {
        var m = prepare(.ambiguous([event("e1"), event("e2", account: "other", subject: "Other")]))
        m.accountID = "other"
        let cleared = MeetingActions.clearEvent(m, appName: "Teams", timeZone: zone)
        #expect(cleared.candidateEvents.isEmpty)
        #expect(cleared.accountID == "other")
    }

    @Test func ambiguousLeavesChoice() {
        let m = prepare(.ambiguous([event("e1"), event("e2", account: "other", subject: "Other")]))
        #expect(m.candidateEvents == [
            CalendarEventRef(accountID: "work", eventID: "e1", subject: "Kickoff", start: start),
            CalendarEventRef(accountID: "other", eventID: "e2", subject: "Other", start: start),
        ])
        #expect(m.accountID == nil)
        #expect(m.association == nil)
        #expect(m.recipients.isEmpty)
        #expect(m.title == RecipientBuilder.untitledTitle(appName: "Teams", at: start, timeZone: zone))
    }

    @Test func chooseResolvesAmbiguous() {
        let m = prepare(.ambiguous([event("e1"), event("e2", account: "other", subject: "Other")]))
        let chosen = MeetingPreparation.choose(event("e1"), for: m, accounts: accounts, clientDomains: domains)
        #expect(chosen.id == m.id)
        #expect(chosen.title == "Kickoff")
        #expect(chosen.accountID == "work")
        #expect(chosen.association?.eventID == "e1")
        #expect(chosen.client == "Acme")
        #expect(chosen.candidateEvents.isEmpty)
        #expect(chosen.attendees == event("e1").attendees)
        #expect(chosen.recipients.map(\.attendee.email) == ["jan@acme.be"])
    }

    @Test func chooseExcludesOtherAccountsSelfAddress() {
        var other = event("e2", account: "other", subject: "Other")
        other.attendees = [Attendee(name: "Me", email: "me@example.com"), Attendee(name: "Me", email: "me@example.org"), Attendee(name: "Jan", email: "jan@acme.be")]
        other.organizer = Attendee(name: "Me", email: "me@example.org")
        let m = prepare(.ambiguous([event("e1"), other]))
        let chosen = MeetingPreparation.choose(other, for: m, accounts: accounts, clientDomains: domains)
        #expect(chosen.recipients.map(\.attendee.email) == ["jan@acme.be"])
        #expect(chosen.client == "Acme")
    }

    @Test func canDraftRequiresAccountAndRecipient() {
        var m = prepare(.none)
        #expect(!MeetingActions.canDraft(m, accounts: accounts))
        m.accountID = "work"
        #expect(!MeetingActions.canDraft(m, accounts: accounts))
        m = MeetingActions.addRecipient(Attendee(name: "Jan", email: "jan@acme.be"), to: m, selfAddresses: [])
        #expect(MeetingActions.canDraft(m, accounts: accounts))
        m = MeetingActions.setIncluded("JAN@acme.be", false, in: m)
        #expect(!MeetingActions.canDraft(m, accounts: accounts))
    }

    @Test func aMeetingWhoseAccountWasRemovedCannotDraft() {
        var m = prepare(.none)
        m.accountID = "gone"
        m = MeetingActions.addRecipient(Attendee(name: "Jan", email: "jan@acme.be"), to: m, selfAddresses: [])
        #expect(MeetingActions.accountRemoved(m, accounts: accounts))
        #expect(!MeetingActions.canDraft(m, accounts: accounts))
        m.accountID = "other"
        #expect(!MeetingActions.accountRemoved(m, accounts: accounts))
        #expect(MeetingActions.canDraft(m, accounts: accounts))
        m.accountID = nil
        #expect(!MeetingActions.accountRemoved(m, accounts: accounts))
        #expect(MeetingActions.accountRemovedLabel == "Account removed — choose an account")
    }

    @Test func noEventToDraftable() {
        var m = prepare(.none)
        m.accountID = "work"
        m = MeetingActions.addRecipient(Attendee(name: "Jan", email: "jan@acme.be"), to: m, selfAddresses: ["me@example.com"])
        #expect(MeetingActions.canDraft(m, accounts: accounts))
    }

    @Test func addRecipientIgnoresSelfAndDuplicates() {
        var m = prepare(.none)
        let selves = ["me@example.com"]
        m = MeetingActions.addRecipient(Attendee(name: "Me", email: "ME@example.com"), to: m, selfAddresses: selves)
        #expect(m.recipients.isEmpty)
        m = MeetingActions.addRecipient(Attendee(name: "Jan", email: "jan@acme.be"), to: m, selfAddresses: selves)
        m = MeetingActions.addRecipient(Attendee(name: "Jan", email: "Jan@Acme.be"), to: m, selfAddresses: selves)
        #expect(m.recipients.count == 1)
    }
}
