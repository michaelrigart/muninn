import Foundation
import Testing
@testable import MuninnCore

struct ObsidianTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let pattern = "{area}/Clients/{client}/Meetings/{date} {title}.md"

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func meeting() -> Meeting {
        Meeting(
            id: MeetingID(rawValue: "2026-10-22-1000-acme-sync"),
            title: "Acme sync: backups",
            startedAt: date("2026-10-22T10:00:00Z"),
            endedAt: nil,
            captureMode: .micOnly,
            language: "en",
            accountID: "work",
            association: nil,
            client: "Acme",
            candidateEvents: [],
            attendees: [Attendee(name: "Ann", email: "ann@acme.be")],
            recipients: [],
            flags: [],
            speakerNames: [:],
            status: .ready,
            summaryEngine: .claude,
            engineNotice: nil,
            exportedNotePath: nil,
            draftWebLink: nil,
            metrics: ProcessingMetrics()
        )
    }

    private func summary() -> Summary {
        Summary(
            language: "en",
            subjects: [Subject(
                title: "Backups",
                bullets: [Bullet(text: "Window agreed", sources: [1])],
                actions: [ActionPoint(owner: "Sam", text: "Confirm backup window", due: "2026-11-07", sources: [1])]
            )],
            engine: .claude,
            generatedAt: date("2026-10-22T11:00:00Z")
        )
    }

    private func options(embedded: [String] = []) -> NoteOptions {
        NoteOptions(
            transcriptLink: URL(fileURLWithPath: "/tmp/muninn/transcript.md"),
            embeddedTranscript: nil,
            audioLinks: [URL(fileURLWithPath: "/tmp/muninn/mic.caf"), URL(fileURLWithPath: "/tmp/muninn/system.caf")],
            embeddedAudioFileNames: embedded
        )
    }

    private func tempVault() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("muninn-obsidian-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func pathWithClient() {
        let path = NotePathResolver.relativePath(
            pattern: pattern, area: "Work", client: "Acme", date: date("2026-10-22T10:00:00Z"),
            title: "Acme sync", inbox: "Inbox", timeZone: utc
        )
        #expect(path == "Work/Clients/Acme/Meetings/2026-10-22 Acme sync.md")
    }

    @Test func pathWithoutClientGoesToInbox() {
        let path = NotePathResolver.relativePath(
            pattern: pattern, area: "Work", client: nil, date: date("2026-10-22T10:00:00Z"),
            title: "Acme sync", inbox: "Inbox", timeZone: utc
        )
        #expect(path == "Inbox/2026-10-22 Acme sync.md")
    }

    @Test func titleWithSlashDoesNotCreateFolders() {
        let path = NotePathResolver.relativePath(
            pattern: pattern, area: "Work", client: "Acme", date: date("2026-10-22T10:00:00Z"),
            title: "Q3/Q4: plan?", inbox: "Inbox", timeZone: utc
        )
        #expect(path == "Work/Clients/Acme/Meetings/2026-10-22 Q3Q4 plan.md")
        #expect(NotePathResolver.sanitize("///") == "")
        #expect(NotePathResolver.sanitize("  .hidden   name ") == "hidden name")
        #expect(NotePathResolver.sanitize(String(repeating: "a", count: 100)).count == 80)
        let empty = NotePathResolver.relativePath(
            pattern: pattern, area: "A", client: nil, date: date("2026-10-22T10:00:00Z"),
            title: "?", inbox: "Inbox", timeZone: utc
        )
        #expect(empty == "Inbox/2026-10-22 Meeting.md")
    }

    @Test func subdomainMaps() {
        let domains = ["acme.example": "Acme", "example.org": "Other"]
        let attendees = [
            Attendee(name: "Me", email: "me@example.org"),
            Attendee(name: "A", email: "a@mail.acme.example"),
            Attendee(name: "B", email: "b@NOTacme.example"),
            Attendee(name: "C", email: "c@ACME.example"),
        ]
        #expect(ClientMapper.client(for: attendees, domains: domains, selfAddresses: ["me@example.org"]) == "Acme")
        #expect(ClientMapper.client(for: [Attendee(name: "B", email: "b@notacme.example")], domains: domains, selfAddresses: []) == nil)
        let tie = [Attendee(name: "O", email: "o@example.org"), Attendee(name: "A", email: "a@acme.example")]
        #expect(ClientMapper.client(for: tie, domains: domains, selfAddresses: []) == "Other")
    }

    @Test func taskLineFormat() {
        let note = MeetingNoteRenderer.render(meeting: meeting(), summary: summary(), options: options())
        #expect(note.contains("- [ ] Confirm backup window [owner:: Sam] [due:: 2026-11-07]"))
        #expect(note.contains("title: \"Acme sync: backups\""))
        #expect(note.contains("type: meeting"))
        #expect(note.contains("muninn: 2026-10-22-1000-acme-sync"))
        #expect(note.contains("### Backups"))
        #expect(note.contains("[Full transcript](file:///tmp/muninn/transcript.md)"))
    }

    @Test func ownersAreMappedThroughSpeakerNames() {
        var named = meeting()
        named.speakerNames = ["S2": "Jan"]
        let summary = Summary(
            language: "en",
            subjects: [Subject(title: "Offer", bullets: [], actions: [
                ActionPoint(owner: "S2", text: "Send the offer", due: nil, sources: [1]),
                ActionPoint(owner: "S3", text: "Review it", due: nil, sources: [1]),
            ])],
            engine: .claude,
            generatedAt: date("2026-10-22T11:00:00Z")
        )
        let note = MeetingNoteRenderer.render(meeting: named, summary: summary, options: options())
        #expect(note.contains("- [ ] Send the offer [owner:: Jan]"))
        #expect(note.contains("- [ ] Review it [owner:: S3]"))
    }

    @Test func defaultNoteLinksAudioWithoutEmbeds() {
        let note = MeetingNoteRenderer.render(meeting: meeting(), summary: summary(), options: options())
        #expect(note.contains("[Audio (mic)](file:///tmp/muninn/mic.caf)"))
        #expect(note.contains("[Audio (call)](file:///tmp/muninn/system.caf)"))
        #expect(!note.contains("![["))
        let embedded = MeetingNoteRenderer.render(meeting: meeting(), summary: summary(), options: options(embedded: ["mic.m4a"]))
        #expect(embedded.contains("![[mic.m4a]]"))
    }

    @Test func frontmatterDateUsesGivenTimeZone() {
        var m = meeting()
        m.startedAt = date("2026-10-22T22:30:00Z")
        var brussels = options()
        brussels.timeZone = TimeZone(identifier: "Europe/Brussels")!
        var utcOptions = options()
        utcOptions.timeZone = utc
        #expect(MeetingNoteRenderer.render(meeting: m, summary: summary(), options: brussels).contains("date: 2026-10-23\n"))
        #expect(MeetingNoteRenderer.render(meeting: m, summary: summary(), options: utcOptions).contains("date: 2026-10-22\n"))
    }

    @Test func existingFileNotOverwritten() throws {
        let vault = try tempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let exporter = ObsidianExporter(vault: vault)
        let first = try exporter.export(note: "one", relativePath: "A/B/note.md", attachments: [], overwrite: false)
        let url = vault.appendingPathComponent("A/B/note.md")
        #expect(first == .written(url))
        let second = try exporter.export(note: "two", relativePath: "A/B/note.md", attachments: [], overwrite: false)
        #expect(second == .alreadyExists(url))
        #expect(try String(contentsOf: url, encoding: .utf8) == "one")
    }

    @Test func overwriteWhenAsked() throws {
        let vault = try tempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let attachment = vault.appendingPathComponent("src.m4a")
        try Data("audio".utf8).write(to: attachment)
        let exporter = ObsidianExporter(vault: vault)
        _ = try exporter.export(note: "one", relativePath: "N/note.md", attachments: [attachment], overwrite: false)
        let outcome = try exporter.export(note: "two", relativePath: "N/note.md", attachments: [attachment], overwrite: true)
        let url = vault.appendingPathComponent("N/note.md")
        #expect(outcome == .written(url))
        #expect(try String(contentsOf: url, encoding: .utf8) == "two")
        #expect(try String(contentsOf: vault.appendingPathComponent("N/note - src.m4a"), encoding: .utf8) == "audio")
    }

    @Test func twoNotesWithSameAttachmentNamesKeepBoth() throws {
        let vault = try tempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let sources = vault.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: sources.appendingPathComponent("a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sources.appendingPathComponent("b"), withIntermediateDirectories: true)
        let a = sources.appendingPathComponent("a/mic.caf")
        let b = sources.appendingPathComponent("b/mic.caf")
        try Data("A".utf8).write(to: a)
        try Data("B".utf8).write(to: b)
        let exporter = ObsidianExporter(vault: vault)
        _ = try exporter.export(note: "a", relativePath: "M/2026-10-22 One.md", attachments: [a], overwrite: false)
        _ = try exporter.export(note: "b", relativePath: "M/2026-10-22 Two.md", attachments: [b], overwrite: false)
        #expect(ObsidianExporter.attachmentName(forNote: "M/2026-10-22 One.md", source: a) == "2026-10-22 One - mic.caf")
        #expect(try String(contentsOf: vault.appendingPathComponent("M/2026-10-22 One - mic.caf"), encoding: .utf8) == "A")
        #expect(try String(contentsOf: vault.appendingPathComponent("M/2026-10-22 Two - mic.caf"), encoding: .utf8) == "B")
    }

    @Test func failedCopyLeavesNoNoteOrAttachments() throws {
        let vault = try tempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let good = vault.appendingPathComponent("good.caf")
        try Data("x".utf8).write(to: good)
        let missing = vault.appendingPathComponent("missing.caf")
        let exporter = ObsidianExporter(vault: vault)
        #expect(throws: (any Error).self) {
            try exporter.export(note: "n", relativePath: "M/note.md", attachments: [good, missing], overwrite: false)
        }
        #expect(!FileManager.default.fileExists(atPath: vault.appendingPathComponent("M/note.md").path))
        #expect(!FileManager.default.fileExists(atPath: vault.appendingPathComponent("M/note - good.caf").path))
    }

    @Test func existingNoteIsUntouchedWithoutOverwrite() throws {
        let vault = try tempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let url = vault.appendingPathComponent("M/note.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: url)
        let attachment = vault.appendingPathComponent("a.caf")
        try Data("A".utf8).write(to: attachment)
        let outcome = try ObsidianExporter(vault: vault).export(note: "theirs", relativePath: "M/note.md", attachments: [attachment], overwrite: false)
        #expect(outcome == .alreadyExists(url))
        #expect(try String(contentsOf: url, encoding: .utf8) == "mine")
        #expect(!FileManager.default.fileExists(atPath: vault.appendingPathComponent("M/note - a.caf").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: vault.appendingPathComponent("M").path)
        #expect(leftovers == ["note.md"])
    }

    @Test func concurrentExportsToOnePathWriteExactlyOnce() throws {
        let vault = try tempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let exporter = ObsidianExporter(vault: vault)
        let outcomes = LockedBox<[ExportOutcome]>([])
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            if let outcome = try? exporter.export(note: "note \(index)", relativePath: "M/note.md", attachments: [], overwrite: false) {
                outcomes.update { $0.append(outcome) }
            }
        }
        let url = vault.appendingPathComponent("M/note.md")
        let results = outcomes.get()
        #expect(results.count == 12)
        #expect(results.filter { $0 == .written(url) }.count == 1)
        #expect(results.filter { $0 == .alreadyExists(url) }.count == 11)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: vault.appendingPathComponent("M").path)
        #expect(leftovers == ["note.md"])
    }

    @Test func pathOutsideVaultRejected() throws {
        let vault = try tempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        #expect(throws: ObsidianExportError.outsideVault) {
            try ObsidianExporter(vault: vault).export(note: "n", relativePath: "../escape.md", attachments: [], overwrite: false)
        }
    }

    @Test func relatedNotesSection() {
        var opts = options()
        opts.relatedNotes = ["Acme", "Backups"]
        let note = MeetingNoteRenderer.render(meeting: meeting(), summary: summary(), options: opts)
        #expect(note.contains("## Related\n\n- [[Acme]]\n- [[Backups]]"))
        #expect(!MeetingNoteRenderer.render(meeting: meeting(), summary: summary(), options: options()).contains("## Related"))
    }

    @Test func sanitizeAndPlaceholderHardening() {
        #expect(NotePathResolver.sanitize(". .env") == "env")
        #expect(NotePathResolver.sanitize(". ..") == "")
        #expect(NotePathResolver.sanitize("a{date}b") == "adateb")
        let date = date("2026-10-22T10:00:00Z")
        let missingArea = NotePathResolver.relativePath(pattern: pattern, area: "///", client: "Acme", date: date, title: "T", inbox: "Inbox", timeZone: utc)
        #expect(missingArea == "Inbox/2026-10-22 T.md")
        let single = NotePathResolver.relativePath(pattern: "{title}/{date}", area: "A", client: "C", date: date, title: "x", inbox: "Inbox", timeZone: utc)
        #expect(single == "x/2026-10-22")
    }

    @Test func mostFrequentClientBeatsEarliest() {
        let domains = ["acme.example": "Acme", "example.org": "Other"]
        let attendees = [
            Attendee(name: "O", email: "o@example.org"),
            Attendee(name: "A", email: "a@acme.example"),
            Attendee(name: "B", email: "b@acme.example"),
        ]
        #expect(ClientMapper.client(for: attendees, domains: domains, selfAddresses: []) == "Acme")
    }

    @Test func optionalFieldsOmittedAndTitleEscaped() {
        var m = meeting()
        m.client = nil
        m.accountID = nil
        m.summaryEngine = nil
        m.attendees = []
        m.title = "Say \"hi\""
        let note = MeetingNoteRenderer.render(meeting: m, summary: summary(), options: options())
        #expect(!note.contains("client:"))
        #expect(!note.contains("account:"))
        #expect(!note.contains("engine:"))
        #expect(note.contains("attendees: []"))
        #expect(note.contains("title: \"Say \\\"hi\\\"\""))
    }

    @Test func embeddedTranscriptAndAudioLabels() {
        var opts = options()
        opts.embeddedTranscript = "Hello transcript"
        opts.audioLinks = [URL(fileURLWithPath: "/a/mic.caf"), URL(fileURLWithPath: "/a/system.caf"), URL(fileURLWithPath: "/a/extra.caf")]
        let note = MeetingNoteRenderer.render(meeting: meeting(), summary: summary(), options: opts)
        #expect(note.contains("Hello transcript"))
        #expect(!note.contains("[Full transcript]"))
        #expect(note.contains("[Audio (mic)](file:///a/mic.caf)"))
        #expect(note.contains("[Audio (call)](file:///a/system.caf)"))
        #expect(note.contains("[Audio (extra.caf)](file:///a/extra.caf)"))
        #expect(MeetingNoteRenderer.render(meeting: meeting(), summary: summary(), options: options()).contains("  - \"ann@acme.be\""))
    }

    @Test func vaultUnderPrivatePrefixExportsNewNote() throws {
        let temp = try tempVault()
        defer { try? FileManager.default.removeItem(at: temp) }
        let path = temp.path.hasPrefix("/private") ? temp.path : "/private" + temp.path
        let vault = URL(fileURLWithPath: path)
        #expect(vault.path.hasPrefix("/private"))
        let outcome = try ObsidianExporter(vault: vault).export(note: "n", relativePath: "New/Dir/note.md", attachments: [], overwrite: false)
        #expect(outcome == .written(vault.appendingPathComponent("New/Dir/note.md")))
        #expect(throws: ObsidianExportError.outsideVault) {
            try ObsidianExporter(vault: vault).export(note: "n", relativePath: "../escape.md", attachments: [], overwrite: false)
        }
    }

    @Test func failedOverwriteKeepsOldAttachment() throws {
        let vault = try tempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let first = vault.appendingPathComponent("mic.caf")
        try Data("old".utf8).write(to: first)
        let exporter = ObsidianExporter(vault: vault)
        _ = try exporter.export(note: "one", relativePath: "M/note.md", attachments: [first], overwrite: false)
        try Data("new".utf8).write(to: first)
        let missing = vault.appendingPathComponent("system.caf")
        #expect(throws: (any Error).self) {
            try exporter.export(note: "two", relativePath: "M/note.md", attachments: [first, missing], overwrite: true)
        }
        #expect(try String(contentsOf: vault.appendingPathComponent("M/note - mic.caf"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: vault.appendingPathComponent("M/note.md"), encoding: .utf8) == "one")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: vault.appendingPathComponent("M").path)
        #expect(leftovers.sorted() == ["note - mic.caf", "note.md"])
    }

    @Test func emptyEmailAttendeeAndRelatedNameSanitized() {
        var m = meeting()
        m.attendees = [Attendee(name: "Ghost", email: ""), Attendee(name: "Ann", email: "ann@acme.be")]
        var opts = options()
        opts.relatedNotes = ["A[b]|c"]
        let note = MeetingNoteRenderer.render(meeting: m, summary: summary(), options: opts)
        #expect(!note.contains("Ghost"))
        #expect(note.contains("- [[Abc]]"))
    }
}
