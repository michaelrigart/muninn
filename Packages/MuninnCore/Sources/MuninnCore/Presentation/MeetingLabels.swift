import Foundation

public enum DayGroup: String, CaseIterable, Sendable {
    case today, yesterday, thisWeek, earlier

    public var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .thisWeek: "This week"
        case .earlier: "Earlier"
        }
    }
}

public struct MeetingGroup: Identifiable {
    public let group: DayGroup
    public let meetings: [Meeting]

    public var id: DayGroup { group }
}

public enum MeetingGrouping {
    public static func group(of date: Date, now: Date, calendar: Calendar) -> DayGroup {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return .thisWeek }
        return .earlier
    }

    public static func groups(_ meetings: [Meeting], now: Date = Date(), calendar: Calendar = .current) -> [MeetingGroup] {
        var buckets: [DayGroup: [Meeting]] = [:]
        for meeting in meetings {
            buckets[group(of: meeting.startedAt, now: now, calendar: calendar), default: []].append(meeting)
        }
        return DayGroup.allCases.compactMap { group in
            buckets[group].map { MeetingGroup(group: group, meetings: $0) }
        }
    }
}

public enum Timestamp {
    /// Whole seconds, truncated: `mm:ss` under an hour, `h:mm:ss` from an hour; negative as zero.
    public static func format(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, rest) }
        return String(format: "%02d:%02d", minutes, rest)
    }
}

public enum MeetingLabels {
    public static func meta(start: Date, end: Date?, language: String?, calendar: Calendar, locale: Locale) -> String {
        var parts = [formatted(start, template: "EEEdMMMyyyy", calendar: calendar, locale: locale)]
        let startTime = formatted(start, template: "jmm", calendar: calendar, locale: locale)
        if let end, end > start {
            parts.append("\(startTime)–\(formatted(end, template: "jmm", calendar: calendar, locale: locale))")
            parts.append(DurationText.minutes(end.timeIntervalSince(start)))
        } else {
            parts.append(startTime)
        }
        if let language, let name = locale.localizedString(forLanguageCode: language) { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    public static func sidebarTime(start: Date, end: Date?, group: DayGroup, now: Date, calendar: Calendar, locale: Locale) -> String {
        let time = formatted(start, template: "jmm", calendar: calendar, locale: locale)
        var text: String
        switch group {
        case .today, .yesterday:
            text = time
        case .thisWeek:
            text = "\(formatted(start, template: "EEE", calendar: calendar, locale: locale)) \(time)"
        case .earlier:
            let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: now)
            text = "\(formatted(start, template: sameYear ? "dMMM" : "dMMMyyyy", calendar: calendar, locale: locale)) \(time)"
        }
        if let end, end > start { text += " · \(DurationText.minutes(end.timeIntervalSince(start)))" }
        return text
    }

    public static func detailsChip(accountName: String?, client: String?) -> String {
        let parts = [accountName, client].compactMap { $0 }
        return parts.isEmpty ? "Account and client" : parts.joined(separator: " · ")
    }

    private static func formatted(_ date: Date, template: String, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

public enum PersonLabel {
    public static func initials(name: String, email: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
        guard let first = words.first else { return email.first.map { String($0).uppercased() } ?? "" }
        guard let last = words.last, words.count > 1 else { return String(first.prefix(1)).uppercased() }
        return (String(first.prefix(1)) + String(last.prefix(1))).uppercased()
    }

    public static func shortName(name: String, email: String) -> String {
        if let first = name.split(whereSeparator: \.isWhitespace).first { return String(first) }
        return String(email.split(separator: "@", omittingEmptySubsequences: false).first ?? "")
    }
}
