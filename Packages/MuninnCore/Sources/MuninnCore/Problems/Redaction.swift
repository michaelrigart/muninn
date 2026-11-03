import Foundation

public enum Redaction {
    public static let marker = "[redacted]"

    private static let patterns: [NSRegularExpression] = [
        #"sk-ant-[A-Za-z0-9_\-]{8,}"#,
        #"sk-[A-Za-z0-9_\-]{16,}"#,
        #"(?i)bearer\s+[A-Za-z0-9._~+/=\-]{8,}"#,
        #"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#,
        #"[A-Za-z0-9+/_]{40,}={0,2}"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    public static func redact(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: marker))
        }
        return result
    }
}
