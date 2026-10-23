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
        let cleanWords = Tokenizer.normalizedWords(clean)
        let candidates = forms.indices.filter { !forms[$0].isEmpty }

        let n = candidates.count
        let m = cleanWords.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = forms[candidates[i]] == cleanWords[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var kept = Set<Int>()
        var i = 0
        var j = 0
        while i < n, j < m {
            if forms[candidates[i]] == cleanWords[j] {
                kept.insert(candidates[i])
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }

        return surface.indices.map { index in
            ChangeToken(text: surface[index], removed: !forms[index].isEmpty && !kept.contains(index))
        }
    }
}
