import Foundation
import MuninnCore
import SwiftUI

extension MeetingProgress {
    /// What Muninn is doing with the meeting, in a few words; nil when it is doing nothing or the meeting waits or failed.
    var title: String? {
        switch self {
        case .working(let work): work.stage.title
        case .queued: "Waiting its turn"
        case .preparingSpeechModel: "Getting the speech model ready"
        case .none, .waiting, .failed: nil
        }
    }
}

struct CommitTextField: View {
    let title: String
    let value: String
    let onCommit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { _, new in
                if !focused { text = new }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onSubmit(commit)
    }

    private func commit() {
        if text != value { onCommit(text) }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

enum DueDate {
    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    static func string(from date: Date) -> String {
        formatter().string(from: date)
    }

    /// Nil unless the text is a real calendar date written as `yyyy-MM-dd`.
    static func date(from text: String) -> Date? {
        let formatter = formatter()
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }
}
