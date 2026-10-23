import AppKit
import Foundation
import MuninnCore
import MuninnSystem
import UserNotifications
import os

private let logger = Logger(subsystem: "be.netronix.muninn", category: "services")

@MainActor
final class GraphServices {
    private let tokens: KeychainTokenStore
    private let urlSession: URLSession
    private var sessions: [String: GraphSession] = [:]

    init(secrets: KeychainSecrets) {
        tokens = KeychainTokenStore(secrets: secrets)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        urlSession = URLSession(configuration: configuration)
    }

    func client(for account: AccountSettings) throws -> GraphClient {
        guard !account.clientID.isEmpty, try tokens.load(account: account.id) != nil else { throw GraphError.notSignedIn }
        let key = "\(account.id)|\(account.tenant)|\(account.clientID)"
        let session: GraphSession
        if let existing = sessions[key] {
            session = existing
        } else {
            let authenticator = DeviceCodeAuthenticator(clientID: account.clientID, tenant: account.tenant, session: urlSession)
            session = GraphSession(account: account.id, authenticator: authenticator, store: tokens)
            sessions[key] = session
        }
        return GraphClient(account: account.id, token: { try await session.accessToken() }, session: urlSession)
    }

    /// The account's client, or nil when it has no client ID or stored tokens; Keychain failures are logged.
    func signedInClient(for account: AccountSettings) -> GraphClient? {
        do {
            return try client(for: account)
        } catch GraphError.notSignedIn {
            return nil
        } catch {
            logger.error("Reading the sign-in for \(account.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// Calendar events per signed-in account, kept warm by a background refresh so starting a recording never waits on the network.
@MainActor
final class CalendarCache {
    static let maxAge: TimeInterval = 300
    static let deadline: Duration = .seconds(2)

    private struct Entry {
        var events: [CalendarEvent]
        var fetchedAt: Date
        var from: Date
        var to: Date
    }

    private let graph: GraphServices
    private var entries: [String: Entry] = [:]
    private var inFlight: Task<Void, Never>?
    private var inFlightIDs: Set<String> = []
    private var generation = 0
    private var forgetCounts: [String: Int] = [:]
    /// Called per account after each refresh: true when Microsoft rejected the stored sign-in, false when the account fetched fine or is signed out.
    var onSignInState: ((String, Bool) -> Void)?

    init(graph: GraphServices) {
        self.graph = graph
    }

    /// Fetches now-1h...now+2h for every signed-in account. A fetch already running for the same accounts is joined;
    /// one started for a different set is followed by a fresh fetch.
    @discardableResult
    func refresh(_ accounts: [AccountSettings]) -> Task<Void, Never> {
        let clients = accounts.compactMap { account in graph.signedInClient(for: account).map { (account.id, $0) } }
        let ids = Set(clients.map(\.0))
        for account in accounts where !ids.contains(account.id) {
            onSignInState?(account.id, false)
        }
        if let inFlight, inFlightIDs == ids { return inFlight }
        let previous = inFlight
        generation += 1
        let mine = generation
        let forgetCountsAtStart = forgetCounts
        let task = Task { [weak self] in
            await previous?.value
            let now = Date()
            let from = now.addingTimeInterval(-3600)
            let to = now.addingTimeInterval(7200)
            let fetched = await withTaskGroup(of: (String, Result<[CalendarEvent], Error>).self) { group in
                for (id, client) in clients {
                    group.addTask {
                        do {
                            return (id, .success(try await client.events(from: from, to: to)))
                        } catch {
                            logger.warning("Fetching events for \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                            return (id, .failure(error))
                        }
                    }
                }
                var result: [String: Result<[CalendarEvent], Error>] = [:]
                for await (id, outcome) in group {
                    result[id] = outcome
                }
                return result
            }
            guard let self else { return }
            for (id, outcome) in fetched {
                guard (forgetCounts[id] ?? 0) == (forgetCountsAtStart[id] ?? 0) else { continue }
                switch outcome {
                case .success(let events):
                    entries[id] = Entry(events: events, fetchedAt: now, from: from, to: to)
                    onSignInState?(id, false)
                case .failure(let error):
                    if Self.signInRejected(error) { onSignInState?(id, true) }
                }
            }
            if generation == mine {
                inFlight = nil
                inFlightIDs = []
            }
        }
        inFlight = task
        inFlightIDs = ids
        return task
    }

    /// Drops a removed account's events; a refresh already running for it neither stores its result nor flags the account.
    func forget(_ accountID: String) {
        entries[accountID] = nil
        forgetCounts[accountID, default: 0] += 1
    }

    private static func signInRejected(_ error: Error) -> Bool {
        (error as? GraphError)?.isExpiredSignIn ?? false
    }

    /// Matches `at` against the cache; accounts with no fresh entry get one fetch, abandoned after two seconds.
    func match(at: Date, accounts: [AccountSettings]) async -> EventMatch {
        let signedIn = accounts.filter { graph.signedInClient(for: $0) != nil }
        if signedIn.contains(where: { !isFresh(entries[$0.id], at: at) }) {
            await wait(for: refresh(signedIn), upTo: Self.deadline)
        }
        let events = signedIn.flatMap { account -> [CalendarEvent] in
            guard let entry = entries[account.id], isFresh(entry, at: at) else { return [] }
            return entry.events
        }
        return EventMatcher.match(events, at: at)
    }

    private func isFresh(_ entry: Entry?, at: Date) -> Bool {
        guard let entry else { return false }
        return Date().timeIntervalSince(entry.fetchedAt) <= Self.maxAge && entry.from <= at && at <= entry.to
    }

    private func wait(for task: Task<Void, Never>, upTo deadline: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = Gate(continuation)
            Task { await task.value; gate.open() }
            Task { try? await Task.sleep(for: deadline); gate.open() }
        }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func open() {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }
}

@MainActor
enum Alerts {
    /// Shows a modal question and returns the index of the pressed button (0 is the first title).
    static func ask(_ message: String, _ detail: String, buttons: [String], destructiveFirst: Bool = false) -> Int {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        for title in buttons {
            alert.addButton(withTitle: title)
        }
        if destructiveFirst { alert.buttons[0].hasDestructiveAction = true }
        NSApp.activate()
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
}

private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["meeting"] as? String else { return }
        await MainActor.run { RecapNotifications.onOpen?(MeetingID(rawValue: id)) }
    }
}

@MainActor
enum RecapNotifications {
    private static let delegate = NotificationDelegate()
    static var onOpen: ((MeetingID) -> Void)?

    /// `UNUserNotificationCenter` aborts outside an app bundle, e.g. under `swift run`.
    private static var available: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static func start(onOpen: @escaping (MeetingID) -> Void) {
        self.onOpen = onOpen
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                logger.error("Notification authorization failed: \(String(describing: error), privacy: .public)")
            } else if !granted {
                logger.notice("Notifications are not allowed")
            }
        }
    }

    static func recapReady(_ meeting: Meeting) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "Recap ready: \(meeting.title)"
        content.sound = .default
        content.userInfo = ["meeting": meeting.id.rawValue]
        let request = UNNotificationRequest(identifier: "recap-\(meeting.id.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Posting the recap notification failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
