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

    public struct Item: Equatable, Sendable {
        public var owner: String?
        public var text: String

        public init(owner: String?, text: String) {
            self.owner = owner
            self.text = text
        }
    }

    public struct Section: Equatable, Sendable {
        public var title: String
        public var items: [Item]

        public init(title: String, items: [Item]) {
            self.title = title
            self.items = items
        }
    }

    public struct Content: Equatable, Sendable {
        public var greeting: String
        public var intro: String
        public var sections: [Section]
        public var closing: String

        public init(greeting: String, intro: String, sections: [Section], closing: String) {
            self.greeting = greeting
            self.intro = intro
            self.sections = sections
            self.closing = closing
        }
    }

    /// One section per subject (its bullets, owner nil), then the actions section: the language's heading, and each
    /// subject's actions in order, owner resolved through speakerNames, text with " (dd/MM)" when the due date is valid.
    public static func content(summary: Summary, speakerNames: [String: String]) -> Content {
        let copy = copy(for: summary.language)
        var sections = summary.subjects.map { subject in
            Section(title: subject.title, items: subject.bullets.map { Item(owner: nil, text: $0.text) })
        }
        let actions = summary.subjects.flatMap(\.actions).map { action in
            var text = action.text
            if let due = action.due, let formatted = dueDate(due) {
                text += " (\(formatted))"
            }
            return Item(owner: speakerNames[action.owner] ?? action.owner, text: text)
        }
        sections.append(Section(title: copy.actionsHeading, items: actions))
        return Content(greeting: copy.greeting, intro: copy.intro, sections: sections, closing: copy.closing)
    }

    public static func html(summary: Summary, speakerNames: [String: String]) -> String {
        let content = content(summary: summary, speakerNames: speakerNames)
        var out = [
            "<p>\(escape(content.greeting))</p>",
            "<p>\(escape(content.intro))</p>",
        ]
        for section in content.sections {
            out.append("<h3>\(escape(section.title))</h3>")
            out.append("<ul>")
            for item in section.items {
                let text = escape(item.text)
                out.append(item.owner.map { "<li><b>\(escape($0))</b>: \(text)</li>" } ?? "<li>\(text)</li>")
            }
            out.append("</ul>")
        }
        out.append("<p>\(escape(content.closing))</p>")
        return out.joined(separator: "\n")
    }

    public static func plainText(summary: Summary, speakerNames: [String: String]) -> String {
        let content = content(summary: summary, speakerNames: speakerNames)
        var blocks = [content.greeting, content.intro]
        for section in content.sections {
            let lines = section.items.map { item in
                "- " + (item.owner.map { "\($0): \(item.text)" } ?? item.text)
            }
            blocks.append(([section.title] + lines).joined(separator: "\n"))
        }
        blocks.append(content.closing)
        return blocks.joined(separator: "\n\n")
    }

    public static func htmlDocument(summary: Summary, speakerNames: [String: String]) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        </head>
        <body>
        \(html(summary: summary, speakerNames: speakerNames))
        </body>
        </html>
        """
    }

    /// A due date as the email shows it (dd/MM), or nil when `iso` is not a valid yyyy-MM-dd date.
    public static func dueDate(_ iso: String) -> String? {
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
