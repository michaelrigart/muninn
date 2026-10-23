import Foundation

public enum MeetingPreparation {
    public static func prepare(
        startedAt: Date,
        mode: CaptureMode,
        appName: String?,
        match: EventMatch,
        accounts: [AccountSettings],
        clientDomains: [String: String],
        timeZone: TimeZone,
        existingIDs: Set<String>
    ) -> Meeting {
        var title = RecipientBuilder.untitledTitle(appName: appName ?? "Conversation", at: startedAt, timeZone: timeZone)
        if case .single(let event) = match { title = event.subject }
        var meeting = Meeting(
            id: MeetingID.make(startedAt: startedAt, title: title, timeZone: timeZone, existing: existingIDs),
            title: title,
            startedAt: startedAt,
            endedAt: nil,
            captureMode: mode,
            language: nil,
            accountID: nil,
            association: nil,
            client: nil,
            candidateEvents: [],
            attendees: [],
            recipients: [],
            flags: [],
            speakerNames: [:],
            status: .recording,
            summaryEngine: nil,
            engineNotice: nil,
            exportedNotePath: nil,
            draftWebLink: nil,
            metrics: ProcessingMetrics(),
            timeZone: timeZone.identifier
        )
        switch match {
        case .none:
            break
        case .single(let event):
            meeting = apply(event, to: meeting, accounts: accounts, clientDomains: clientDomains)
        case .ambiguous(let events):
            meeting.candidateEvents = events.map {
                CalendarEventRef(accountID: $0.accountID, eventID: $0.eventID, subject: $0.subject, start: $0.start)
            }
        }
        return meeting
    }

    public static func choose(_ event: CalendarEvent, for m: Meeting, accounts: [AccountSettings], clientDomains: [String: String]) -> Meeting {
        var result = apply(event, to: m, accounts: accounts, clientDomains: clientDomains)
        result.candidateEvents = []
        return result
    }

    private static func apply(_ event: CalendarEvent, to m: Meeting, accounts: [AccountSettings], clientDomains: [String: String]) -> Meeting {
        var seen = Set<String>()
        let selfAddresses = accounts.flatMap(\.selfAddresses).filter { seen.insert($0.lowercased()).inserted }
        var result = m
        result.title = event.subject
        result.attendees = attendees(of: event)
        result.recipients = RecipientBuilder.recipients(for: event, selfAddresses: selfAddresses)
        result.accountID = event.accountID
        result.association = EventAssociation(accountID: event.accountID, eventID: event.eventID, iCalUID: event.iCalUID)
        result.client = ClientMapper.client(
            for: [event.organizer].compactMap { $0 } + event.attendees,
            domains: clientDomains,
            selfAddresses: selfAddresses
        )
        return result
    }

    /// The event's people with the organizer first; a client-organized call otherwise misses its main contact.
    private static func attendees(of event: CalendarEvent) -> [Attendee] {
        var people = event.attendees.filter { !$0.isResource }
        if let organizer = event.organizer, !organizer.isResource, !organizer.email.isEmpty,
           !people.contains(where: { $0.email.lowercased() == organizer.email.lowercased() }) {
            people.insert(organizer, at: 0)
        }
        return people
    }
}
