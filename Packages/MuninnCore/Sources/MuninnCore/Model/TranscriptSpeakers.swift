import Foundation

/// One speaker a line can be given: its stored label and the name shown for it.
public struct SpeakerChoice: Equatable, Sendable {
    public var label: String
    public var title: String

    public init(label: String, title: String) {
        self.label = label
        self.title = title
    }
}

/// The speaker labels of a transcript, and the edits that move lines between them.
public enum TranscriptSpeakers {
    /// n for a label of the form `S<n>` (no sign, no leading zero, ASCII digits only), else nil.
    public static func number(of label: String) -> Int? {
        let bytes = Array(label.utf8)
        guard bytes.count >= 2, bytes[0] == UInt8(ascii: "S"), (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(bytes[1]),
              bytes.dropFirst(2).allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
        else { return nil }
        return Int(label.dropFirst())
    }

    /// Every label with a segment, once: "you" first, then the numbered labels by number, then the rest by first appearance.
    public static func ordered(in transcript: Transcript) -> [String] {
        var seen = Set<String>()
        var labels: [String] = []
        for segment in transcript.segments where seen.insert(segment.speaker).inserted {
            labels.append(segment.speaker)
        }
        let numbered = labels.compactMap { label in number(of: label).map { (label, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
        let others = labels.filter { $0 != Transcript.youSpeaker && number(of: $0) == nil }
        return (labels.contains(Transcript.youSpeaker) ? [Transcript.youSpeaker] : []) + numbered + others
    }

    /// The next free `S<n>`: above every number a segment, a stored name or a recap owner still carries.
    public static func newLabel(transcript: Transcript, speakerNames: [String: String], recapOwners: [String]) -> String {
        let used = transcript.segments.map(\.speaker) + Array(speakerNames.keys) + recapOwners
        return "S\((used.compactMap { number(of: $0) }.max() ?? 0) + 1)"
    }

    /// The transcript with the chosen segments given to `speaker`; unknown ids are ignored.
    public static func changing(_ segmentIDs: Set<Int>, to speaker: String, in transcript: Transcript) -> Transcript {
        var result = transcript
        for index in result.segments.indices where segmentIDs.contains(result.segments[index].id) {
            result.segments[index].speaker = speaker
        }
        return result
    }

    /// The speaker every listed segment has, or nil when they differ or none is found.
    public static func commonSpeaker(of segmentIDs: Set<Int>, in transcript: Transcript) -> String? {
        let speakers = Set(transcript.segments.filter { segmentIDs.contains($0.id) }.map(\.speaker))
        return speakers.count == 1 ? speakers.first : nil
    }

    /// "you" and every speaker with lines; names shown more than once get their label appended.
    public static func menuChoices(transcript: Transcript, speakerNames: [String: String], userName: String) -> [SpeakerChoice] {
        let labels = [Transcript.youSpeaker] + ordered(in: transcript).filter { $0 != Transcript.youSpeaker }
        let choices = choices(for: labels, speakerNames: speakerNames, userName: userName)
        let counts = Dictionary(choices.map { ($0.title, 1) }, uniquingKeysWith: +)
        return choices.map { counts[$0.title, default: 0] > 1 ? SpeakerChoice(label: $0.label, title: "\($0.title) (\($0.label))") : $0 }
    }

    /// The speakers to name in the header: only for a meeting with no people, where the transcript is all there is to go on.
    public static func headerSpeakers(meeting: Meeting, transcript: Transcript?, userName: String) -> [SpeakerChoice] {
        guard let transcript, meeting.attendees.allSatisfy(\.isResource) else { return [] }
        return choices(for: ordered(in: transcript), speakerNames: meeting.speakerNames, userName: userName)
    }

    private static func choices(for labels: [String], speakerNames: [String: String], userName: String) -> [SpeakerChoice] {
        labels.map {
            SpeakerChoice(label: $0, title: SummaryRequestBuilder.displayName($0, speakerNames: speakerNames, userName: userName))
        }
    }
}
