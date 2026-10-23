import Foundation
import MuninnCore

/// SentencePiece-style token: a leading "▁" or " " starts a new word.
public struct TimedToken: Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public enum SegmentBuilder {
    private static let sentenceEnds: Set<Character> = [".", "?", "!"]

    public static func words(from tokens: [TimedToken]) -> [Word] {
        var words: [Word] = []
        var current: (text: String, start: TimeInterval, end: TimeInterval)?

        func flush() {
            if let current, !current.text.isEmpty {
                words.append(Word(text: current.text, start: current.start, end: current.end))
            }
            current = nil
        }

        for token in tokens {
            if let first = token.text.first, first == "▁" || first == " " {
                flush()
                let text = String(token.text.drop(while: { $0 == "▁" || $0 == " " }))
                current = (text, token.start, token.end)
            } else if var open = current {
                open.text += token.text
                open.end = token.end
                current = open
            } else {
                current = (token.text, token.start, token.end)
            }
        }
        flush()
        return words
    }

    public static func segments(
        from words: [Word],
        track: Track,
        pauseGap: TimeInterval = 0.8,
        maxDuration: TimeInterval = 20
    ) -> [Segment] {
        var segments: [Segment] = []
        var group: [Word] = []

        func flush() {
            guard let first = group.first, let last = group.last else { return }
            segments.append(Segment(
                id: segments.count,
                track: track,
                speaker: "",
                start: first.start,
                end: last.end,
                text: group.map(\.text).joined(separator: " "),
                words: group
            ))
            group = []
        }

        for word in words {
            if let first = group.first, let last = group.last,
               word.start - last.end > pauseGap || word.end - first.start > maxDuration {
                flush()
            }
            group.append(word)
            if let end = word.text.last, sentenceEnds.contains(end) {
                flush()
            }
        }
        flush()
        return segments
    }

    /// A stretch of recognised text with the engine's own bounds and, when the engine produced
    /// them, its word timings.
    struct Piece {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
        var words: [Word]
    }

    /// Pieces with words are split into segments as usual; a piece whose engine gave text but
    /// no word timings stays one segment with `words: []` rather than being dropped.
    static func segments(from pieces: [Piece], track: Track) -> [Segment] {
        var result: [Segment] = []
        var run: [Word] = []

        func flushRun() {
            result += segments(from: run, track: track)
            run = []
        }

        for piece in pieces {
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.words.isEmpty {
                run += piece.words
            } else if !text.isEmpty {
                flushRun()
                result.append(Segment(id: 0, track: track, speaker: "", start: piece.start, end: piece.end, text: text, words: []))
            }
        }
        flushRun()
        for index in result.indices { result[index].id = index }
        return result
    }

    /// Maps vocabulary-corrected text back onto word timings. Words the correction left alone
    /// keep their timings exactly; each changed hunk is spread evenly over the span it replaced.
    static func realign(_ words: [Word], to text: String) -> [Word] {
        let original = words.map(\.text)
        let corrected = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in corrected.difference(from: original) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var result: [Word] = []
        var i = 0
        var j = 0
        while i < words.count || j < corrected.count {
            if i < words.count, j < corrected.count, !removed.contains(i), !inserted.contains(j) {
                result.append(words[i])
                i += 1
                j += 1
                continue
            }
            var old: [Word] = []
            var new: [String] = []
            while i < words.count, removed.contains(i) {
                old.append(words[i])
                i += 1
            }
            while j < corrected.count, inserted.contains(j) {
                new.append(corrected[j])
                j += 1
            }
            if old.isEmpty && new.isEmpty { break }
            guard !new.isEmpty else { continue }
            if old.count == new.count {
                for (word, text) in zip(old, new) { result.append(Word(text: text, start: word.start, end: word.end)) }
                continue
            }
            let start = old.first?.start ?? result.last?.end ?? words.first?.start ?? 0
            let end = old.last?.end ?? start
            let step = (end - start) / Double(new.count)
            for (offset, text) in new.enumerated() {
                result.append(Word(text: text, start: start + step * Double(offset), end: start + step * Double(offset + 1)))
            }
        }
        return result
    }
}

/// Fits a vocabulary list into a decoder prompt budget.
enum PromptBuilder {
    /// Whole entries are kept in order until the next one would exceed `limit` tokens; the rest
    /// are dropped and counted.
    static func tokens(for vocabulary: [String], limit: Int, encode: (String) -> [Int]) -> (tokens: [Int], dropped: Int) {
        var tokens: [Int] = []
        for (index, term) in vocabulary.enumerated() {
            let piece = encode((tokens.isEmpty ? " " : ", ") + term)
            if tokens.count + piece.count > limit { return (tokens, vocabulary.count - index) }
            tokens += piece
        }
        return (tokens, 0)
    }
}
