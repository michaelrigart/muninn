import Foundation

/// Assigns each speaker, or each person, one of the palette's speaker colours.
public enum SpeakerColours {
    public static let count = 6

    /// "you" is always colour 0; a label `S<n>` takes colour `1 + (n - 1) % 5`, so a line moving between speakers shifts no
    /// other speaker's colour. Any other label takes the colours after the numbered ones, in order of first appearance.
    public static func indices(for transcript: Transcript) -> [String: Int] {
        var result = [Transcript.youSpeaker: 0]
        let highest = transcript.segments.compactMap { TranscriptSpeakers.number(of: $0.speaker) }.max() ?? 0
        var others = 0
        for segment in transcript.segments where result[segment.speaker] == nil {
            if let number = TranscriptSpeakers.number(of: segment.speaker) {
                result[segment.speaker] = 1 + (number - 1) % (count - 1)
            } else {
                result[segment.speaker] = 1 + (highest + others) % (count - 1)
                others += 1
            }
        }
        return result
    }

    /// A stable colour for a person: FNV-1a over the name, or the address when there is no name.
    public static func personIndex(name: String, email: String) -> Int {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (trimmedName.isEmpty ? email.trimmingCharacters(in: .whitespacesAndNewlines) : trimmedName).lowercased()
        var hash: UInt32 = 0x811C9DC5
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return Int(hash % UInt32(count))
    }
}
