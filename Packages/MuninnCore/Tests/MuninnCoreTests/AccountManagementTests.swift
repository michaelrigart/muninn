import Foundation
import Testing
@testable import MuninnCore

struct AccountManagementTests {
    @Test(arguments: [
        ("Work", "work"),
        ("Acme Corp.", "acme-corp"),
        ("  Café  Münster / Nord ", "cafe-munster-nord"),
        ("日本", "account"),
        ("", "account"),
        ("--A--b--", "a-b"),
        ("Client 2", "client-2"),
    ])
    func idsAreLowercasedAsciiHyphenated(name: String, expected: String) {
        #expect(AccountManagement.makeID(displayName: name, existing: []) == expected)
    }

    @Test func idsAreUnique() {
        #expect(AccountManagement.makeID(displayName: "Work", existing: ["work"]) == "work-2")
        #expect(AccountManagement.makeID(displayName: "Work", existing: ["work", "work-2"]) == "work-3")
        #expect(AccountManagement.makeID(displayName: "Other", existing: ["work"]) == "other")
    }

    @Test func aRemovedAccountsIDIsNeverReused() {
        let work = AccountSettings(id: "work", displayName: "Work", vaultArea: "Work", tenant: "organizations", clientID: "", selfAddresses: [])
        let stale = meeting("a", account: "acme", status: .ready)
        #expect(AccountManagement.newID(displayName: "Acme", accounts: [work], meetings: [stale]) == "acme-2")
        #expect(AccountManagement.newID(displayName: "Acme", accounts: [work], meetings: []) == "acme")
        #expect(AccountManagement.newID(displayName: "Work", accounts: [work], meetings: [meeting("b", account: nil, status: .ready)]) == "work-2")
        let twice = [stale, meeting("c", account: "acme-2", status: .ready)]
        #expect(AccountManagement.newID(displayName: "Acme", accounts: [], meetings: twice) == "acme-3")
    }

    @Test func idsStoredMeetingsReferenceInAnyWayAreNeverReused() {
        let ref = CalendarEventRef(accountID: "acme", eventID: "e1", subject: "Sync", start: Date(timeIntervalSince1970: 0))
        var candidateOnly = meeting("a", account: nil, status: .ready)
        candidateOnly.candidateEvents = [ref]
        #expect(AccountManagement.newID(displayName: "Acme", accounts: [], meetings: [candidateOnly]) == "acme-2")
        var associated = meeting("b", account: nil, status: .ready)
        associated.association = EventAssociation(accountID: "globex", eventID: "e2", iCalUID: nil)
        #expect(AccountManagement.newID(displayName: "Globex", accounts: [], meetings: [associated]) == "globex-2")
    }

    @Test func aRetiredIDIsNeverGivenBackWhateverTheMeetings() {
        let work = AccountSettings(id: "work", displayName: "Work", vaultArea: "Work", tenant: "organizations", clientID: "", selfAddresses: [])
        #expect(AccountManagement.newID(displayName: "Acme", accounts: [work], retired: ["acme"], meetings: []) == "acme-2")
        #expect(AccountManagement.newID(displayName: "Acme", accounts: [work], retired: ["acme", "acme-2"], meetings: []) == "acme-3")
    }

    @Test func removingAnAccountRetiresItsID() {
        var settings = Settings.defaults
        settings.accounts.append(AccountSettings(id: "acme", displayName: "Acme", vaultArea: "Acme", tenant: "organizations", clientID: "", selfAddresses: []))
        AccountManagement.remove("acme", from: &settings)
        #expect(settings.accounts.map(\.id) == ["work"])
        #expect(settings.retiredAccountIDs == ["acme"])
        let readded = AccountManagement.newID(displayName: "Acme", accounts: settings.accounts, retired: settings.retiredAccountIDs, meetings: [])
        #expect(readded == "acme-2")
        AccountManagement.remove("acme", from: &settings)
        #expect(settings.retiredAccountIDs == ["acme"])
    }

    private func meeting(_ id: String, account: String?, status: ProcessingStatus) -> Meeting {
        Meeting(
            id: MeetingID(rawValue: id), title: "Sync", startedAt: Date(timeIntervalSince1970: 0), endedAt: nil,
            captureMode: .micOnly, language: "en", accountID: account, association: nil, client: nil,
            candidateEvents: [], attendees: [], recipients: [], flags: [], speakerNames: [:], status: status,
            summaryEngine: nil, engineNotice: nil, exportedNotePath: nil, draftWebLink: nil, metrics: ProcessingMetrics()
        )
    }

    @Test func removalIsBlockedByRecordingOrProcessingMeetingsOfThatAccount() {
        let meetings = [
            meeting("a", account: "work", status: .recording),
            meeting("b", account: "work", status: .summarizing),
            meeting("c", account: "other", status: .transcribing),
            meeting("d", account: "work", status: .ready),
            meeting("e", account: "work", status: .waiting(.studioNotConfigured)),
            meeting("f", account: "work", status: .failed("x")),
            meeting("g", account: nil, status: .recording),
        ]
        #expect(AccountManagement.busyMeetings(for: "work", in: meetings).map(\.id.rawValue) == ["a", "b"])
        #expect(AccountManagement.busyMeetings(for: "other", in: meetings).map(\.id.rawValue) == ["c"])
        #expect(AccountManagement.busyMeetings(for: "none", in: meetings).isEmpty)
        #expect(AccountManagement.busyMeetings(for: "work", in: Array(meetings[3...])).isEmpty)
    }

    @Test func refusalNamesTheAccount() {
        #expect(AccountManagement.removalRefusal(accountName: "Work") == "Work can't be removed while a meeting for it is recording or being processed.")
    }
}
