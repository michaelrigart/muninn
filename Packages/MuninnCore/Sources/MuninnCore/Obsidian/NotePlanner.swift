import Foundation

/// The pure decisions behind filing a meeting into the vault.
public enum NotePlanner {
    /// The vault area of an account: its configured area, else its display name; no account gives an empty area.
    public static func area(for account: AccountSettings?) -> String {
        guard let account else { return "" }
        return account.vaultArea.isEmpty ? account.displayName : account.vaultArea
    }

    public static func relativePath(meeting: Meeting, settings: Settings, timeZone: TimeZone) -> String {
        let account = meeting.accountID.flatMap { id in settings.accounts.first { $0.id == id } }
        return NotePathResolver.relativePath(
            pattern: settings.notePattern, area: area(for: account), client: meeting.client, date: meeting.startedAt,
            title: meeting.title, inbox: settings.inboxFolder, timeZone: timeZone
        )
    }

    /// The client's own note plus the most recent earlier exported meeting with the same client.
    public static func relatedNotes(for meeting: Meeting, among meetings: [Meeting]) -> [String] {
        guard let client = meeting.client else { return [] }
        var related = [client]
        let earlier = meetings
            .filter { $0.id != meeting.id && $0.startedAt < meeting.startedAt && $0.exportedNotePath != nil }
            .filter { $0.client?.lowercased() == client.lowercased() }
            .max { $0.startedAt < $1.startedAt }
        if let path = earlier?.exportedNotePath {
            related.append(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
        }
        return related
    }

    /// The clean transcript when there is one, else the raw one, without the title line the note already has.
    public static func transcriptBody(clean: String?, raw: String?) -> String? {
        guard let text = clean ?? raw else { return nil }
        var lines = text.components(separatedBy: "\n")
        if lines.first?.hasPrefix("# ") == true {
            lines.removeFirst()
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }
}
