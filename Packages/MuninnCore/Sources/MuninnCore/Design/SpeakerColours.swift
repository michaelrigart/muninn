import Foundation

/// Assigns each speaker, or each person, one of the palette's speaker colours.
public enum SpeakerColours {
    public static let count = 6

    /// "you" is always colour 0; the others take colours 1 to 5 in order of first appearance.
    public static func indices(for transcript: Transcript) -> [String: Int] {
        var result = [Transcript.youSpeaker: 0]
        var others = 0
        for segment in transcript.segments where result[segment.speaker] == nil {
            result[segment.speaker] = 1 + (others % (count - 1))
            others += 1
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
