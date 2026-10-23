import Foundation

public enum Tokenizer {
    private static let units: Set<Character> = ["%", "\u{20AC}", "$", "\u{00A3}"]

    public static func normalizedWords(_ s: String) -> [String] {
        s.split(whereSeparator: \.isWhitespace)
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    public static func normalize(_ token: String) -> String {
        let characters = Array(token.lowercased())
        var kept = ""
        for (index, character) in characters.enumerated() {
            if character.isLetter || character.isNumber {
                kept.append(character)
            } else if character == "'" || character == "\u{2019}" {
                kept.append("'")
            } else if character == "-" || character == "+",
                      index + 1 < characters.count, characters[index + 1].isNumber,
                      index == 0 || !(characters[index - 1].isLetter || characters[index - 1].isNumber) {
                kept.append(character)
            } else if character == "-" {
                kept.append("-")
            } else if Self.units.contains(character),
                      (index > 0 && characters[index - 1].isNumber) || (index + 1 < characters.count && characters[index + 1].isNumber) {
                kept.append(character)
            } else if character == "." || character == "," || character == ":",
                      index > 0, index + 1 < characters.count,
                      characters[index - 1].isNumber, characters[index + 1].isNumber {
                kept.append(character)
            }
        }
        let edges: Set<Character> = ["'", "-"]
        while let first = kept.first, edges.contains(first), !(first == "-" && kept.dropFirst().first?.isNumber == true) {
            kept.removeFirst()
        }
        while let last = kept.last, edges.contains(last) { kept.removeLast() }
        return kept
    }
}
