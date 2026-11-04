import AppKit
import MuninnCore
import MuninnSystem
import SwiftUI

@MainActor
final class SignInFlow: ObservableObject {
    enum Phase {
        case starting
        case waiting(DeviceCodePrompt)
        case finishing
        case done([String])
        case failed(Problem)
    }

    @Published private(set) var phase = Phase.starting

    private let account: AccountSettings
    private let secrets: KeychainSecrets
    private let activity: ActivityCenter
    private let onAddresses: ([String]) -> Void
    private var task: Task<Void, Never>?

    init(account: AccountSettings, secrets: KeychainSecrets, activity: ActivityCenter, onAddresses: @escaping ([String]) -> Void) {
        self.account = account
        self.secrets = secrets
        self.activity = activity
        self.onAddresses = onAddresses
    }

    func start() {
        guard task == nil else { return }
        phase = .starting
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func retry() {
        cancel()
        start()
    }

    private func run() async {
        let authenticator = DeviceCodeAuthenticator(clientID: account.clientID, tenant: account.tenant)
        let tokens: TokenSet
        do {
            let prompt = try await authenticator.start()
            phase = .waiting(prompt)
            tokens = try await authenticator.poll(prompt)
        } catch {
            fail(error)
            return
        }
        guard !Task.isCancelled else { return }
        phase = .finishing
        do {
            try TokenAccess.signIn(tokens, account: account.id, store: KeychainTokenStore(secrets: secrets))
        } catch {
            fail(error) { Problems.keychainUnwritable(details: $0.details) }
            return
        }
        let accessToken = tokens.accessToken
        do {
            let addresses = try await GraphClient(account: account.id, token: { accessToken }).me()
            onAddresses(addresses)
            phase = .done(addresses)
            activity.record(.info, .accounts, "Signed in to \(account.displayName)", details: ProblemDetails(account: account.displayName))
        } catch {
            fail(error) { Problems.signedInProfileUnreadable(account: account.displayName, details: $0.details) }
        }
    }

    /// Shows what went wrong and records it. A cancellation is not a failure. `refine` swaps the translated problem for a
    /// more specific one that keeps its details.
    private func fail(_ error: Error, refine: (Problem) -> Problem = { $0 }) {
        guard !Task.isCancelled, !ActivityCenter.isCancellation(error) else { return }
        let translated = ProblemTranslator.problem(for: error, in: ProblemContext(stage: .signingIn, accountName: account.displayName))
        let problem = refine(translated)
        activity.record(problem, area: .accounts)
        phase = .failed(problem)
    }
}

struct SignInSheet: View {
    let account: AccountSettings
    @StateObject private var flow: SignInFlow
    @Environment(\.dismiss) private var dismiss

    init(account: AccountSettings, secrets: KeychainSecrets, activity: ActivityCenter, onAddresses: @escaping ([String]) -> Void) {
        self.account = account
        _flow = StateObject(wrappedValue: SignInFlow(account: account, secrets: secrets, activity: activity, onAddresses: onAddresses))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in to \(account.displayName)")
                .font(.title2)
            content
            HStack {
                Spacer()
                switch flow.phase {
                case .done:
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                case .failed:
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                default:
                    Button("Cancel") {
                        flow.cancel()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { flow.start() }
        .onDisappear { flow.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.phase {
        case .starting:
            progress("Requesting a sign-in code")
        case .waiting(let prompt):
            VStack(alignment: .leading, spacing: 12) {
                Text("Open the link below and enter this code:")
                HStack(spacing: 12) {
                    Text(prompt.userCode)
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(prompt.userCode, forType: .string)
                    }
                }
                Button(prompt.verificationURI.absoluteString) {
                    NSWorkspace.shared.open(prompt.verificationURI)
                }
                .buttonStyle(.link)
                progress("Waiting for you to finish signing in")
            }
        case .finishing:
            progress("Reading your profile")
        case .done(let addresses):
            VStack(alignment: .leading, spacing: 6) {
                Label("Signed in", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if !addresses.isEmpty {
                    Text("Your addresses: \(addresses.joined(separator: ", "))")
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let problem):
            ProblemCard(
                problem: problem,
                handlers: ProblemHandlers(tryAgain: { flow.retry() }, signInAgain: { flow.retry() })
            )
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }
}
