import AppKit
import AVFoundation
import MuninnCore
import MuninnSpeech
import MuninnSystem
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let problem = model.settingsProblem {
                ProblemCard(
                    problem: problem,
                    compact: true,
                    handlers: model.problemHandlers(tryAgain: model.failedSettings.map { failed in { model.saveSettings(failed) } }),
                    showInActivity: { model.showInActivity(problem) },
                    onDismiss: { model.dismissSettingsProblem() }
                )
                .padding(.horizontal, Space.m)
                .padding(.top, Space.s)
            }
            tabs
        }
        .frame(width: 560, height: 520)
    }

    private var tabs: some View {
        TabView(selection: $model.settingsTab) {
            EnginesTab()
                .tabItem { Label("Engines", systemImage: "cpu") }
                .tag(SettingsTab.engines)
            AccountsTab()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag(SettingsTab.accounts)
            ObsidianTab()
                .tabItem { Label("Obsidian", systemImage: "folder") }
                .tag(SettingsTab.obsidian)
            RecordingTab()
                .tabItem { Label("Recording", systemImage: "record.circle") }
                .tag(SettingsTab.recording)
            DictionaryTab()
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
                .tag(SettingsTab.dictionary)
            PermissionsTab()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(SettingsTab.permissions)
        }
    }
}

// MARK: - Engines

private struct EnginesTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Picker("Default engine", selection: model.settingsBinding(\.defaultEngine)) {
                ForEach(EngineKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle("Use LLM cleanup", isOn: model.settingsBinding(\.useLLMCleanup))

            EndpointSection(title: EngineKind.macbook.displayName, keyPath: \.macbook)
            EndpointSection(title: EngineKind.studio.displayName, keyPath: \.studio, urlPrompt: "http://my-mac.local:11434")
            ClaudeSection()
        }
        .formStyle(.grouped)
    }
}

private struct EndpointSection: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let keyPath: WritableKeyPath<MuninnCore.Settings, EngineEndpoint>
    var urlPrompt: String?

    var body: some View {
        let endpoint = model.settings[keyPath: keyPath]
        Section(title) {
            Picker("API", selection: model.settingsBinding(keyPath.appending(path: \.api))) {
                Text("Ollama").tag(EndpointAPI.ollama)
                Text("OpenAI compatible").tag(EndpointAPI.openAICompatible)
            }
            DebouncedText("Base URL", value: endpoint.baseURL, prompt: urlPrompt, validate: SettingsValidation.baseURL) { text in
                set(\.baseURL, text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if urlPrompt != nil, endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Set the network Mac's address to use it. Until then it is skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DebouncedText("Model", value: endpoint.model) { text in
                set(\.model, text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            DebouncedText("Keep alive", value: endpoint.keepAlive) { text in
                set(\.keepAlive, text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    private func set(_ field: WritableKeyPath<EngineEndpoint, String>, _ value: String) {
        model.updateSettings { $0[keyPath: keyPath][keyPath: field] = value }
    }
}

private struct ClaudeSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var apiKey = ""
    @State private var issue: SettingsIssue?

    private static let efforts = ["low", "medium", "high", "xhigh", "max"]

    var body: some View {
        let effort = model.settings.claudeEffort
        Section("Claude") {
            DebouncedText("Model", value: model.settings.claudeModel) { text in
                model.updateSettings { $0.claudeModel = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            Picker("Effort", selection: model.settingsBinding(\.claudeEffort)) {
                ForEach(Self.efforts.contains(effort) ? Self.efforts : Self.efforts + [effort], id: \.self) { Text($0) }
            }
            SecureField("API key", text: $apiKey, prompt: Text(model.claudeKeyPresent ? "Replace the saved key" : "sk-ant-..."))
                .onSubmit(save)
            HStack {
                if model.claudeKeyPresent {
                    Label("Key saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Save", action: save)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove", role: .destructive, action: remove)
                    .disabled(!model.claudeKeyPresent)
            }
            if let issue {
                SettingsIssueCard(issue: issue, dismiss: { self.issue = nil })
            }
        }
        .onAppear(perform: model.refreshClaudeKey)
    }

    private func save() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try model.secrets.set(key, for: LiveEnvironmentProbe.claudeKeyName)
            apiKey = ""
            issue = nil
            model.refreshClaudeKey()
        } catch {
            issue = .keychainWrite(error, area: .engines, activity: model.activity, retry: save)
        }
    }

    private func remove() {
        do {
            try model.secrets.delete(LiveEnvironmentProbe.claudeKeyName)
            apiKey = ""
            issue = nil
            model.refreshClaudeKey()
        } catch {
            issue = .keychainWrite(error, area: .engines, activity: model.activity, retry: remove)
        }
    }
}

/// A problem a Settings pane shows under its fields, with what runs the action again.
private struct SettingsIssue {
    let problem: Problem
    var retry: (() -> Void)?

    static func notice(_ title: String) -> SettingsIssue {
        SettingsIssue(problem: .notice(title))
    }

    /// A Keychain write that failed, recorded in Activity.
    @MainActor
    static func keychainWrite(_ error: Error, area: ActivityArea, activity: ActivityCenter, retry: @escaping () -> Void) -> SettingsIssue {
        let details = ProblemTranslator.problem(for: error, in: ProblemContext(stage: .savingSettings)).details
        let problem = Problems.keychainUnwritable(details: details)
        activity.record(problem, area: area)
        return SettingsIssue(problem: problem, retry: retry)
    }
}

private struct SettingsIssueCard: View {
    @EnvironmentObject private var model: AppModel
    let issue: SettingsIssue
    let dismiss: () -> Void

    var body: some View {
        ProblemCard(
            problem: issue.problem,
            role: issue.problem.severity == .warning ? .attention : nil,
            compact: true,
            handlers: model.problemHandlers(tryAgain: issue.retry),
            showInActivity: { model.showInActivity(issue.problem) },
            onDismiss: dismiss
        )
    }
}

// MARK: - Accounts

private struct AccountsTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var signingIn: SigningIn?
    @State private var statuses: [String: SignInStatus] = [:]
    @State private var issue: SettingsIssue?
    @State private var flusher = FieldFlusher()

    private enum SignInStatus: Equatable {
        case signedIn
        case signedOut
        case unreadable(Problem)

        var isUnreadable: Bool {
            if case .unreadable = self { true } else { false }
        }
    }

    private struct SigningIn: Identifiable {
        let account: AccountSettings
        var id: String { account.id }
    }

    var body: some View {
        Form {
            Section("You") {
                DebouncedText("Your name", value: model.settings.userName, prompt: model.resolvedUserName, flusher: flusher) { text in
                    model.updateSettings { $0.userName = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                Text("Your lines in transcripts and recaps carry this name. Empty uses the first name of this Mac's user.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.settings.accounts, id: \.id) { account in
                let status = statuses[account.id] ?? .signedOut
                Section(account.displayName) {
                    DebouncedText("Name", value: account.displayName, flusher: flusher) { text in
                        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        update(account.id) { $0.displayName = name }
                    }
                    DebouncedText("Client ID", value: account.clientID, flusher: flusher) { text in
                        update(account.id) { $0.clientID = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    DebouncedText("Tenant", value: account.tenant, flusher: flusher) { text in
                        update(account.id) { $0.tenant = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    DebouncedText("Vault area", value: account.vaultArea, flusher: flusher) { text in
                        update(account.id) { $0.vaultArea = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    DebouncedText(
                        "Your addresses (comma separated)",
                        value: account.selfAddresses.joined(separator: ", "),
                        flusher: flusher
                    ) { text in
                        update(account.id) { $0.selfAddresses = SettingsValidation.commaList(text) }
                    }
                    if case .unreadable(let problem) = status {
                        ProblemCard(
                            problem: problem,
                            compact: true,
                            handlers: model.problemHandlers(tryAgain: refresh),
                            showInActivity: { model.showInActivity(problem) }
                        )
                    }
                    let signInExpired = status == .signedIn && model.signInNeeded.contains(account.id)
                    if signInExpired {
                        let problem = Problems.signInExpired(account: account.displayName)
                        ProblemCard(
                            problem: problem,
                            compact: true,
                            handlers: signInHandlers(account.id),
                            showInActivity: { model.showInActivity(problem) }
                        )
                    }
                    HStack {
                        switch status {
                        case .signedIn where signInExpired:
                            EmptyView()
                        case .signedIn:
                            Label("Signed in", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .signedOut:
                            Text("Not signed in").foregroundStyle(.secondary)
                        case .unreadable:
                            EmptyView()
                        }
                        Spacer()
                        if status == .signedIn {
                            Button("Sign out") { signOut(account) }
                        }
                        Button(status == .signedIn ? "Sign in again" : "Sign in") {
                            signIn(account.id)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Remove Account…", role: .destructive) { remove(account) }
                    }
                }
            }
            Section {
                Button("Add Account", action: add)
            }
            if let issue {
                SettingsIssueCard(issue: issue, dismiss: { self.issue = nil })
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .sheet(item: $signingIn, onDismiss: refresh) { request in
            let account = request.account
            SignInSheet(account: account, secrets: model.secrets, activity: model.activity) { addresses in
                update(account.id) { $0.selfAddresses = Self.merge($0.selfAddresses, addresses) }
                model.signInNeeded.remove(account.id)
                model.refreshCalendar()
            }
        }
    }

    private func add() {
        flusher.flushAll()
        guard let name = Self.askForName() else { return }
        let id = AccountManagement.newID(
            displayName: name, accounts: model.settings.accounts, retired: model.settings.retiredAccountIDs, meetings: model.meetings
        )
        let account = AccountSettings(id: id, displayName: name, vaultArea: name, tenant: "organizations", clientID: "", selfAddresses: [])
        model.updateSettings { $0.accounts.append(account) }
        issue = nil
        refresh()
    }

    private func remove(_ account: AccountSettings) {
        flusher.flushAll()
        guard AccountManagement.busyMeetings(for: account.id, in: model.meetings).isEmpty else {
            issue = .notice(AccountManagement.removalRefusal(accountName: account.displayName))
            return
        }
        let answer = Alerts.ask(
            "Remove \(account.displayName)?",
            "This signs the account out and deletes its stored sign-in from the Keychain. Meetings already recorded keep their data.",
            buttons: ["Remove Account", "Cancel"],
            destructive: 0
        )
        guard answer == 0 else { return }
        do {
            try TokenAccess.signOut(account: account.id, store: KeychainTokenStore(secrets: model.secrets))
        } catch {
            issue = .keychainWrite(error, area: .accounts, activity: model.activity) { remove(account) }
            refresh()
            return
        }
        model.updateSettings { AccountManagement.remove(account.id, from: &$0) }
        model.calendar.forget(account.id)
        model.signInNeeded.remove(account.id)
        model.refreshCalendar()
        issue = nil
        refresh()
    }

    private static func askForName() -> String? {
        let alert = Alerts.makeAlert()
        alert.messageText = "Add an account"
        alert.informativeText = "Name it after the organisation whose calendar it signs in to, for example Work or Acme."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func update(_ id: String, _ change: (inout AccountSettings) -> Void) {
        model.updateSettings { settings in
            guard let index = settings.accounts.firstIndex(where: { $0.id == id }) else { return }
            change(&settings.accounts[index])
        }
    }

    private func signInHandlers(_ id: String) -> ProblemHandlers {
        var handlers = model.problemHandlers()
        handlers.signInAgain = { signIn(id) }
        return handlers
    }

    private func signIn(_ id: String) {
        flusher.flushAll()
        guard let account = model.settings.accounts.first(where: { $0.id == id }) else { return }
        guard !account.clientID.isEmpty, !account.tenant.isEmpty else {
            issue = .notice("Enter a client ID and tenant for \(account.displayName) first")
            return
        }
        issue = nil
        signingIn = SigningIn(account: account)
    }

    private func refresh() {
        let store = KeychainTokenStore(secrets: model.secrets)
        var result: [String: SignInStatus] = [:]
        for account in model.settings.accounts {
            do {
                result[account.id] = try store.load(account: account.id) == nil ? .signedOut : .signedIn
            } catch {
                let context = ProblemContext(stage: .signingIn, accountName: account.displayName)
                let problem = ProblemTranslator.problem(for: error, in: context).with(actions: [.tryAgain])
                if statuses[account.id]?.isUnreadable != true {
                    model.activity.record(problem, area: .accounts)
                }
                result[account.id] = .unreadable(problem)
            }
        }
        statuses = result
    }

    private func signOut(_ account: AccountSettings) {
        do {
            try TokenAccess.signOut(account: account.id, store: KeychainTokenStore(secrets: model.secrets))
            model.signInNeeded.remove(account.id)
            model.activity.record(.info, .accounts, "Signed out of \(account.displayName)", details: ProblemDetails(account: account.displayName))
            issue = nil
        } catch {
            issue = .keychainWrite(error, area: .accounts, activity: model.activity) { signOut(account) }
        }
        refresh()
    }

    private static func merge(_ existing: [String], _ new: [String]) -> [String] {
        var seen = Set(existing.map { $0.lowercased() })
        return existing + new.filter { seen.insert($0.lowercased()).inserted }
    }
}

// MARK: - Obsidian

private struct ObsidianTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Vault") {
                HStack {
                    DebouncedText("Vault path", value: model.settings.vaultPath, prompt: "Choose your Obsidian vault folder") { text in
                        model.updateSettings { $0.vaultPath = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    Button("Choose...", action: chooseVault)
                }
                DebouncedText("Note pattern", value: model.settings.notePattern, validate: SettingsValidation.notePattern) { text in
                    model.updateSettings { $0.notePattern = text }
                }
                Text("Placeholders: {area}, {client}, {date}, {title}. {title} is required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DebouncedText("Inbox folder", value: model.settings.inboxFolder) { text in
                    model.updateSettings { $0.inboxFolder = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
            }
            Section("Filing") {
                Toggle("File to Obsidian automatically", isOn: model.settingsBinding(\.autoFileToObsidian))
                Toggle("Include the transcript", isOn: model.settingsBinding(\.vaultIncludesTranscript))
                Toggle("Include the audio", isOn: model.settingsBinding(\.vaultIncludesAudio))
            }
            Section("Client domains") {
                ClientDomainsEditor(value: model.settings.clientDomains) { domains in
                    model.updateSettings { $0.clientDomains = domains }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            model.updateSettings { $0.vaultPath = url.path }
        }
    }
}

// MARK: - Recording

private struct RecordingTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Watch list") {
                DebouncedText(
                    "Bundle identifiers, one per line",
                    value: model.settings.watchList.joined(separator: "\n"),
                    multiline: true
                ) { text in
                    model.updateSettings { $0.watchList = SettingsValidation.lines(text) }
                }
            }
            Section("Flag") {
                DebouncedText(
                    "Flag hotkey",
                    value: HotkeyText.format(model.settings.flagHotkey),
                    validate: SettingsValidation.hotkey
                ) { text in
                    guard let hotkey = HotkeyText.parse(text) else { return }
                    model.updateSettings { $0.flagHotkey = hotkey }
                }
                if let hotkeyError = model.hotkeyError {
                    ProblemCard(
                        problem: hotkeyError,
                        compact: true,
                        handlers: ProblemHandlers(),
                        showInActivity: { model.showInActivity(hotkeyError) }
                    )
                }
                Toggle("Show the recording pill", isOn: model.settingsBinding(\.showPill))
            }
            Section("Echo") {
                Toggle("Echo cancellation (use when on speakers)", isOn: model.settingsBinding(\.recording.voiceProcessing))
                Text("Removes the call from the microphone track when the call plays on the laptop speakers. It applies from the next recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Models") {
                LiveModelPicker()
                ModelPicker(title: "Final model", selection: model.settingsBinding(\.finalModel))
            }
        }
        .formStyle(.grouped)
    }
}

private struct LiveModelPicker: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let ids = SpeechModelID.allCases.filter(\.supportsLive).map(\.rawValue)
        Picker("Live model", selection: Binding(
            get: { SpeechModelID.liveModel(named: model.settings.liveModel).rawValue },
            set: { value in model.updateSettings { $0.liveModel = value } }
        )) {
            ForEach(ids, id: \.self) { Text($0) }
        }
    }
}

private struct ModelPicker: View {
    let title: String
    @Binding var selection: String

    var body: some View {
        let ids = SpeechModelID.allCases.map(\.rawValue)
        Picker(title, selection: $selection) {
            ForEach(ids.contains(selection) ? ids : ids + [selection], id: \.self) { Text($0) }
        }
    }
}

// MARK: - Dictionary

private struct DictionaryTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Personal dictionary") {
                DebouncedText(
                    "Names and terms, one per line",
                    value: model.settings.dictionary.joined(separator: "\n"),
                    multiline: true
                ) { text in
                    model.updateSettings { $0.dictionary = SettingsValidation.lines(text) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Permissions

private struct PermissionsTab: View {
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        Form {
            Section("Microphone") {
                LabeledContent("Status") {
                    Text(Self.statusText(microphone))
                        .foregroundStyle(microphone == .authorized ? .green : .secondary)
                }
                Button("Open Microphone settings") {
                    Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                }
            }
            Section("System audio") {
                Text("macOS does not report this permission. It is requested the first time you record a call.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Audio Recording settings") {
                    Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    private static func statusText(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: "Allowed"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not requested yet"
        @unknown default: "Unknown"
        }
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
