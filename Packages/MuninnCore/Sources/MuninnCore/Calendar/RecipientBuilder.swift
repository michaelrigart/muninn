import Foundation

public enum RecipientBuilder {
    public static func recipients(for event: CalendarEvent, selfAddresses: [String]) -> [Recipient] {
        var seen = Set(selfAddresses.map { $0.lowercased() })
        var result: [Recipient] = []
        for attendee in [event.organizer].compactMap({ $0 }) + event.attendees {
            guard !attendee.isResource, seen.insert(attendee.email.lowercased()).inserted else { continue }
            result.append(Recipient(attendee: attendee, included: !attendee.hasDeclined))
        }
        return result
    }

    public static func untitledTitle(appName: String, at: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return "\(appName) call, \(formatter.string(from: at))"
    }
}
