import AppKit
import MuninnCore

/// Writes the Email recap sheet's parts to the general pasteboard, replacing whatever it held.
@MainActor
enum RecapPasteboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The recap as HTML, RTF and plain text on one item, so each mail app takes the richest form it reads.
    static func copyRecap(_ summary: Summary, speakerNames: [String: String]) {
        let html = RecapEmail.htmlDocument(summary: summary, speakerNames: speakerNames)
        let item = NSPasteboardItem()
        item.setData(Data(html.utf8), forType: .html)
        if let rtf = rtf(fromHTML: html) {
            item.setData(rtf, forType: .rtf)
        }
        item.setString(RecapEmail.plainText(summary: summary, speakerNames: speakerNames), forType: .string)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// The HTML imported as an attributed string, with the importer's Times replaced by the system font at the same
    /// sizes, keeping bold, then written as RTF. Nil when the HTML can't be imported or written.
    private static func rtf(fromHTML html: String) -> Data? {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let imported = try? NSAttributedString(data: Data(html.utf8), options: options, documentAttributes: nil) else {
            return nil
        }
        let text = NSMutableAttributedString(attributedString: imported)
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.font, in: whole) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
            text.addAttribute(.font, value: NSFont.systemFont(ofSize: font.pointSize, weight: bold ? .bold : .regular), range: range)
        }
        return text.rtf(from: whole, documentAttributes: [:])
    }
}
