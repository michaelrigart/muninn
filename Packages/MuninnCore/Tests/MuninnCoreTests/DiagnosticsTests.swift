import Foundation
import Testing
@testable import MuninnCore

struct DiagnosticsTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let meetingID = "2026-11-03-1400-quarterly-review"

    private func settings(accounts: [AccountSettings]? = nil, studioURL: String = "http://studio.secret-lab.local:11434") -> Settings {
        var settings = Settings.defaults
        settings.studio.baseURL = studioURL
        settings.accounts = accounts ?? [
            AccountSettings(id: "acme", displayName: "Acme Corp", vaultArea: "Acme", tenant: "organizations", clientID: "", selfAddresses: ["me@acme.example"]),
        ]
        return settings
    }

    private func input(
        settings: Settings,
        entries: [ActivityEntry] = [],
        permissions: [PermissionReport] = [],
        home: String = "/Users/tester"
    ) -> DiagnosticsInput {
        DiagnosticsInput(
            system: SystemInfo(appVersion: "1.2 (3)", osVersion: "26.1"),
            macClass: "Mac15,6",
            settings: settings,
            permissions: permissions,
            entries: entries,
            homeDirectory: home
        )
    }

    private func entry(_ message: String, meeting: ActivityMeeting? = nil, at time: Date = DiagnosticsTests.now, details: ProblemDetails? = nil) -> ActivityEntry {
        ActivityEntry(time: time, level: .problem, area: .recap, meeting: meeting, message: message, details: details)
    }

    private let quarterly = ActivityMeeting(id: MeetingID(rawValue: DiagnosticsTests.meetingID), title: SEED)

    @Test func diagnosticsLeakNothingSeeded() {
        let details = ProblemDetails(
            request: RequestFacts(method: "GET", path: "/Users/tester/.local/share/muninn/meetings/\(Self.meetingID)/summary.json", host: "studio.secret-lab.local"),
            account: "Acme Corp"
        )
        let entries = [
            entry("Sign-in to Acme Corp expired", meeting: quarterly, details: details),
            entry("Draft for ann@client.example failed"),
            entry("token sk-ant-api03-SECRETSECRETSECRET"),
        ]
        let text = Diagnostics.text(input(settings: settings(), entries: entries))
        for secret in ["Henderson", "quarterly-review", "Acme Corp", "me@acme.example", "ann@client.example", "studio.secret-lab.local", "sk-ant-", "SECRETSECRET", "/Users/tester"] {
            #expect(!text.contains(secret), "\(secret)")
        }
        for label in ["meeting A", "account 1", "<email>", "~/.local/share/muninn/meetings/meeting A/summary.json"] {
            #expect(text.contains(label), "\(label)")
        }
    }

    @Test func sameMeetingGetsTheSameLabel() {
        let other = ActivityMeeting(id: MeetingID(rawValue: "2026-11-04-0900-standup"), title: "Standup")
        let entries = [
            entry("first", meeting: quarterly, at: Self.now),
            entry("second", meeting: other, at: Self.now.addingTimeInterval(-1)),
            entry("third", meeting: quarterly, at: Self.now.addingTimeInterval(-2)),
        ]
        let text = Diagnostics.text(input(settings: settings(), entries: entries))
        #expect(text.components(separatedBy: "meeting A").count - 1 == 2)
        #expect(text.components(separatedBy: "meeting B").count - 1 == 1)
        #expect(!text.contains("Standup") && !text.contains("standup"))
    }

    @Test func onlyTheLast200Entries() {
        let entries = (0..<250).map { entry("entry \($0)", at: Self.now.addingTimeInterval(Double(-$0))) }
        let text = Diagnostics.text(input(settings: settings(), entries: entries))
        #expect(text.contains("Activity (last 200 entries, newest first)"))
        #expect(text.components(separatedBy: " · problem · Recap · entry ").count - 1 == 200)
        #expect(text.contains("entry 0") && text.contains("entry 199") && !text.contains("entry 200"))
    }

    @Test func entriesComeNewestFirstWhateverTheInputOrder() throws {
        let entries = [entry("older", at: Self.now.addingTimeInterval(-60)), entry("newer", at: Self.now)]
        let text = Diagnostics.text(input(settings: settings(), entries: entries))
        let newer = try #require(text.range(of: "newer"))
        let older = try #require(text.range(of: "older"))
        #expect(newer.lowerBound < older.lowerBound)
    }

    @Test func entryLinesCarryTimeLevelAreaAndDetails() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let details = ProblemDetails(request: RequestFacts(method: "POST", path: "/v1/messages", host: "api.anthropic.com"), httpStatus: 529)
        let text = Diagnostics.text(input(settings: settings(), entries: [entry("Claude is busy", details: details)]))
        #expect(text.contains("\(formatter.string(from: Self.now)) · problem · Recap · Claude is busy\n    Request: POST /v1/messages\n    HTTP status: 529"))
    }

    @Test func engineSectionShowsSchemeAndPortOnly() {
        var configured = settings(studioURL: "not a url")
        configured.studio.model = "gpt-oss:20b"
        configured.macbook.model = "qwen3:8b"
        let text = Diagnostics.text(input(settings: configured))
        #expect(text.contains("Muninn diagnostics\nMuninn 1.2 (3) · macOS 26.1 · Mac15,6\n\nEngines\nDefault engine: This Mac\n"))
        #expect(text.contains("This Mac: Ollama · model qwen3:8b · address http, port 11434"))
        #expect(text.contains("Network Mac: Ollama · model gpt-oss:20b · no address"))
        #expect(text.contains("Claude: model \(configured.claudeModel) · effort \(configured.claudeEffort)"))
        #expect(text.contains("LLM cleanup: off"))
        #expect(!text.contains("127.0.0.1"))
    }

    @Test func aSchemeWithoutAPortUsesTheDefaultPort() {
        var configured = settings(studioURL: "https://studio.example")
        configured.studio.api = .openAICompatible
        let text = Diagnostics.text(input(settings: configured))
        #expect(text.contains("Network Mac: OpenAI-compatible server · model gpt-oss:20b · address https, port 443"))
    }

    @Test func permissionsAreListed() {
        let permissions = [PermissionReport(name: "Microphone", state: "granted"), PermissionReport(name: "System Audio Recording", state: "not reported by macOS")]
        let text = Diagnostics.text(input(settings: settings(), permissions: permissions))
        #expect(text.contains("Permissions\nMicrophone: granted\nSystem Audio Recording: not reported by macOS\n"))
    }

    @Test func accountIdsAreMaskedAsWholeWordsOnly() {
        let work = [AccountSettings(id: "work", displayName: "Contoso", vaultArea: "Work", tenant: "organizations", clientID: "", selfAddresses: [])]
        let text = Diagnostics.text(input(settings: settings(accounts: work), entries: [entry("Network Mac is busy; the work account is signed out")]))
        #expect(text.contains("Network Mac is busy; the account 1 account is signed out"))
        #expect(text.contains("Network Mac: "))
    }

    @Test func accountNamesAreCaseSensitive() {
        let work = [AccountSettings(id: "work", displayName: "Contoso", vaultArea: "Work", tenant: "organizations", clientID: "", selfAddresses: [])]
        let text = Diagnostics.text(input(settings: settings(accounts: work), entries: [entry("Work item for contoso")]))
        #expect(text.contains("Work item for contoso"))
    }

    @Test func renamedAndRemovedAccountsAreMasked() {
        let current = [AccountSettings(id: "acme", displayName: "Acme Corp", vaultArea: "Acme", tenant: "organizations", clientID: "", selfAddresses: [])]
        let entries = [
            entry("Sign-in to Acme Corp expired", details: ProblemDetails(account: "Acme Corp")),
            entry("Signed in to Old Name", details: ProblemDetails(account: "Old Name")),
            entry("Signed in to Removed Ltd", details: ProblemDetails(account: "Removed Ltd")),
        ]
        let text = Diagnostics.text(input(settings: settings(accounts: current), entries: entries))
        #expect(!text.contains("Acme Corp") && !text.contains("Old Name") && !text.contains("Removed Ltd"))
        #expect(text.contains("Sign-in to account 1 expired"))
        #expect(text.contains("Signed in to account 2"))
        #expect(text.contains("Signed in to account 3"))
        #expect(text.contains("Account: account 1") && text.contains("Account: account 2") && text.contains("Account: account 3"))
    }

    @Test func addressesAndHostsAreMasked() {
        let entries = [
            entry("Could not reach 192.168.1.20 or studio.secret-lab.local"),
            entry("Home is /Users/tester/Documents"),
        ]
        let text = Diagnostics.text(input(settings: settings(), entries: entries))
        #expect(text.contains("Could not reach <host> or <host>"))
        #expect(text.contains("Home is ~/Documents"))
    }

    @Test func aHomeDirectoryIsOnlyMatchedAsAWholePath() {
        let text = Diagnostics.text(input(settings: settings(), entries: [entry("/Users/tester2/file")]))
        #expect(text.contains("/Users/tester2/file"))
    }

    @Test func aLongKeyLikeStringIsRedacted() {
        let text = Diagnostics.text(input(settings: settings(), entries: [entry("key sk-abcdefghijklmnopqrstuvwxyz0123456789")]))
        #expect(!text.contains("abcdefghijkl") && text.contains(Redaction.marker))
    }
}
