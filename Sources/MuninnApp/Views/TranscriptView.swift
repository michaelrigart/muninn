import MuninnCore
import SwiftUI

private enum TranscriptMode: String, CaseIterable, Identifiable {
    case clean = "Clean"
    case changes = "Show changes"
    case verbatim = "Verbatim"

    var id: String { rawValue }
}

struct TranscriptView: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting
    let transcript: Transcript?
    let clean: CleanTranscript?
    @Binding var target: Int?
    let report: (Error) -> Void

    @ViewState private var mode = TranscriptMode.clean
    @ViewState private var highlighted: Int?

    var body: some View {
        if let transcript {
            let flagged = Set(FlagCoverage.flaggedSegmentIDs(meeting.flags, in: transcript))
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    ForEach(TranscriptMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .padding(.bottom, 8)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(transcript.segments) { segment in
                                row(segment, flagged: flagged.contains(segment.id))
                                    .id(segment.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                    .onChange(of: target) { _, _ in scroll(proxy) }
                    .task { scroll(proxy) }
                }
            }
        } else {
            ContentUnavailableView("No transcript yet", systemImage: "text.alignleft")
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let id = target else { return }
        highlighted = id
        target = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation { proxy.scrollTo(id, anchor: .center) }
            try? await Task.sleep(for: .seconds(2))
            if highlighted == id { highlighted = nil }
        }
    }

    private func row(_ segment: Segment, flagged: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(timestamp(segment.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
            SpeakerButton(
                name: SummaryRequestBuilder.displayName(segment.speaker, speakerNames: meeting.speakerNames, userName: model.resolvedUserName),
                isCustom: meeting.speakerNames[segment.speaker] != nil
            ) { newName in
                rename(segment.speaker, to: newName)
            }
            .frame(width: 120, alignment: .leading)
            content(segment)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(flagged ? "🚩" : "")
                .frame(width: 20)
        }
        .padding(.vertical, 3)
        .background(highlighted == segment.id ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func content(_ segment: Segment) -> Text {
        let cleaned = clean?.text(for: segment) ?? segment.text
        switch mode {
        case .verbatim:
            return Text(segment.text)
        case .clean:
            return Text(cleaned)
        case .changes:
            var result = AttributedString()
            for (index, token) in ChangeView.tokens(verbatim: segment.text, clean: cleaned).enumerated() {
                var piece = AttributedString((index == 0 ? "" : " ") + token.text)
                if token.removed {
                    piece.strikethroughStyle = .single
                    piece.foregroundColor = Color.primary.opacity(0.45)
                }
                result.append(piece)
            }
            return Text(result)
        }
    }

    private func rename(_ speaker: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var names: [String: String] = [:]
        do {
            try model.mutate(meeting.id) { current in
                if trimmed.isEmpty {
                    current.speakerNames.removeValue(forKey: speaker)
                } else {
                    current.speakerNames[speaker] = trimmed
                }
                names = current.speakerNames
            }
            guard let transcript else { return }
            try model.store.saveTranscript(transcript, for: meeting.id, speakerNames: names, userName: model.resolvedUserName)
            if let clean {
                try model.store.saveClean(clean, transcript: transcript, for: meeting.id, speakerNames: names, userName: model.resolvedUserName)
            }
        } catch {
            report(error)
        }
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

private struct SpeakerButton: View {
    let name: String
    let isCustom: Bool
    let onRename: (String) -> Void

    @ViewState private var editing = false
    @ViewState private var draft = ""

    var body: some View {
        Button {
            draft = isCustom ? name : ""
            editing = true
        } label: {
            Text(name)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help("Rename speaker")
        .popover(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rename \(name)")
                    .font(.headline)
                TextField("Name", text: $draft)
                    .frame(width: 200)
                    .onSubmit(commit)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Save", action: commit)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
    }

    private func commit() {
        onRename(draft)
        editing = false
    }
}
