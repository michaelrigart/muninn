import Foundation

public enum EventMatch: Equatable, Sendable {
    case none
    case single(CalendarEvent)
    case ambiguous([CalendarEvent])
}

public enum EventMatcher {
    public static func match(_ events: [CalendarEvent], at: Date, earlyJoin: TimeInterval = 600) -> EventMatch {
        let candidates = events
            .filter { !$0.isAllDay && !$0.isCancelled && $0.start.addingTimeInterval(-earlyJoin) <= at && at <= $0.end }
            .sorted { ($0.start, $0.accountID) < ($1.start, $1.accountID) }
        switch candidates.count {
        case 0: return .none
        case 1: return .single(candidates[0])
        default: return .ambiguous(candidates)
        }
    }
}
