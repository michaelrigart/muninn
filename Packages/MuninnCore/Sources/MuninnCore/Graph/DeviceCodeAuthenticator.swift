import Foundation

public enum GraphError: Error, Equatable {
    case notSignedIn
    case auth(String)
    case http(Int, String)
    case decoding(String)
}

extension GraphError {
    /// Whether Microsoft rejected the stored sign-in, so the account needs signing in again: an auth error, no tokens, or HTTP 401.
    public var isExpiredSignIn: Bool {
        switch self {
        case .auth, .notSignedIn: true
        case .http(let status, _): status == 401
        case .decoding: false
        }
    }
}

extension GraphError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "Not signed in to this account. Sign in again in Settings."
        case .auth(let code): "Microsoft returned \(code)."
        case .http(let status, let body): body.isEmpty ? "Microsoft Graph returned HTTP \(status)." : "Microsoft Graph returned HTTP \(status): \(body)"
        case .decoding(let detail): "Unexpected response from Microsoft: \(detail)"
        }
    }
}

public struct DeviceCodePrompt: Equatable, Sendable {
    public var userCode: String
    public var verificationURI: URL
    public var message: String
    public var deviceCode: String
    public var interval: Int
    public var expiresIn: Int

    public init(userCode: String, verificationURI: URL, message: String, deviceCode: String, interval: Int, expiresIn: Int) {
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.message = message
        self.deviceCode = deviceCode
        self.interval = interval
        self.expiresIn = expiresIn
    }
}

public struct DeviceCodeAuthenticator: Sendable {
    public static let scopes = ["offline_access", "User.Read", "Calendars.Read", "Mail.ReadWrite", "People.Read"]

    let clientID: String
    let tenant: String
    let session: URLSession
    let sleep: @Sendable (UInt64) async -> Void
    let now: @Sendable () -> Date

    public init(
        clientID: String,
        tenant: String,
        session: URLSession = .shared,
        sleep: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.clientID = clientID
        self.tenant = tenant
        self.session = session
        self.sleep = sleep
        self.now = now
    }

    private struct StartResponse: Decodable {
        var userCode: String
        var deviceCode: String
        var verificationUri: URL
        var message: String?
        var interval: Int?
        var expiresIn: Int
    }

    private struct TokenResponse: Decodable {
        var accessToken: String
        var refreshToken: String?
        var expiresIn: Int
    }

    private struct ErrorResponse: Decodable {
        var error: String
    }

    private func endpoint(_ name: String) -> URL {
        URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/\(name)")!
    }

    private func post(_ name: String, form: [(String, String)]) async throws -> (Data, Int) {
        var request = URLRequest(url: endpoint(name))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(GraphQuery.encode(form).utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GraphError.decoding("The response is not an HTTP response")
        }
        return (data, http.statusCode)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw GraphError.decoding(String(describing: error))
        }
    }

    private func failure(_ data: Data, status: Int) -> GraphError {
        if let error = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            return .auth(error.error)
        }
        return .http(status, String(String(decoding: data, as: UTF8.self).prefix(500)))
    }

    public func start() async throws -> DeviceCodePrompt {
        let (data, status) = try await post("devicecode", form: [
            ("client_id", clientID),
            ("scope", Self.scopes.joined(separator: " ")),
        ])
        guard (200..<300).contains(status) else { throw failure(data, status: status) }
        let response = try decode(StartResponse.self, from: data)
        return DeviceCodePrompt(
            userCode: response.userCode,
            verificationURI: response.verificationUri,
            message: response.message ?? "",
            deviceCode: response.deviceCode,
            interval: response.interval ?? 5,
            expiresIn: response.expiresIn
        )
    }

    public func poll(_ p: DeviceCodePrompt) async throws -> TokenSet {
        var interval = p.interval
        while true {
            let (data, status) = try await post("token", form: [
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                ("client_id", clientID),
                ("device_code", p.deviceCode),
            ])
            if (200..<300).contains(status) {
                return try tokens(from: data, keeping: nil)
            }
            let error = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            switch error?.error {
            case "authorization_pending":
                break
            case "slow_down":
                interval += 5
            default:
                throw failure(data, status: status)
            }
            await sleep(UInt64(interval) * 1_000_000_000)
        }
    }

    public func refresh(_ refreshToken: String) async throws -> TokenSet {
        let (data, status) = try await post("token", form: [
            ("grant_type", "refresh_token"),
            ("client_id", clientID),
            ("refresh_token", refreshToken),
            ("scope", Self.scopes.joined(separator: " ")),
        ])
        guard (200..<300).contains(status) else { throw failure(data, status: status) }
        return try tokens(from: data, keeping: refreshToken)
    }

    private func tokens(from data: Data, keeping refreshToken: String?) throws -> TokenSet {
        let response = try decode(TokenResponse.self, from: data)
        return TokenSet(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? refreshToken,
            expiresAt: now().addingTimeInterval(TimeInterval(response.expiresIn))
        )
    }
}

public actor GraphSession {
    private let account: String
    private let authenticator: DeviceCodeAuthenticator
    private let store: TokenStore
    private let now: @Sendable () -> Date
    private var inFlight: (refreshToken: String, task: Task<String, Error>)?

    public init(
        account: String,
        authenticator: DeviceCodeAuthenticator,
        store: TokenStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.account = account
        self.authenticator = authenticator
        self.store = store
        self.now = now
    }

    public func accessToken() async throws -> String {
        guard let tokens = try store.load(account: account) else { throw GraphError.notSignedIn }
        let remaining = tokens.expiresAt.timeIntervalSince(now())
        guard remaining < 300 else { return tokens.accessToken }
        guard let refreshToken = tokens.refreshToken else {
            if remaining <= 0 { throw GraphError.notSignedIn }
            return tokens.accessToken
        }
        if let flight = inFlight, flight.refreshToken == refreshToken {
            return try await flight.task.value
        }
        let task = Task { try await self.refresh(using: refreshToken) }
        let flight = (refreshToken: refreshToken, task: task)
        inFlight = flight
        defer {
            if inFlight?.task == task { inFlight = nil }
        }
        return try await task.value
    }

    /// Refreshes with `refreshToken`, then saves the result only if the stored sign-in is still the one that was used.
    private func refresh(using refreshToken: String) async throws -> String {
        let refreshed = try await authenticator.refresh(refreshToken)
        let account = account
        let store = store
        let saved: String? = try TokenAccess.withLock(account: account) {
            guard let stored = try store.load(account: account) else { throw GraphError.notSignedIn }
            guard stored.refreshToken == refreshToken else { return nil }
            try store.save(refreshed, account: account)
            return refreshed.accessToken
        }
        if let saved { return saved }
        return try await accessToken()
    }
}
