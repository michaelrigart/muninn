import Foundation

public enum RuleCleaner {
    public static let fillers: Set<String> = [
        "euh", "euhm", "eh", "ehm", "uh", "uhm", "um", "umm", "hmm", "hm", "mm", "mmm",
    ]

    private static let sentenceEnds: Set<Character> = [".", "?", "!", ":", ";"]

    public static func clean(_ text: String) -> String {
        var tokens = removeFillers(text.split(whereSeparator: \.isWhitespace).map(String.init))
        tokens = collapseRepeats(tokens)
        guard let first = tokens.first else { return "" }
        tokens[0] = capitalizingFirstLetter(first)
        return tokens.joined(separator: " ")
    }

    private static func removeFillers(_ tokens: [String]) -> [String] {
        var result: [String] = []
        for (index, token) in tokens.enumerated() {
            let form = Tokenizer.normalize(token)
            guard fillers.contains(form) else {
                result.append(token)
                continue
            }
            if form == "eh", index + 1 < tokens.count, ["bien", "ben"].contains(Tokenizer.normalize(tokens[index + 1])) {
                result.append(token)
                continue
            }
            if token.hasSuffix(",") { continue }
            if let last = token.last, ".?!".contains(last), var previous = result.popLast() {
                if previous.hasSuffix(",") { previous.removeLast() }
                if let end = previous.last, ".?!:;".contains(end) {
                    result.append(previous)
                } else {
                    result.append(previous + String(last))
                }
            } else if let previous = result.last, previous.hasSuffix(",") {
                result[result.count - 1] = String(previous.dropLast())
            }
        }
        return result
    }

    private static func collapseRepeats(_ input: [String]) -> [String] {
        var tokens = input
        var changed = true
        while changed {
            changed = false
            let normalized = tokens.map(Tokenizer.normalize)
            search: for index in 0..<tokens.count {
                for size in stride(from: 3, through: 1, by: -1) where index + 2 * size <= tokens.count {
                    let first = normalized[index..<index + size]
                    let second = normalized[index + size..<index + 2 * size]
                    guard first.elementsEqual(second), isCollapsible(Array(tokens[index..<index + size]), forms: Array(first)) else { continue }
                    if let survivor = tokens.indices.contains(index + size) ? index + size : nil,
                       tokens[index].first?.isUppercase == true,
                       let letter = tokens[survivor].first, letter.isLowercase {
                        tokens[survivor] = capitalizingFirstLetter(tokens[survivor])
                    }
                    tokens.removeSubrange(index..<index + size)
                    changed = true
                    break search
                }
            }
        }
        return tokens
    }

    private static func isCollapsible(_ copy: [String], forms: [String]) -> Bool {
        if forms.contains(where: \.isEmpty) { return false }
        if forms.contains(where: { $0.contains(where: \.isNumber) }) { return false }
        if forms.contains(where: { CleanupVerifier.protectedWords.contains($0) }) { return false }
        if copy.contains(where: { $0.last.map { sentenceEnds.contains($0) } == true }) { return false }
        if copy.count == 1 { return copy[0].hasSuffix(",") }
        return true
    }

    private static func capitalizingFirstLetter(_ token: String) -> String {
        guard let index = token.firstIndex(where: { $0.isLetter || $0.isNumber }), token[index].isLetter else { return token }
        return token[..<index] + token[index].uppercased() + token[token.index(after: index)...]
    }
}
