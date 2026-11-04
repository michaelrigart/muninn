import Foundation

public enum TranscriptMode: String, CaseIterable, Sendable {
    case clean, changes, verbatim

    public var label: String {
        switch self {
        case .clean: "Clean"
        case .changes: "Changes"
        case .verbatim: "Verbatim"
        }
    }
}

public struct ReadAlongPosition: Equatable, Sendable {
    /// Index into `TranscriptLayout.segments`.
    public var segment: Int
    /// Index into that segment's `words`.
    public var word: Int?

    public init(segment: Int, word: Int?) {
        self.segment = segment
        self.word = word
    }
}

/// The transcript's displayed text for one view, with the UTF-16 ranges of its parts.
public struct TranscriptLayout: Sendable {
    public struct WordSpan: Sendable {
        /// The shown token this timed word maps to, or nil when the shown text has none for it.
        public var range: NSRange?
        public var start: TimeInterval
        public var end: TimeInterval
    }

    public struct SegmentLayout: Sendable {
        public var segmentID: Int
        public var start: TimeInterval
        public var end: TimeInterval
        /// The whole line, without its newline.
        public var line: NSRange
        public var timestamp: NSRange
        /// The flag marker (the flag glyph and its text-presentation selector), when the segment is flagged.
        public var flag: NSRange?
        public var text: NSRange
        public var words: [WordSpan]
        /// The tokens the Changes view marks as removed.
        public var removed: [NSRange]
    }

    public struct SpeakerLine: Sendable {
        /// The name only.
        public var range: NSRange
        public var speaker: String
        public var name: String
    }

    public let string: String
    public let segments: [SegmentLayout]
    public let speakerLines: [SpeakerLine]

    private let startOrder: [Int]
    private let latestEndThrough: [TimeInterval]
    private let indexByID: [Int: Int]

    private init(string: String, segments: [SegmentLayout], speakerLines: [SpeakerLine]) {
        self.string = string
        self.segments = segments
        self.speakerLines = speakerLines
        let order = segments.indices.sorted { segments[$0].start != segments[$1].start ? segments[$0].start < segments[$1].start : $0 < $1 }
        startOrder = order
        var latest = -TimeInterval.infinity
        latestEndThrough = order.map { latest = max(latest, segments[$0].end); return latest }
        indexByID = Dictionary(segments.indices.map { (segments[$0].segmentID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public static func make(
        transcript: Transcript,
        clean: CleanTranscript?,
        mode: TranscriptMode,
        speakerNames: [String: String],
        userName: String,
        flags: [Flag]
    ) -> TranscriptLayout {
        let flagged = Set(FlagCoverage.flaggedSegmentIDs(flags, in: transcript))
        let cleanTexts = Dictionary((clean?.segments ?? []).map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        var builder = Builder()
        var previousSpeaker: String?
        var segments: [SegmentLayout] = []
        var speakerLines: [SpeakerLine] = []

        for segment in transcript.segments {
            let shown = shownText(for: segment, cleanText: cleanTexts[segment.id], mode: mode)
            guard !shown.text.allSatisfy(\.isWhitespace) else { continue }

            if segment.speaker != previousSpeaker {
                let name = singleLine(SummaryRequestBuilder.displayName(segment.speaker, speakerNames: speakerNames, userName: userName))
                builder.append("\t")
                let range = builder.append(name)
                builder.append("\n")
                speakerLines.append(SpeakerLine(range: range, speaker: segment.speaker, name: name))
                previousSpeaker = segment.speaker
            }

            let lineStart = builder.length
            let timestamp = builder.append(Timestamp.format(segment.start))
            var flag: NSRange?
            if flagged.contains(segment.id) {
                builder.append(" ")
                flag = builder.append("\u{2691}\u{FE0E}")
            }
            builder.append("\t")
            let text = builder.append(shown.text)
            let line = NSRange(location: lineStart, length: builder.length - lineStart)
            builder.append("\n")

            let tokens = tokenRanges(in: shown.text, offset: text.location)
            var wordRanges = [NSRange?](repeating: nil, count: segment.words.count)
            for (tokenIndex, wordIndex) in shown.tokenWords.enumerated() where tokenIndex < tokens.count {
                if let wordIndex, wordRanges.indices.contains(wordIndex) { wordRanges[wordIndex] = tokens[tokenIndex] }
            }
            let words = segment.words.indices.map {
                WordSpan(range: wordRanges[$0], start: segment.words[$0].start, end: segment.words[$0].end)
            }
            let removed = zip(tokens, shown.removed).filter(\.1).map(\.0)

            segments.append(SegmentLayout(
                segmentID: segment.id, start: segment.start, end: segment.end,
                line: line, timestamp: timestamp, flag: flag, text: text, words: words, removed: removed
            ))
        }
        return TranscriptLayout(string: builder.string, segments: segments, speakerLines: speakerLines)
    }

    /// The segment spoken at `time` (among overlapping segments, the latest start) and its word, or nil in a gap.
    public func position(at time: TimeInterval) -> ReadAlongPosition? {
        var low = 0
        var high = startOrder.count
        while low < high {
            let mid = (low + high) / 2
            if segments[startOrder[mid]].start <= time { low = mid + 1 } else { high = mid }
        }
        var cursor = low - 1
        while cursor >= 0, latestEndThrough[cursor] > time {
            let index = startOrder[cursor]
            if time < segments[index].end {
                return ReadAlongPosition(segment: index, word: segments[index].words.lastIndex(where: { $0.start <= time }))
            }
            cursor -= 1
        }
        return nil
    }

    /// A word's start when `offset` is inside a word; the segment's start elsewhere on its line; nil off any line.
    public func seekTime(atOffset offset: Int) -> TimeInterval? {
        guard let index = segmentIndex(containing: offset) else { return nil }
        let segment = segments[index]
        let word = segment.words.first { span in
            span.range.map { $0.location <= offset && offset < $0.location + $0.length } ?? false
        }
        return word?.start ?? segment.start
    }

    public func speakerLine(atOffset offset: Int) -> SpeakerLine? {
        var low = 0
        var high = speakerLines.count
        while low < high {
            let mid = (low + high) / 2
            if speakerLines[mid].range.location <= offset { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let line = speakerLines[low - 1]
        return offset < line.range.location + line.range.length ? line : nil
    }

    public func segmentIndex(forSegmentID id: Int) -> Int? {
        indexByID[id]
    }

    private func segmentIndex(containing offset: Int) -> Int? {
        var low = 0
        var high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].line.location <= offset { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let line = segments[low - 1].line
        return offset < line.location + line.length ? low - 1 : nil
    }

    /// The text shown for a segment, the word each of its tokens maps to, and which tokens are removed.
    private static func shownText(for segment: Segment, cleanText: String?, mode: TranscriptMode) -> (text: String, tokenWords: [Int?], removed: [Bool]) {
        let verbatimWords = WordAlignment.tokenWords(text: segment.text, words: segment.words)
        switch mode {
        case .verbatim:
            return (singleLine(segment.text), verbatimWords, [])
        case .changes:
            let tokens = ChangeView.tokens(verbatim: segment.text, clean: cleanText ?? segment.text)
            return (tokens.map(\.text).joined(separator: " "), verbatimWords, tokens.map(\.removed))
        case .clean:
            guard let cleanText else { return (singleLine(segment.text), verbatimWords, []) }
            guard !segment.words.isEmpty else { return (singleLine(cleanText), [], []) }
            let alignment = ChangeView.alignment(verbatim: segment.text, clean: cleanText)
            let words = alignment.map { verbatimIndex in verbatimIndex.flatMap { verbatimWords.indices.contains($0) ? verbatimWords[$0] : nil } }
            return (singleLine(cleanText), words, [])
        }
    }

    /// Every whitespace character, newlines and tabs included, becomes one space, so a segment is one line.
    private static func singleLine(_ text: String) -> String {
        String(text.map { $0.isWhitespace ? " " : $0 })
    }

    /// The UTF-16 range of each whitespace-separated token of `text`, which starts at `offset`.
    private static func tokenRanges(in text: String, offset: Int) -> [NSRange] {
        var ranges: [NSRange] = []
        var position = offset
        var start: Int?
        for character in text {
            if character.isWhitespace {
                if let begin = start {
                    ranges.append(NSRange(location: begin, length: position - begin))
                    start = nil
                }
            } else if start == nil {
                start = position
            }
            position += character.utf16.count
        }
        if let begin = start { ranges.append(NSRange(location: begin, length: position - begin)) }
        return ranges
    }

    /// A string built piece by piece, with the UTF-16 range of each piece.
    private struct Builder {
        var string = ""
        var length = 0

        @discardableResult
        mutating func append(_ piece: String) -> NSRange {
            let range = NSRange(location: length, length: piece.utf16.count)
            string += piece
            length += range.length
            return range
        }
    }
}
