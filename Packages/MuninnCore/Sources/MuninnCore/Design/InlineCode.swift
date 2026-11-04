import Foundation

/// Splits text into plain and code runs. Only a span between backticks is code; nothing else is
/// parsed, because titles and explanations hold model and account names that may contain `*` or `_`.
public enum InlineCode {
    public struct Run: Equatable, Sendable {
        public var text: String
        public var isCode: Bool

        public init(text: String, isCode: Bool) {
            self.text = text
            self.isCode = isCode
        }
    }

    public static func runs(_ text: String) -> [Run] {
        var parts = text.components(separatedBy: "`")
        if parts.count > 1, parts.count.isMultiple(of: 2) {
            let last = parts.removeLast()
            parts[parts.count - 1] += "`" + last
        }
        var runs: [Run] = []
        for (index, part) in parts.enumerated() where !part.isEmpty {
            let isCode = index % 2 == 1
            if let last = runs.last, last.isCode == isCode {
                runs[runs.count - 1].text += part
            } else {
                runs.append(Run(text: part, isCode: isCode))
            }
        }
        return runs
    }
}
