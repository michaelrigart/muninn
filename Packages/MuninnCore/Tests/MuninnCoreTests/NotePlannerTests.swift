import Foundation
import Testing
@testable import MuninnCore

struct NotePlannerTests {
    private let utc = TimeZone(identifier: "UTC")!

    private func meeting(_ id: String, client: String? = "Acme", at seconds: TimeInterval = 1_792_000_000, exported: String? = nil) -> Meeting {
        Meeting(
            id: MeetingID(rawValue: id), title: "Sync", startedAt: Date(timeIntervalSince1970: seconds), endedAt: nil,
            captureMode: .micOnly, language: "en", accountID: "work", association: nil, client: client,
            candidateEvents: [], attendees: [], recipients: [], flags: [], speakerNames: [:], status: .ready,
            summaryEngine: nil, engineNotice: nil, exportedNotePath: exported, draftWebLink: nil, metrics: ProcessingMetrics()
        )
    }

    private func account(area: String) -> AccountSettings {
        AccountSettings(id: "work", displayName: "Work Ltd", vaultArea: area, tenant: "organizations", clientID: "c", selfAddresses: [])
    }

    @Test func areaFallsBackToDisplayNameAndInbox() {
        #expect(NotePlanner.area(for: account(area: "Work")) == "Work")
        #expect(NotePlanner.area(for: account(area: "")) == "Work Ltd")
        #expect(NotePlanner.area(for: nil) == "")
    }

    @Test func pathUsesTheAccountAreaAndFallsBackToTheInbox() {
        var settings = Settings.defaults
        settings.accounts = [account(area: "")]
        let filed = NotePlanner.relativePath(meeting: meeting("a"), settings: settings, timeZone: utc)
        #expect(filed == "Meetings/Acme/2026-10-14 Sync.md")
        settings.notePattern = "{area}/Clients/{client}/Meetings/{date} {title}.md"
        #expect(NotePlanner.relativePath(meeting: meeting("a"), settings: settings, timeZone: utc) == "Work Ltd/Clients/Acme/Meetings/2026-10-14 Sync.md")

        var noAccount = meeting("a")
        noAccount.accountID = nil
        #expect(NotePlanner.relativePath(meeting: noAccount, settings: settings, timeZone: utc) == "Inbox/2026-10-14 Sync.md")
        #expect(NotePlanner.relativePath(meeting: meeting("a", client: nil), settings: settings, timeZone: utc) == "Inbox/2026-10-14 Sync.md")
    }

    @Test func defaultPatternFilesANoteWithoutAnAccountUnderItsClient() {
        let settings = Settings.defaults
        var noAccount = meeting("a")
        noAccount.accountID = nil
        #expect(NotePlanner.relativePath(meeting: noAccount, settings: settings, timeZone: utc) == "Meetings/Acme/2026-10-14 Sync.md")
        var removed = meeting("a")
        removed.accountID = "gone"
        #expect(NotePlanner.relativePath(meeting: removed, settings: settings, timeZone: utc) == "Meetings/Acme/2026-10-14 Sync.md")
        #expect(NotePlanner.relativePath(meeting: meeting("a", client: nil), settings: settings, timeZone: utc) == "Inbox/2026-10-14 Sync.md")
    }

    @Test func aPatternWithAreaSendsANoteWithoutAnAccountToTheInbox() {
        var settings = Settings.defaults
        settings.notePattern = "{area}/{client}/{date} {title}.md"
        var noAccount = meeting("a")
        noAccount.accountID = nil
        #expect(NotePlanner.relativePath(meeting: noAccount, settings: settings, timeZone: utc) == "Inbox/2026-10-14 Sync.md")
    }

    @Test func aPatternWithoutClientFilesANoteWithoutOne() {
        var settings = Settings.defaults
        settings.notePattern = "Meetings/{date} {title}.md"
        #expect(NotePlanner.relativePath(meeting: meeting("a", client: nil), settings: settings, timeZone: utc) == "Meetings/2026-10-14 Sync.md")
    }

    @Test func relatedNotesAreTheClientAndTheLatestEarlierExport() {
        let current = meeting("now", at: 3_000)
        let all = [
            current,
            meeting("old", at: 1_000, exported: "Work/Clients/Acme/Meetings/2026-01-01 Old.md"),
            meeting("recent", at: 2_000, exported: "Work/Clients/Acme/Meetings/2026-02-01 Recent.md"),
            meeting("unexported", at: 2_500),
            meeting("other", client: "Other", at: 2_800, exported: "x/Other.md"),
            meeting("later", at: 4_000, exported: "x/Later.md"),
        ]
        #expect(NotePlanner.relatedNotes(for: current, among: all) == ["Acme", "2026-02-01 Recent"])
        #expect(NotePlanner.relatedNotes(for: meeting("solo", at: 500), among: [meeting("solo", at: 500)]) == ["Acme"])
        #expect(NotePlanner.relatedNotes(for: meeting("none", client: nil), among: all).isEmpty)
    }

    @Test func clientMatchIgnoresCase() {
        let current = meeting("now", client: "ACME", at: 3_000)
        let earlier = meeting("old", client: "acme", at: 1_000, exported: "a/Old note.md")
        #expect(NotePlanner.relatedNotes(for: current, among: [current, earlier]) == ["ACME", "Old note"])
    }

    @Test func transcriptBodyPrefersCleanAndDropsTheTitle() {
        #expect(NotePlanner.transcriptBody(clean: "# T\n\n**[00:01] A:** clean\n", raw: "# T\n\n**[00:01] A:** raw\n") == "**[00:01] A:** clean")
        #expect(NotePlanner.transcriptBody(clean: nil, raw: "# T\n\nraw line") == "raw line")
        #expect(NotePlanner.transcriptBody(clean: nil, raw: nil) == nil)
        #expect(NotePlanner.transcriptBody(clean: "# T\n\n", raw: "# T\n\nraw") == nil)
        #expect(NotePlanner.transcriptBody(clean: "no title line", raw: nil) == "no title line")
    }
}
