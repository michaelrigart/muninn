import Foundation

public enum SpeakerAttribution {
    public static func attribute(
        mic: [Segment], system: [Segment], micTurns: [SpeakerTurn], systemTurns: [SpeakerTurn], mode: CaptureMode
    ) -> [Segment] {
        var combined: [Segment]
        switch mode {
        case .call:
            combined = removingEcho(from: mic, of: system).map { segment in
                var segment = segment
                segment.speaker = Transcript.youSpeaker
                return segment
            }
            combined += split(system, turns: systemTurns)
        case .micOnly:
            combined = split(mic, turns: micTurns)
        }
        var ordered = combined.enumerated().sorted { lhs, rhs in
            lhs.element.start != rhs.element.start ? lhs.element.start < rhs.element.start : lhs.offset < rhs.offset
        }.map(\.element)
        for index in ordered.indices {
            ordered[index].id = index
        }
        return ordered
    }

    static let echoMinimumRun = 3
    static let echoMaximumLag: TimeInterval = 0.5
    static let echoMaximumLead: TimeInterval = 0.15

    private static func isEchoOffset(mic: TimeInterval, system: TimeInterval) -> Bool {
        let offset = mic - system
        return offset >= -echoMaximumLead && offset <= echoMaximumLag
    }

    /// Drops mic words that repeat the system track: runs of at least three consecutive words that
    /// match a run of system words in order, each starting up to half a second after (or 0.15 s before) its counterpart.
    /// Acoustic echo always lags the call track; a mic copy that leads it is the far end echoing the user.
    static func removingEcho(from mic: [Segment], of system: [Segment]) -> [Segment] {
        let systemWords = system.flatMap(\.words).sorted { $0.start < $1.start }.map { (word: $0, key: normalised($0.text)) }
        guard !systemWords.isEmpty else { return mic }
        let micWords = mic.flatMap(\.words).map { (word: $0, key: normalised($0.text)) }
        var echoed = Set<Int>()
        for index in micWords.indices where !micWords[index].key.isEmpty && !echoed.contains(index) {
            let start = micWords[index].word.start
            var lower = 0
            var upper = systemWords.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if systemWords[middle].word.start < start - echoMaximumLag { lower = middle + 1 } else { upper = middle }
            }
            var candidate = lower
            while candidate < systemWords.count, systemWords[candidate].word.start <= start + echoMaximumLead {
                var length = 0
                while index + length < micWords.count, candidate + length < systemWords.count,
                      !micWords[index + length].key.isEmpty,
                      micWords[index + length].key == systemWords[candidate + length].key,
                      isEchoOffset(mic: micWords[index + length].word.start, system: systemWords[candidate + length].word.start) {
                    length += 1
                }
                if length >= echoMinimumRun {
                    echoed.formUnion(index..<(index + length))
                    break
                }
                candidate += 1
            }
        }
        guard !echoed.isEmpty else { return mic }

        var result: [Segment] = []
        var position = 0
        for segment in mic {
            guard !segment.words.isEmpty else {
                result.append(segment)
                continue
            }
            var groups: [[Word]] = []
            var previousKept = false
            for word in segment.words {
                defer { position += 1 }
                if echoed.contains(position) {
                    previousKept = false
                    continue
                }
                if previousKept {
                    groups[groups.count - 1].append(word)
                } else {
                    groups.append([word])
                }
                previousKept = true
            }
            if groups.count == 1, groups[0].count == segment.words.count {
                result.append(segment)
                continue
            }
            result += groups.map { words in
                Segment(
                    id: segment.id, track: segment.track, speaker: segment.speaker,
                    start: words[0].start, end: words[words.count - 1].end,
                    text: words.map(\.text).joined(separator: " "), words: words
                )
            }
        }
        return result
    }

    private static func normalised(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func split(_ segments: [Segment], turns: [SpeakerTurn]) -> [Segment] {
        var labels: [String: String] = [:]
        func label(_ start: TimeInterval, _ end: TimeInterval) -> String {
            let raw = turns.isEmpty ? "" : turn(start: start, end: end, in: turns).speaker
            if let existing = labels[raw] { return existing }
            let created = "S\(labels.count + 1)"
            labels[raw] = created
            return created
        }

        let ordered = segments.enumerated().sorted { lhs, rhs in
            lhs.element.start != rhs.element.start ? lhs.element.start < rhs.element.start : lhs.offset < rhs.offset
        }.map(\.element)

        var result: [Segment] = []
        for segment in ordered {
            guard !segment.words.isEmpty else {
                var segment = segment
                segment.speaker = label(segment.start, segment.end)
                result.append(segment)
                continue
            }
            var groups: [(speaker: String, words: [Word])] = []
            for word in segment.words {
                let speaker = label(word.start, word.end)
                if groups.last?.speaker == speaker {
                    groups[groups.count - 1].words.append(word)
                } else {
                    groups.append((speaker, [word]))
                }
            }
            if groups.count == 1 {
                var segment = segment
                segment.speaker = groups[0].speaker
                result.append(segment)
                continue
            }
            result += groups.map { group in
                Segment(
                    id: segment.id, track: segment.track, speaker: group.speaker,
                    start: group.words.first?.start ?? segment.start, end: group.words.last?.end ?? segment.end,
                    text: group.words.map(\.text).joined(separator: " "), words: group.words
                )
            }
        }
        return result
    }

    private static func turn(start: TimeInterval, end: TimeInterval, in turns: [SpeakerTurn]) -> SpeakerTurn {
        var best = turns[0]
        var bestOverlap = 0.0
        for candidate in turns {
            let overlap = min(end, candidate.end) - max(start, candidate.start)
            if overlap > bestOverlap {
                best = candidate
                bestOverlap = overlap
            }
        }
        if bestOverlap > 0 { return best }
        let midpoint = (start + end) / 2
        func distance(_ turn: SpeakerTurn) -> TimeInterval {
            midpoint < turn.start ? turn.start - midpoint : max(0, midpoint - turn.end)
        }
        return turns.min { distance($0) < distance($1) } ?? best
    }
}
