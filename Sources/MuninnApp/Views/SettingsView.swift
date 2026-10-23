import AppKit
import AVFoundation
import MuninnCore
import MuninnSpeech
import MuninnSystem
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            EnginesTab()
                .tabItem { Label("Engines", systemImage: "cpu") }
            AccountsTab()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            ObsidianTab()
                .tabItem { Label("Obsidian", systemImage: "folder") }
            RecordingTab()
                .tabItem { Label("Recording", systemImage: "record.circle") }
            DictionaryTab()
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            PermissionsTab()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 560, height: 520)
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
    @ViewState private var apiKey = ""
    @ViewState private var hasKey = false
    @ViewState private var error: String?

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
            SecureField("API key", text: $apiKey, prompt: Text(hasKey ? "Replace the saved key" : "sk-ant-..."))
                .onSubmit(save)
            HStack {
                if hasKey {
                    Label("Key saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Save", action: save)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove", role: .destructive, action: remove)
                    .disabled(!hasKey)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        do {
            hasKey = !(try model.secrets.get(LiveEnvironmentProbe.claudeKeyName) ?? "").isEmpty
            error = nil
        } catch {
            self.error = SignInFlow.keychainMessage("read", error)
        }
    }

    private func save() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try model.secrets.set(key, for: LiveEnvironmentProbe.claudeKeyName)
            apiKey = ""
            error = nil
            hasKey = true
        } catch {
            self.error = SignInFlow.keychainMessage("save the key in", error)
        }
    }

    private func remove() {
        do {
            try model.secrets.delete(LiveEnvironmentProbe.claudeKeyName)
            apiKey = ""
            error = nil
            hasKey = false
        } catch {
            self.error = SignInFlow.keychainMessage("remove the key from", error)
        }
    }
}

// MARK: - Accounts

private struct AccountsTab: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var signingIn: SigningIn?
    @ViewState private var statuses: [String: SignInStatus] = [:]
    @ViewState private var error: String?
    @ViewState private var flusher = FieldFlusher()

    private enum SignInStatus: Equatable {
        case signedIn
        case signedOut
        case unreadable(String)
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
                    HStack {
                        switch status {
                        case .signedIn where model.signInNeeded.contains(account.id):
                            Label("Sign-in expired: sign in again", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        case .signedIn:
                            Label("Signed in", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .signedOut:
                            Text("Not signed in").foregroundStyle(.secondary)
                        case .unreadable(let message):
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
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
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .sheet(item: $signingIn, onDismiss: refresh) { request in
            let account = request.account
            SignInSheet(account: account, secrets: model.secrets) { addresses in
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
        error = nil
        refresh()
    }

    private func remove(_ account: AccountSettings) {
        flusher.flushAll()
        guard AccountManagement.busyMeetings(for: account.id, in: model.meetings).isEmpty else {
            error = AccountManagement.removalRefusal(accountName: account.displayName)
            return
        }
        let answer = Alerts.ask(
            "Remove \(account.displayName)?",
            "This signs the account out and deletes its stored sign-in from the Keychain. Meetings already recorded keep their data.",
            buttons: ["Remove Account", "Cancel"],
            destructiveFirst: true
        )
        guard answer == 0 else { return }
        do {
            try TokenAccess.signOut(account: account.id, store: KeychainTokenStore(secrets: model.secrets))
        } catch {
            self.error = SignInFlow.keychainMessage("remove the tokens of \(account.displayName) from", error)
            refresh()
            return
        }
        model.updateSettings { AccountManagement.remove(account.id, from: &$0) }
        model.calendar.forget(account.id)
        model.signInNeeded.remove(account.id)
        model.refreshCalendar()
        error = nil
        refresh()
    }

    private static func askForName() -> String? {
        let alert = NSAlert()
        alert.messageText = "Add an account"
        alert.informativeText = "Name it after the organisation whose calendar and mail it signs in to, for example Work or Acme."
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

    private func signIn(_ id: String) {
        flusher.flushAll()
        guard let account = model.settings.accounts.first(where: { $0.id == id }) else { return }
        guard !account.clientID.isEmpty, !account.tenant.isEmpty else {
            error = "Enter a client ID and tenant for \(account.displayName) first."
            return
        }
        error = nil
        signingIn = SigningIn(account: account)
    }

    private func refresh() {
        let store = KeychainTokenStore(secrets: model.secrets)
        var result: [String: SignInStatus] = [:]
        for account in model.settings.accounts {
            do {
                result[account.id] = try store.load(account: account.id) == nil ? .signedOut : .signedIn
            } catch {
                result[account.id] = .unreadable(SignInFlow.keychainMessage("read", error))
            }
        }
        statuses = result
    }

    private func signOut(_ account: AccountSettings) {
        do {
            try TokenAccess.signOut(account: account.id, store: KeychainTokenStore(secrets: model.secrets))
            model.signInNeeded.remove(account.id)
            error = nil
        } catch {
            self.error = SignInFlow.keychainMessage("remove the tokens of \(account.displayName) from", error)
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
                    Text(hotkeyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
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
    @ViewState private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        Form {
            Section("Microphone") {
                LabeledContent("Status") {
                    Text(Self.describe(microphone))
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

    private static func describe(_ status: AVAuthorizationStatus) -> String {
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
