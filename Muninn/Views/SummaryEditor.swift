import MuninnCore
import SwiftUI

struct SummaryEditor: View {
    let meeting: Meeting
    let summary: Summary?
    let onEdit: (Summary) -> Void
    let onSource: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let summary {
                    ForEach(Array(summary.subjects.indices), id: \.self) { index in
                        subjectView(index)
                    }
                    Button {
                        mutate { $0.subjects.append(Subject(title: "New subject", bullets: [], actions: [])) }
                    } label: {
                        Label("Add subject", systemImage: "plus")
                    }
                } else if meeting.status == .ready {
                    Text("No recap yet.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func mutate(_ change: (inout Summary) -> Void) {
        guard var updated = summary else { return }
        change(&updated)
        onEdit(updated)
    }

    private func subjectView(_ s: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Subject", text: subjectTitle(s))
                    .textFieldStyle(.plain)
                    .font(.title3.bold())
                Button {
                    mutate { if $0.subjects.indices.contains(s) { $0.subjects.remove(at: s) } }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove subject")
            }
            ForEach(Array((summary?.subjects[safe: s]?.bullets ?? []).indices), id: \.self) { b in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        TextField("Bullet", text: bulletText(s, b), axis: .vertical)
                            .textFieldStyle(.plain)
                        sourceChips(summary?.subjects[safe: s]?.bullets[safe: b]?.sources ?? [])
                        removeButton { if $0.subjects[safe: s]?.bullets[safe: b] != nil { $0.subjects[s].bullets.remove(at: b) } }
                    }
                    unsourcedMarker(summary?.subjects[safe: s]?.bullets[safe: b]?.sources ?? [])
                }
            }
            ForEach(Array((summary?.subjects[safe: s]?.actions ?? []).indices), id: \.self) { a in
                actionRow(s, a)
            }
            HStack(spacing: 12) {
                Button {
                    mutate { if $0.subjects.indices.contains(s) { $0.subjects[s].bullets.append(Bullet(text: "", sources: [])) } }
                } label: {
                    Label("Bullet", systemImage: "plus")
                }
                Button {
                    mutate { if $0.subjects.indices.contains(s) { $0.subjects[s].actions.append(ActionPoint(owner: "", text: "", due: nil, sources: [])) } }
                } label: {
                    Label("Action", systemImage: "plus")
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func actionRow(_ s: Int, _ a: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            actionFields(s, a)
            unsourcedMarker(summary?.subjects[safe: s]?.actions[safe: a]?.sources ?? [])
        }
    }

    @ViewBuilder
    private func unsourcedMarker(_ sources: [Int]) -> some View {
        if sources.isEmpty {
            Label("No transcript source — check this", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func actionFields(_ s: Int, _ a: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark.square")
                .foregroundStyle(.secondary)
            TextField("Owner", text: actionOwner(s, a))
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
            TextField("Action", text: actionText(s, a), axis: .vertical)
                .textFieldStyle(.plain)
            dueControl(s, a)
            sourceChips(summary?.subjects[safe: s]?.actions[safe: a]?.sources ?? [])
            removeButton { if $0.subjects[safe: s]?.actions[safe: a] != nil { $0.subjects[s].actions.remove(at: a) } }
        }
    }

    private func removeButton(_ remove: @escaping (inout Summary) -> Void) -> some View {
        Button {
            mutate(remove)
        } label: {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help("Remove")
    }

    private func sourceChips(_ sources: [Int]) -> some View {
        HStack(spacing: 4) {
            ForEach(sources, id: \.self) { id in
                Button("S\(id)") { onSource(id) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Show in transcript")
            }
        }
    }

    private func subjectTitle(_ s: Int) -> Binding<String> {
        Binding(
            get: { summary?.subjects[safe: s]?.title ?? "" },
            set: { value in mutate { if $0.subjects.indices.contains(s) { $0.subjects[s].title = value } } }
        )
    }

    private func bulletText(_ s: Int, _ b: Int) -> Binding<String> {
        Binding(
            get: { summary?.subjects[safe: s]?.bullets[safe: b]?.text ?? "" },
            set: { value in
                mutate {
                    if $0.subjects[safe: s]?.bullets[safe: b] != nil { $0.subjects[s].bullets[b].text = value }
                }
            }
        )
    }

    private func actionOwner(_ s: Int, _ a: Int) -> Binding<String> {
        Binding(
            get: { summary?.subjects[safe: s]?.actions[safe: a]?.owner ?? "" },
            set: { value in
                mutate {
                    if $0.subjects[safe: s]?.actions[safe: a] != nil { $0.subjects[s].actions[a].owner = value }
                }
            }
        )
    }

    private func actionText(_ s: Int, _ a: Int) -> Binding<String> {
        Binding(
            get: { summary?.subjects[safe: s]?.actions[safe: a]?.text ?? "" },
            set: { value in
                mutate {
                    if $0.subjects[safe: s]?.actions[safe: a] != nil { $0.subjects[s].actions[a].text = value }
                }
            }
        )
    }

    private func dueControl(_ s: Int, _ a: Int) -> some View {
        let due = summary?.subjects[safe: s]?.actions[safe: a]?.due
        return HStack(spacing: 6) {
            Toggle("Due date", isOn: hasDue(s, a))
                .toggleStyle(.checkbox)
            if let due {
                if let date = DueDate.date(from: due) {
                    DatePicker("Due date", selection: dueDate(s, a, fallback: date), displayedComponents: .date)
                        .labelsHidden()
                } else {
                    Button("“\(due)” is not a date: pick one") { setDue(s, a, DueDate.string(from: Date())) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.orange)
                }
            }
        }
        .font(.callout)
    }

    private func hasDue(_ s: Int, _ a: Int) -> Binding<Bool> {
        Binding(
            get: { summary?.subjects[safe: s]?.actions[safe: a]?.due != nil },
            set: { on in setDue(s, a, on ? DueDate.string(from: Date()) : nil) }
        )
    }

    private func dueDate(_ s: Int, _ a: Int, fallback: Date) -> Binding<Date> {
        Binding(
            get: { summary?.subjects[safe: s]?.actions[safe: a]?.due.flatMap(DueDate.date(from:)) ?? fallback },
            set: { setDue(s, a, DueDate.string(from: $0)) }
        )
    }

    private func setDue(_ s: Int, _ a: Int, _ due: String?) {
        mutate {
            if $0.subjects[safe: s]?.actions[safe: a] != nil { $0.subjects[s].actions[a].due = due }
        }
    }
}
