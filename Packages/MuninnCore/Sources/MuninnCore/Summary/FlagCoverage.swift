public enum FlagCoverage {
    /// Ids of the segments the flags fall in, in transcript order. A flag inside overlapping segments maps to the longest one; a flag in a gap maps to the preceding segment,
    /// one before the first segment to the first, and one past the end to the last.
    public static func flaggedSegmentIDs(_ flags: [Flag], in transcript: Transcript) -> [Int] {
        guard let first = transcript.segments.first else { return [] }
        var ids = Set<Int>()
        for flag in flags {
            let containing = transcript.segments.filter { $0.start <= flag.offset && flag.offset < $0.end }
            let segment = containing.max(by: { $0.end - $0.start < $1.end - $1.start })
                ?? transcript.segments.last(where: { $0.start <= flag.offset })
                ?? first
            ids.insert(segment.id)
        }
        return transcript.segments.map(\.id).filter(ids.contains)
    }

    public static func ensureCovered(_ summary: Summary, uncovered: [Int], clean: CleanTranscript) -> Summary {
        guard !uncovered.isEmpty else { return summary }
        let bullets = uncovered.compactMap { id in
            clean.segments.first(where: { $0.id == id }).map { Bullet(text: $0.text, sources: [id]) }
        }
        guard !bullets.isEmpty else { return summary }
        var result = summary
        result.subjects.append(Subject(title: title(for: summary.language), bullets: bullets, actions: []))
        return result
    }

    private static func title(for language: String) -> String {
        switch language.lowercased().prefix(2) {
        case "nl": "Gemarkeerde momenten"
        case "fr": "Moments signalés"
        default: "Flagged moments"
        }
    }
}
