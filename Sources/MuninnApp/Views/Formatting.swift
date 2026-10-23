import Foundation
import MuninnCore
import SwiftUI

extension WaitReason {
    var text: String {
        switch self {
        case .studioUnreachable: "Waiting for the Network Mac"
        case .studioNotConfigured: "Set the network Mac's address in Settings"
        case .memoryPressure: "Waiting: memory pressure"
        case .claudeKeyMissing: "Waiting: no Claude API key"
        case .recording: "Waiting for the recording to end"
        }
    }
}

extension ProcessingStatus {
    var label: String {
        switch self {
        case .recording: "Recording"
        case .transcribing: "Transcribing"
        case .diarizing: "Identifying speakers"
        case .cleaning: "Cleaning up"
        case .summarizing: "Summarising"
        case .waiting(let reason): reason.text
        case .ready: "Ready"
        case .failed: "Failed"
        }
    }

    var symbol: String? {
        switch self {
        case .recording: "record.circle"
        case .transcribing, .diarizing, .cleaning, .summarizing: "hourglass"
        case .waiting: "pause.circle"
        case .ready: nil
        case .failed: "exclamationmark.triangle"
        }
    }
}

struct CommitTextField: View {
    let title: String
    let value: String
    let onCommit: (String) -> Void
    @ViewState private var text = ""
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
