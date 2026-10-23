import Foundation

public enum AccountManagement {
    /// An account ID from its display name: lowercased ASCII words joined by hyphens, made unique among `existing`.
    public static func makeID(displayName: String, existing: [String]) -> String {
        let folded = displayName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var base = ""
        var pendingHyphen = false
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingHyphen, !base.isEmpty { base.append("-") }
                pendingHyphen = false
                base.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }
        if base.isEmpty { base = "account" }
        let taken = Set(existing)
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// A new account's ID: unique against every current account, every retired ID and every account ID a stored meeting
    /// still references (its account, its event association or a candidate event), so a removed account's ID is never
    /// given to a different account.
    public static func newID(displayName: String, accounts: [AccountSettings], retired: [String] = [], meetings: [Meeting]) -> String {
        let referenced = meetings.flatMap { meeting in
            [meeting.accountID, meeting.association?.accountID].compactMap { $0 } + meeting.candidateEvents.map(\.accountID)
        }
        return makeID(displayName: displayName, existing: accounts.map(\.id) + retired + referenced)
    }

    /// Removes an account and retires its ID.
    public static func remove(_ accountID: String, from settings: inout Settings) {
        settings.accounts.removeAll { $0.id == accountID }
        if !settings.retiredAccountIDs.contains(accountID) { settings.retiredAccountIDs.append(accountID) }
    }

    /// The meetings that keep an account from being removed: those recording or being processed for it.
    public static func busyMeetings(for accountID: String, in meetings: [Meeting]) -> [Meeting] {
        meetings.filter { $0.accountID == accountID && !MeetingActions.canDelete($0) }
    }

    public static func removalRefusal(accountName: String) -> String {
        "\(accountName) can't be removed while a meeting for it is recording or being processed."
    }
}
