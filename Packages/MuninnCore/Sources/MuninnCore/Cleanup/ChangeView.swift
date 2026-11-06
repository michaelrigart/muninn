import Foundation

public struct ChangeToken: Hashable, Sendable {
    public var text: String
    public var removed: Bool

    public init(text: String, removed: Bool) {
        self.text = text
        self.removed = removed
    }
}

public enum ChangeView {
    public static func tokens(verbatim: String, clean: String) -> [ChangeToken] {
        let surface = verbatim.split(whereSeparator: \.isWhitespace).map(String.init)
        let forms = surface.map(Tokenizer.normalize)
        let cleanForms = clean.split(whereSeparator: \.isWhitespace).map { Tokenizer.normalize(String($0)) }
        let kept = Set(WordAlignment.pairs(forms, cleanForms).map(\.0))

        return surface.indices.map { index in
            ChangeToken(text: surface[index], removed: !forms[index].isEmpty && !kept.contains(index))
        }
    }

    /// For each whitespace-separated token of `clean`, the index of the verbatim token it keeps.
    public static func alignment(verbatim: String, clean: String) -> [Int?] {
        let forms = verbatim.split(whereSeparator: \.isWhitespace).map { Tokenizer.normalize(String($0)) }
        let cleanForms = clean.split(whereSeparator: \.isWhitespace).map { Tokenizer.normalize(String($0)) }
        var result = [Int?](repeating: nil, count: cleanForms.count)
        for (verbatimIndex, cleanIndex) in WordAlignment.pairs(forms, cleanForms) {
            result[cleanIndex] = verbatimIndex
        }
        return result
    }
}
