import Foundation

public enum EmailRecipients {
    private static let pattern = #"\A[^\s@,;:<>"()\[\]\\]+@[^\s@,;:<>"()\[\]\\]+\.[^\s@,;:<>"()\[\]\\]+\z"#
    private static let needsQuotes = CharacterSet(charactersIn: ",;:<>@\"()[]\\.")

    /// Exactly one "@", a dot in the domain, no whitespace, none of , ; : < > " ( ) [ ] \
    public static func isValidAddress(_ address: String) -> Bool {
        address.range(of: pattern, options: .regularExpression) != nil
    }

    /// The typed text, trimmed, as a recipient without a name; nil unless it is a valid address.
    public static func typedAddress(_ text: String) -> Attendee? {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidAddress(address) ? Attendee(name: "", email: address) : nil
    }

    /// The ticked recipients, in list order, as "Name <address>" or "address", joined by ", ".
    public static func line(_ recipients: [Recipient]) -> String {
        recipients.filter(\.included).map { recipient in
            let address = recipient.attendee.email
            let name = recipient.attendee.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { return address }
            guard name.rangeOfCharacter(from: needsQuotes) != nil else { return "\(name) <\(address)>" }
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\" <\(address)>"
        }.joined(separator: ", ")
    }
}
