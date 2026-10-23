import Foundation
import Testing
@testable import MuninnCore

@Suite struct CalendarTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func event(
        account: String = "a",
        id: String = "e1",
        uid: String? = nil,
        start: TimeInterval = 0,
        duration: TimeInterval = 3600,
        allDay: Bool = false,
        cancelled: Bool = false,
        attendees: [Attendee] = [],
        organizer: Attendee? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            accountID: account, eventID: id, iCalUID: uid, subject: "Sync",
            start: base.addingTimeInterval(start), end: base.addingTimeInterval(start + duration),
            isAllDay: allDay, isCancelled: cancelled, attendees: attendees, organizer: organizer
        )
    }

    @Test func singleMatch() {
        let e = event()
        #expect(EventMatcher.match([e], at: base.addingTimeInterval(60)) == .single(e))
        #expect(EventMatcher.match([e], at: base.addingTimeInterval(4000)) == .none)
        #expect(EventMatcher.match([], at: base) == .none)
    }

    @Test func earlyJoinWithin10Min() {
        let e = event()
        #expect(EventMatcher.match([e], at: base.addingTimeInterval(-600)) == .single(e))
        #expect(EventMatcher.match([e], at: base.addingTimeInterval(-601)) == .none)
    }

    @Test func allDayIgnored() {
        let allDay = event(id: "ad", allDay: true)
        let cancelled = event(id: "c", cancelled: true)
        #expect(EventMatcher.match([allDay, cancelled], at: base.addingTimeInterval(60)) == .none)
        let real = event(id: "r")
        #expect(EventMatcher.match([allDay, cancelled, real], at: base.addingTimeInterval(60)) == .single(real))
    }

    @Test func sameInviteBothAccountsIsAmbiguous() {
        let b = event(account: "b", uid: "uid")
        let a = event(account: "a", uid: "uid")
        #expect(EventMatcher.match([b, a], at: base.addingTimeInterval(60)) == .ambiguous([a, b]))
    }

    @Test func overlapIsAmbiguous() {
        let later = event(id: "later", start: 1800)
        let earlier = event(id: "earlier", start: 0)
        #expect(EventMatcher.match([later, earlier], at: base.addingTimeInterval(2000)) == .ambiguous([earlier, later]))
    }

    @Test func recipientsExcludeSelfCaseInsensitive() {
        let e = event(
            attendees: [
                Attendee(name: "Me", email: "Sam@Example.com"),
                Attendee(name: "Ann", email: "ann@example.com"),
                Attendee(name: "Bob", email: "bob@example.com"),
                Attendee(name: "Ann again", email: "ANN@example.com"),
                Attendee(name: "Org", email: "org@example.com"),
            ],
            organizer: Attendee(name: "Org", email: "Org@example.com")
        )
        let recipients = RecipientBuilder.recipients(for: e, selfAddresses: ["sam@example.com"])
        #expect(recipients.map(\.attendee.email) == ["Org@example.com", "ann@example.com", "bob@example.com"])
        #expect(recipients.allSatisfy { $0.included })
    }

    @Test func recipientsSkipSelfOrganizer() {
        let e = event(
            attendees: [Attendee(name: "Ann", email: "ann@example.com")],
            organizer: Attendee(name: "Me", email: "me@example.com")
        )
        let recipients = RecipientBuilder.recipients(for: e, selfAddresses: ["ME@example.com"])
        #expect(recipients.map(\.attendee.email) == ["ann@example.com"])
    }

    @Test func recipientsDropResourcesAndUntickDeclined() {
        let e = event(attendees: [
            Attendee(name: "Ann", email: "ann@example.com", type: "required", response: "accepted"),
            Attendee(name: "Room 4", email: "room4@example.com", type: "resource", response: "accepted"),
            Attendee(name: "Bob", email: "bob@example.com", type: "optional", response: "declined"),
            Attendee(name: "Cy", email: "cy@example.com", type: "required", response: "none"),
        ])
        let recipients = RecipientBuilder.recipients(for: e, selfAddresses: [])
        #expect(recipients.map(\.attendee.email) == ["ann@example.com", "bob@example.com", "cy@example.com"])
        #expect(recipients.map(\.included) == [true, false, true])
    }

    @Test func untitledTitle() {
        let zone = TimeZone(identifier: "Europe/Brussels")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let at = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 14, minute: 2))!
        #expect(RecipientBuilder.untitledTitle(appName: "Zoom", at: at, timeZone: zone) == "Zoom call, 14:02")
    }
}
