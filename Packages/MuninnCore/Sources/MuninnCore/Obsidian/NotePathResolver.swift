import Foundation

enum DayFormat {
    static func string(from date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

public enum NotePathResolver {
    /// A note goes to the inbox only when a placeholder the pattern uses has no value: `{client}` without a client, `{area}` without an area.
    public static func relativePath(pattern: String, area: String, client: String?, date: Date, title: String, inbox: String, timeZone: TimeZone) -> String {
        let day = DayFormat.string(from: date, timeZone: timeZone)
        var safeTitle = sanitize(title)
        if safeTitle.isEmpty { safeTitle = "Meeting" }
        let safeClient = client.map(sanitize) ?? ""
        let safeArea = sanitize(area)
        let missingClient = pattern.contains("{client}") && safeClient.isEmpty
        let missingArea = pattern.contains("{area}") && safeArea.isEmpty
        if missingClient || missingArea {
            return "\(inbox)/\(day) \(safeTitle).md"
        }
        let values = ["area": safeArea, "client": safeClient, "date": day, "title": safeTitle]
        var result = ""
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let afterOpen = rest.index(after: open)
            if let close = rest[afterOpen...].firstIndex(of: "}"), let value = values[String(rest[afterOpen..<close])] {
                result += value
                rest = rest[rest.index(after: close)...]
            } else {
                result += "{"
                rest = rest[afterOpen...]
            }
        }
        return result + rest
    }

    public static func sanitize(_ title: String) -> String {
        let forbidden = Set("/\\:*?\"<>|{}")
        var text = String(title.filter { !forbidden.contains($0) })
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var previous: String
        repeat {
            previous = text
            while text.hasPrefix(".") { text.removeFirst() }
            text = String(text.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        } while text != previous
        return text
    }
}
