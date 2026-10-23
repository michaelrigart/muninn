import Foundation

public struct CalendarEvent: Codable, Hashable, Sendable {
    public var accountID: String
    public var eventID: String
    public var iCalUID: String?
    public var subject: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var isCancelled: Bool
    public var attendees: [Attendee]
    public var organizer: Attendee?

    public init(
        accountID: String,
        eventID: String,
        iCalUID: String?,
        subject: String,
        start: Date,
        end: Date,
        isAllDay: Bool,
        isCancelled: Bool,
        attendees: [Attendee],
        organizer: Attendee?
    ) {
        self.accountID = accountID
        self.eventID = eventID
        self.iCalUID = iCalUID
        self.subject = subject
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isCancelled = isCancelled
        self.attendees = attendees
        self.organizer = organizer
    }
}
