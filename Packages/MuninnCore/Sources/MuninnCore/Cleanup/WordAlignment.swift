import Foundation

public enum WordAlignment {
    /// For each whitespace-separated token of `text`, the index of its timed word, or nil.
    public static func tokenWords(text: String, words: [Word]) -> [Int?] {
        let forms = text.split(whereSeparator: \.isWhitespace).map { Tokenizer.normalize(String($0)) }
        if forms.count == words.count { return forms.indices.map { $0 } }
        var result = [Int?](repeating: nil, count: forms.count)
        for (tokenIndex, wordIndex) in pairs(forms, words.map { Tokenizer.normalize($0.text) }) {
            result[tokenIndex] = wordIndex
        }
        return result
    }

    /// The longest common subsequence of two lists of normalised forms, as matched index pairs in
    /// order. Empty forms never match.
    public static func pairs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let left = a.indices.filter { !a[$0].isEmpty }
        let right = b.indices.filter { !b[$0].isEmpty }
        let n = left.count
        let m = right.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[left[i]] == b[right[j]]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var matched: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if a[left[i]] == b[right[j]] {
                matched.append((left[i], right[j]))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return matched
    }
}
