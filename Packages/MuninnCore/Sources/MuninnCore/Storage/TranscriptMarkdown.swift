import Foundation

public enum TranscriptMarkdown {
    public static func render(segments: [(id: Int, start: TimeInterval, speaker: String, text: String)], title: String) -> String {
        var blocks = ["# \(title)"]
        blocks += segments.map { "**[\(timestamp($0.start))] \($0.speaker):** \($0.text)" }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
