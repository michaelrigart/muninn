import MuninnCore
import MuninnSystem
import SwiftUI

enum SettingsValidation {
    static func baseURL(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else {
            return "Enter an http or https URL, or leave it empty."
        }
        return nil
    }

    static func notePattern(_ text: String) -> String? {
        text.contains("{title}") ? nil : "The pattern must contain {title}."
    }

    static func hotkey(_ text: String) -> String? {
        guard let hotkey = HotkeyText.parse(text), HotkeyParser.carbon(hotkey) != nil else {
            return "Use modifiers and a key, for example control+option+command+F. At least one of control, option or command is required."
        }
        return nil
    }

    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func domain(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = value.range(of: "://") { value = String(value[scheme.upperBound...]) }
        if let slash = value.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { value = String(value[..<slash]) }
        if let at = value.lastIndex(of: "@") { value = String(value[value.index(after: at)...]) }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
    }

    static func commaList(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

@MainActor
final class Debouncer {
    private var task: Task<Void, Never>?

    func schedule(after delay: Duration = .milliseconds(500), _ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// Lets a view save every pending text edit in its fields at once, synchronously.
@MainActor
final class FieldFlusher {
    private var flushes: [UUID: () -> Void] = [:]

    func register(_ id: UUID, _ flush: @escaping () -> Void) {
        flushes[id] = flush
    }

    func unregister(_ id: UUID) {
        flushes[id] = nil
    }

    func flushAll() {
        for flush in flushes.values { flush() }
    }
}

/// A text field that validates and saves after a pause in typing, on submit, and when it loses focus.
/// It writes only text the user changed, and adopts the stored value whenever it holds no unsaved edit.
struct DebouncedText: View {
    let title: String
    let value: String
    var prompt: String?
    var multiline = false
    var validate: (String) -> String? = { _ in nil }
    var flusher: FieldFlusher?
    let commit: (String) -> Void

    @ViewState private var text: String
    @ViewState private var synced: String
    @ViewState private var error: String?
    @ViewState private var ownCommit = false
    @ViewState private var registration = UUID()
    @ViewState private var debouncer = Debouncer()
    @FocusState private var focused: Bool

    init(
        _ title: String,
        value: String,
        prompt: String? = nil,
        multiline: Bool = false,
        validate: @escaping (String) -> String? = { _ in nil },
        flusher: FieldFlusher? = nil,
        commit: @escaping (String) -> Void
    ) {
        self.title = title
        self.value = value
        self.prompt = prompt
        self.multiline = multiline
        self.validate = validate
        self.flusher = flusher
        self.commit = commit
        _text = ViewState(initialValue: value)
        _synced = ViewState(initialValue: value)
    }

    /// True while the text holds an edit that has not been saved.
    private var dirty: Bool { text != synced }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if multiline {
                Text(title)
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .frame(minHeight: 120)
                    .focused($focused)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            } else {
                TextField(title, text: $text, prompt: prompt.map { Text($0) })
                    .focused($focused)
                    .onSubmit(apply)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: text) {
            if dirty { debouncer.schedule { apply() } }
        }
        .onChange(of: focused) {
            if !focused {
                ownCommit = false
                apply()
            }
        }
        .onChange(of: value) {
            if ownCommit {
                ownCommit = false
                if focused { return }
            }
            adopt(value)
        }
        .onAppear { flusher?.register(registration) { apply() } }
        .onDisappear {
            flusher?.unregister(registration)
            apply()
        }
    }

    private func adopt(_ incoming: String) {
        guard !dirty, text != incoming else { return }
        debouncer.cancel()
        synced = incoming
        text = incoming
        error = nil
    }

    private func apply() {
        debouncer.cancel()
        guard dirty else {
            error = nil
            return
        }
        if let message = validate(text) {
            error = message
            return
        }
        error = nil
        synced = text
        ownCommit = true
        commit(text)
    }
}

struct ClientDomainsEditor: View {
    let value: [String: String]
    let commit: ([String: String]) -> Void

    private struct Row: Identifiable, Equatable {
        let id = UUID()
        var domain: String
        var client: String

        var normalisedDomain: String { SettingsValidation.domain(domain) }
        var trimmedClient: String { client.trimmingCharacters(in: .whitespaces) }
        var isBlank: Bool { normalisedDomain.isEmpty && trimmedClient.isEmpty }
        var isComplete: Bool { !normalisedDomain.isEmpty && !trimmedClient.isEmpty }
    }

    @ViewState private var rows: [Row]
    @ViewState private var debouncer = Debouncer()

    init(value: [String: String], commit: @escaping ([String: String]) -> Void) {
        self.value = value
        self.commit = commit
        _rows = ViewState(initialValue: value.sorted { $0.key < $1.key }.map { Row(domain: $0.key, client: $0.value) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($rows) { $row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        TextField("Domain", text: $row.domain, prompt: Text("example.com"))
                        TextField("Client", text: $row.client, prompt: Text("Client name"))
                        Button {
                            rows.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this domain")
                    }
                    if let message = issue(for: row) {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(message.hasPrefix("Duplicate") ? .orange : .red)
                    }
                }
            }
            Button("Add domain") {
                rows.append(Row(domain: "", client: ""))
            }
        }
        .onChange(of: rows) {
            debouncer.schedule { save() }
        }
        .onDisappear(perform: save)
    }

    private func issue(for row: Row) -> String? {
        if row.isBlank { return nil }
        if !row.isComplete { return "Enter both a domain and a client. This row is not saved." }
        let duplicates = rows.filter { $0.isComplete && $0.normalisedDomain == row.normalisedDomain }
        if duplicates.count > 1, duplicates.last?.id != row.id {
            return "Duplicate domain: the last row for \(row.normalisedDomain) is used."
        }
        return nil
    }

    private func save() {
        debouncer.cancel()
        var result: [String: String] = [:]
        for row in rows where row.isComplete {
            result[row.normalisedDomain] = row.trimmedClient
        }
        if result != value { commit(result) }
    }
}
