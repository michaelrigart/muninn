import Foundation
import Testing
@testable import MuninnCore

@Suite struct EmailRecipientsTests {
    @Test(arguments: ["ann@example.com", "ann.peeters+recap@mail.example.be", "zoë@exämple.be"])
    func validAddressesPass(_ address: String) { #expect(EmailRecipients.isValidAddress(address)) }

    @Test(arguments: [
        "last,first@example.com", "a;b@example.com", "<a@example.com>", "ann peeters@example.com",
        "a@b@example.com", "ann@example", "ann@", "@example.com", "ann:x@example.com",
        #""ann"@example.com"#, "ann(x)@example.com", "ann[x]@example.com", #"ann\x@example.com"#, "ann@example.com\n",
    ])
    func addressesThatCouldBreakTheLineAreRefused(_ address: String) { #expect(!EmailRecipients.isValidAddress(address)) }

    @Test func typedAddressIsTrimmedAndChecked() {
        #expect(EmailRecipients.typedAddress("  ann@example.com \n") == Attendee(name: "", email: "ann@example.com"))
        #expect(EmailRecipients.typedAddress("last,first@example.com") == nil)
        #expect(EmailRecipients.typedAddress("ann peeters@example.com") == nil)
        #expect(EmailRecipients.typedAddress("ann") == nil)
    }

    @Test func lineFormatsQuotesAndEscapesNames() {
        let recipients = [
            Recipient(attendee: Attendee(name: "Ann Peeters", email: "ann@example.com"), included: true),
            Recipient(attendee: Attendee(name: "", email: "bob@example.com"), included: true),
            Recipient(attendee: Attendee(name: "Carl", email: "carl@example.com"), included: false),
            Recipient(attendee: Attendee(name: "Peeters, Ann", email: "ann2@example.com"), included: true),
            Recipient(attendee: Attendee(name: #"Ann "Boss" \ P"#, email: "boss@example.com"), included: true),
            Recipient(attendee: Attendee(name: "Dr. Who", email: "who@example.com"), included: true),
            Recipient(attendee: Attendee(name: "   ", email: "blank@example.com"), included: true),
            Recipient(attendee: Attendee(name: "Zoë Peeters", email: "zoe@example.be"), included: true),
            Recipient(attendee: Attendee(name: "Bob@Client.com", email: "bob@client.com"), included: true),
        ]
        #expect(EmailRecipients.line(recipients) == #"Ann Peeters <ann@example.com>, bob@example.com, "Peeters, Ann" <ann2@example.com>, "Ann \"Boss\" \\ P" <boss@example.com>, "Dr. Who" <who@example.com>, blank@example.com, Zoë Peeters <zoe@example.be>, bob@client.com"#)
    }

    @Test func lineIsEmptyWhenNobodyIsTicked() {
        #expect(EmailRecipients.line([Recipient(attendee: Attendee(name: "Ann", email: "ann@example.com"), included: false)]) == "")
    }
}
