import Foundation
import Testing
@testable import MuninnCore

struct RecapEmailTests {
    static let brussels = TimeZone(identifier: "Europe/Brussels")!

    static func summary(language: String, title: String = "Pricing", bullet: String = "Agreed on tiers", owner: String = "Jan", action: String = "Send quote", due: String? = nil) -> Summary {
        Summary(
            language: language,
            subjects: [Subject(
                title: title,
                bullets: [Bullet(text: bullet, sources: [1])],
                actions: [ActionPoint(owner: owner, text: action, due: due, sources: [1])]
            )],
            engine: .claude,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    @Test func subjectFormat() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.brussels
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 23, minute: 30))!
        #expect(RecapEmail.subject(title: "Acme monthly sync", date: date, timeZone: Self.brussels) == "Recap: Acme monthly sync, 22/10/2026")
    }

    @Test func dutchCopy() {
        let html = RecapEmail.html(summary: Self.summary(language: "nl"), speakerNames: [:])
        #expect(html.contains("<p>Hallo allemaal,</p>"))
        #expect(html.contains("<p>Bedankt voor het gesprek. Hieronder de samenvatting en de volgende stappen.</p>"))
        #expect(html.contains("<h3>Actiepunten</h3>"))
        #expect(html.contains("<p>Met vriendelijke groeten,</p>"))
        #expect(html.contains("<h3>Pricing</h3>"))
        #expect(html.contains("<li>Agreed on tiers</li>"))
        #expect(html.contains("<li><b>Jan</b>: Send quote</li>"))
    }

    @Test func frenchAndFallbackCopy() {
        let fr = RecapEmail.html(summary: Self.summary(language: "fr"), speakerNames: [:])
        #expect(fr.contains("<p>Bonjour à tous,</p>"))
        #expect(fr.contains("Merci pour l&#39;échange."))
        #expect(fr.contains("<h3>Points d&#39;action</h3>"))
        #expect(fr.contains("<p>Cordialement,</p>"))
        let de = RecapEmail.html(summary: Self.summary(language: "de"), speakerNames: [:])
        #expect(de.contains("<p>Hi all,</p>"))
        #expect(de.contains("<h3>Action points</h3>"))
        #expect(de.contains("<p>Best regards,</p>"))
    }

    @Test func escapesHTML() {
        let html = RecapEmail.html(
            summary: Self.summary(language: "en", title: "<script>alert(1)</script>", bullet: "A & B \"q\" 'x'"),
            speakerNames: [:]
        )
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(!html.contains("<script>"))
        #expect(html.contains("A &amp; B &quot;q&quot; &#39;x&#39;"))
    }

    @Test func dueDateFormatted() {
        let html = RecapEmail.html(summary: Self.summary(language: "en", due: "2026-11-07"), speakerNames: [:])
        #expect(html.contains("<li><b>Jan</b>: Send quote (07/11)</li>"))
    }

    @Test func ownerResolvedThroughSpeakerNames() {
        let html = RecapEmail.html(summary: Self.summary(language: "en", owner: "S1"), speakerNames: ["S1": "Sara"])
        #expect(html.contains("<b>Sara</b>"))
    }
}
