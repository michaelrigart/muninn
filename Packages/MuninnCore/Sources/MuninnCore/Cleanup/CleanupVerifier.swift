import Foundation

public enum CleanupVerifier {
    public static let protectedWords: Set<String> = [
        "niet", "geen", "nooit", "pas", "ne", "not", "no", "never", "nothing", "jamais", "rien",
    ]

    public static func isDeletionOnly(verbatim: String, clean: String) -> Bool {
        let verbatimWords = Tokenizer.normalizedWords(verbatim)
        let cleanWords = Tokenizer.normalizedWords(clean)
        var remaining = verbatimWords[...]
        for word in cleanWords {
            guard let index = remaining.firstIndex(of: word) else { return false }
            remaining = remaining[remaining.index(after: index)...]
        }
        for word in Set(verbatimWords) where protectedWords.contains(word) || word.hasSuffix("n't") {
            if verbatimWords.filter({ $0 == word }).count > cleanWords.filter({ $0 == word }).count { return false }
        }
        return true
    }
}
