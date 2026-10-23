import Foundation

public enum RecapEmail {
    private struct Copy {
        let greeting: String
        let intro: String
        let actionsHeading: String
        let closing: String
    }

    private static func copy(for language: String) -> Copy {
        switch language {
        case "nl":
            Copy(
                greeting: "Hallo allemaal,",
                intro: "Bedankt voor het gesprek. Hieronder de samenvatting en de volgende stappen.",
                actionsHeading: "Actiepunten",
                closing: "Met vriendelijke groeten,"
            )
        case "fr":
            Copy(
                greeting: "Bonjour à tous,",
                intro: "Merci pour l'échange. Voici le résumé et les prochaines étapes.",
                actionsHeading: "Points d'action",
                closing: "Cordialement,"
            )
        default:
            Copy(
                greeting: "Hi all,",
                intro: "Thanks for today. Here are the summary and next steps.",
                actionsHeading: "Action points",
                closing: "Best regards,"
            )
        }
    }

    public static func subject(title: String, date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "dd/MM/yyyy"
        return "Recap: \(title), \(formatter.string(from: date))"
    }

    public static func html(summary: Summary, speakerNames: [String: String]) -> String {
        let copy = copy(for: summary.language)
        var out = [
            "<p>\(escape(copy.greeting))</p>",
            "<p>\(escape(copy.intro))</p>",
        ]
        for subject in summary.subjects {
            out.append("<h3>\(escape(subject.title))</h3>")
            out.append("<ul>")
            for bullet in subject.bullets {
                out.append("<li>\(escape(bullet.text))</li>")
            }
            out.append("</ul>")
        }
        let actions = summary.subjects.flatMap(\.actions)
        out.append("<h3>\(escape(copy.actionsHeading))</h3>")
        out.append("<ul>")
        for action in actions {
            let owner = speakerNames[action.owner] ?? action.owner
            var line = "<b>\(escape(owner))</b>: \(escape(action.text))"
            if let due = action.due, let formatted = dueDate(due) {
                line += " (\(formatted))"
            }
            out.append("<li>\(line)</li>")
        }
        out.append("</ul>")
        out.append("<p>\(escape(copy.closing))</p>")
        return out.joined(separator: "\n")
    }

    private static func dueDate(_ iso: String) -> String? {
        let parts = iso.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        return "\(parts[2])/\(parts[1])"
    }

    private static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }
}
