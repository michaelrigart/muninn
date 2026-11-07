import Foundation
import Testing
@testable import MuninnCore

final class GraphStubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 0
        var body = ""
        var failure: URLError?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    nonisolated(unsafe) static var hook: (@Sendable () -> Void)?

    static func reset(_ replies: [Reply]) {
        lock.lock()
        defer { lock.unlock() }
        self.replies = replies
        captured = []
        hook = nil
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GraphStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            request.httpBody = data
        }
        Self.lock.lock()
        Self.captured.append(request)
        let hook = Self.hook
        Self.lock.unlock()
        hook?()
        Self.lock.lock()
        let reply = Self.replies.isEmpty ? Reply(status: 500, body: "no stubbed reply") : Self.replies.removeFirst()
        Self.lock.unlock()
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [UInt64] = []

    var values: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ nanoseconds: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(nanoseconds)
    }
}

@Suite(.serialized)
struct GraphTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func authenticator(_ sleeps: SleepRecorder = SleepRecorder()) -> DeviceCodeAuthenticator {
        DeviceCodeAuthenticator(
            clientID: "client-1",
            tenant: "contoso",
            session: GraphStubProtocol.session(),
            sleep: { sleeps.record($0) },
            now: { now }
        )
    }

    static func client() -> GraphClient {
        GraphClient(account: "acct", token: { "tok-1" }, session: GraphStubProtocol.session())
    }

    static func form(_ request: URLRequest) throws -> [String: String] {
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        var result: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            result[String(parts[0])] = String(parts[1]).removingPercentEncoding
        }
        return result
    }

    static func query(_ request: URLRequest) throws -> [String: String] {
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    static let startBody = #"{"user_code":"ABC123","device_code":"dev-1","verification_uri":"https://microsoft.com/devicelogin","expires_in":900,"interval":5,"message":"Go sign in"}"#

    @Test func deviceCodeFlowPollsUntilToken() async throws {
        GraphStubProtocol.reset([
            .init(status: 200, body: Self.startBody),
            .init(status: 400, body: #"{"error":"authorization_pending"}"#),
            .init(status: 400, body: #"{"error":"slow_down"}"#),
            .init(status: 200, body: #"{"access_token":"at","refresh_token":"rt","expires_in":3600,"token_type":"Bearer"}"#),
        ])
        let sleeps = SleepRecorder()
        let auth = Self.authenticator(sleeps)

        let prompt = try await auth.start()
        #expect(prompt == DeviceCodePrompt(
            userCode: "ABC123",
            verificationURI: URL(string: "https://microsoft.com/devicelogin")!,
            message: "Go sign in",
            deviceCode: "dev-1",
            interval: 5,
            expiresIn: 900
        ))

        let tokens = try await auth.poll(prompt)
        #expect(tokens == TokenSet(accessToken: "at", refreshToken: "rt", expiresAt: Self.now.addingTimeInterval(3600)))
        #expect(sleeps.values == [5_000_000_000, 10_000_000_000])

        let sent = GraphStubProtocol.requests
        #expect(sent.count == 4)
        #expect(sent[0].url?.absoluteString == "https://login.microsoftonline.com/contoso/oauth2/v2.0/devicecode")
        #expect(sent[0].httpMethod == "POST")
        #expect(sent[0].value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let start = try Self.form(sent[0])
        #expect(start["client_id"] == "client-1")
        #expect(start["scope"] == "offline_access User.Read Calendars.Read People.Read")

        for request in sent.dropFirst() {
            #expect(request.url?.absoluteString == "https://login.microsoftonline.com/contoso/oauth2/v2.0/token")
            let form = try Self.form(request)
            #expect(form["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code")
            #expect(form["client_id"] == "client-1")
            #expect(form["device_code"] == "dev-1")
        }
    }

    @Test(arguments: ["expired_token", "authorization_declined", "bad_verification_code"])
    func deviceCodeErrorsThrowAuth(code: String) async throws {
        GraphStubProtocol.reset([.init(status: 400, body: #"{"error":"\#(code)","error_description":"x"}"#)])
        let prompt = DeviceCodePrompt(
            userCode: "U", verificationURI: URL(string: "https://example.com")!, message: "", deviceCode: "d", interval: 5, expiresIn: 900
        )
        let sleeps = SleepRecorder()
        await #expect(throws: GraphError.auth(code)) { try await Self.authenticator(sleeps).poll(prompt) }
        #expect(sleeps.values.isEmpty)
    }

    @Test func refreshRequestShape() async throws {
        GraphStubProtocol.reset([.init(status: 200, body: #"{"access_token":"at2","refresh_token":"rt2","expires_in":1800}"#)])
        let tokens = try await Self.authenticator().refresh("rt1")
        #expect(tokens == TokenSet(accessToken: "at2", refreshToken: "rt2", expiresAt: Self.now.addingTimeInterval(1800)))
        let form = try Self.form(try #require(GraphStubProtocol.requests.first))
        #expect(form["grant_type"] == "refresh_token")
        #expect(form["client_id"] == "client-1")
        #expect(form["refresh_token"] == "rt1")
        #expect(form["scope"] == "offline_access User.Read Calendars.Read People.Read")
    }

    @Test func refreshFailureThrowsAuth() async throws {
        GraphStubProtocol.reset([.init(status: 400, body: #"{"error":"invalid_grant"}"#)])
        await #expect(throws: GraphError.auth("invalid_grant")) { try await Self.authenticator().refresh("rt1") }
    }

    @Test func refreshWhenNearExpiry() async throws {
        GraphStubProtocol.reset([.init(status: 200, body: #"{"access_token":"fresh","refresh_token":"rt2","expires_in":3600}"#)])
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "stale", refreshToken: "rt1", expiresAt: Self.now.addingTimeInterval(240)), account: "acct")
        let session = GraphSession(account: "acct", authenticator: Self.authenticator(), store: store, now: { Self.now })

        #expect(try await session.accessToken() == "fresh")
        #expect(try store.load(account: "acct") == TokenSet(accessToken: "fresh", refreshToken: "rt2", expiresAt: Self.now.addingTimeInterval(3600)))
        #expect(GraphStubProtocol.requests.count == 1)
        #expect(try Self.form(try #require(GraphStubProtocol.requests.first))["refresh_token"] == "rt1")
    }

    @Test func signOutDuringRefreshStaysSignedOut() async throws {
        GraphStubProtocol.reset([.init(status: 200, body: #"{"access_token":"fresh","refresh_token":"rt2","expires_in":3600}"#)])
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "stale", refreshToken: "rt1", expiresAt: Self.now.addingTimeInterval(240)), account: "acct")
        GraphStubProtocol.hook = { try? store.delete(account: "acct") }
        let session = GraphSession(account: "acct", authenticator: Self.authenticator(), store: store, now: { Self.now })
        await #expect(throws: GraphError.notSignedIn) { try await session.accessToken() }
        #expect(try store.load(account: "acct") == nil)
    }

    private final class SignOutRacingStore: TokenStore, @unchecked Sendable {
        let inner = InMemoryTokenStore()
        private let lock = NSLock()
        private var loads = 0
        private var signOutFinished = false

        func load(account: String) throws -> TokenSet? {
            let tokens = try inner.load(account: account)
            lock.lock()
            loads += 1
            let isRefreshCheck = loads == 2
            lock.unlock()
            if isRefreshCheck {
                Thread.detachNewThread { [self] in
                    try? TokenAccess.signOut(account: account, store: inner)
                    lock.withLock { signOutFinished = true }
                }
                Thread.sleep(forTimeInterval: 0.15)
            }
            return tokens
        }

        func save(_ t: TokenSet, account: String) throws { try inner.save(t, account: account) }
        func delete(account: String) throws { try inner.delete(account: account) }

        /// Polls until the racing sign-out has finished, giving up after `limit` seconds; returns whether it finished.
        func signOutDone(within limit: TimeInterval) async -> Bool {
            let deadline = Date().addingTimeInterval(limit)
            while Date() < deadline {
                if lock.withLock({ signOutFinished }) { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return lock.withLock { signOutFinished }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func signOutBetweenTheRefreshCheckAndSaveStaysSignedOut() async throws {
        GraphStubProtocol.reset([.init(status: 200, body: #"{"access_token":"fresh","refresh_token":"rt2","expires_in":3600}"#)])
        let store = SignOutRacingStore()
        try store.inner.save(TokenSet(accessToken: "stale", refreshToken: "rt1", expiresAt: Self.now.addingTimeInterval(240)), account: "acct")
        let session = GraphSession(account: "acct", authenticator: Self.authenticator(), store: store, now: { Self.now })
        _ = try await session.accessToken()
        #expect(await store.signOutDone(within: 10))
        #expect(try store.inner.load(account: "acct") == nil)
    }

    @Test func onlyRejectedSignInsCountAsExpired() {
        #expect(GraphError.auth("invalid_grant").isExpiredSignIn)
        #expect(GraphError.notSignedIn.isExpiredSignIn)
        #expect(GraphError.http(status: 401, code: "InvalidAuthenticationToken", request: Self.graphRequest).isExpiredSignIn)
        #expect(!GraphError.http(status: 403, code: nil, request: Self.graphRequest).isExpiredSignIn)
        #expect(!GraphError.http(status: 429, code: nil, request: Self.graphRequest).isExpiredSignIn)
        #expect(!GraphError.http(status: 500, code: nil, request: Self.graphRequest).isExpiredSignIn)
        #expect(!GraphError.connection(code: -1009, request: Self.graphRequest).isExpiredSignIn)
        #expect(!GraphError.decoding.isExpiredSignIn)
    }

    @Test func calendarViewMapsAnHTTP401ToAnExpiredSignIn() async throws {
        GraphStubProtocol.reset([.init(status: 401, body: #"{"error":{"code":"InvalidAuthenticationToken"}}"#)])
        let client = GraphClient(account: "acct", token: { "t" }, session: GraphStubProtocol.session())
        do {
            _ = try await client.events(from: Self.now, to: Self.now.addingTimeInterval(3600))
            Issue.record("Expected an error")
        } catch let error as GraphError {
            #expect(error.isExpiredSignIn)
        }
    }

    @Test func signInAndSignOutGoThroughTheStore() throws {
        let store = InMemoryTokenStore()
        let tokens = TokenSet(accessToken: "a", refreshToken: "r", expiresAt: Self.now)
        try TokenAccess.signIn(tokens, account: "acct", store: store)
        #expect(try store.load(account: "acct") == tokens)
        try TokenAccess.signOut(account: "acct", store: store)
        #expect(try store.load(account: "acct") == nil)
    }

    @Test func newerSignInDuringRefreshIsKept() async throws {
        GraphStubProtocol.reset([.init(status: 200, body: #"{"access_token":"fresh","refresh_token":"rt2","expires_in":3600}"#)])
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "stale", refreshToken: "rt1", expiresAt: Self.now.addingTimeInterval(240)), account: "acct")
        let newer = TokenSet(accessToken: "newer", refreshToken: "rtN", expiresAt: Self.now.addingTimeInterval(3600))
        GraphStubProtocol.hook = { try? store.save(newer, account: "acct") }
        let session = GraphSession(account: "acct", authenticator: Self.authenticator(), store: store, now: { Self.now })
        #expect(try await session.accessToken() == "newer")
        #expect(try store.load(account: "acct") == newer)
        #expect(GraphStubProtocol.requests.count == 1)
    }

    @Test func concurrentAccessTokenCallsRefreshOnce() async throws {
        GraphStubProtocol.reset([.init(status: 200, body: #"{"access_token":"fresh","refresh_token":"rt2","expires_in":3600}"#)])
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "stale", refreshToken: "rt1", expiresAt: Self.now.addingTimeInterval(240)), account: "acct")
        GraphStubProtocol.hook = { Thread.sleep(forTimeInterval: 0.2) }
        let session = GraphSession(account: "acct", authenticator: Self.authenticator(), store: store, now: { Self.now })
        async let first = session.accessToken()
        async let second = session.accessToken()
        async let third = session.accessToken()
        let tokens = try await [first, second, third]
        #expect(tokens == ["fresh", "fresh", "fresh"])
        #expect(GraphStubProtocol.requests.count == 1)
        #expect(try store.load(account: "acct")?.refreshToken == "rt2")
    }

    @Test func noRefreshWhenFarFromExpiry() async throws {
        GraphStubProtocol.reset([])
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "good", refreshToken: "rt1", expiresAt: Self.now.addingTimeInterval(600)), account: "acct")
        let session = GraphSession(account: "acct", authenticator: Self.authenticator(), store: store, now: { Self.now })
        #expect(try await session.accessToken() == "good")
        #expect(GraphStubProtocol.requests.isEmpty)
    }

    @Test func nearExpiryWithoutRefreshTokenReturnsCurrent() async throws {
        GraphStubProtocol.reset([])
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "only", refreshToken: nil, expiresAt: Self.now.addingTimeInterval(60)), account: "acct")
        let session = GraphSession(account: "acct", authenticator: Self.authenticator(), store: store, now: { Self.now })
        #expect(try await session.accessToken() == "only")
        #expect(GraphStubProtocol.requests.isEmpty)
    }

    @Test func expiredWithoutRefreshTokenThrowsNotSignedIn() async throws {
        GraphStubProtocol.reset([])
        let store = InMemoryTokenStore()
        try store.save(TokenSet(accessToken: "dead", refreshToken: nil, expiresAt: Self.now.addingTimeInterval(-1)), account: "acct")
        let session = GraphSession(account: "acct", authenticator: Self.authenticator(), store: store, now: { Self.now })
        await #expect(throws: GraphError.notSignedIn) { try await session.accessToken() }
        try store.save(TokenSet(accessToken: "dead", refreshToken: nil, expiresAt: Self.now), account: "acct")
        await #expect(throws: GraphError.notSignedIn) { try await session.accessToken() }
        #expect(GraphStubProtocol.requests.isEmpty)
    }

    @Test func missingTokensThrowNotSignedIn() async throws {
        let session = GraphSession(account: "acct", authenticator: Self.authenticator(), store: InMemoryTokenStore(), now: { Self.now })
        await #expect(throws: GraphError.notSignedIn) { try await session.accessToken() }
    }

    @Test func calendarViewReadsAttendeeTypeAndResponse() async throws {
        let page = #"""
        {"value":[
          {"id":"E1","subject":"Standup","start":{"dateTime":"2026-10-23T09:00:00.0000000"},
           "end":{"dateTime":"2026-10-23T09:30:00.0000000"},
           "attendees":[
             {"type":"required","status":{"response":"accepted","time":"0001-01-01T00:00:00Z"},"emailAddress":{"name":"Bob","address":"bob@example.com"}},
             {"type":"resource","status":{"response":"none"},"emailAddress":{"name":"Room 4","address":"room4@example.com"}},
             {"type":"optional","status":{"response":"declined"},"emailAddress":{"name":"Cy","address":"cy@example.com"}}]}]}
        """#
        GraphStubProtocol.reset([.init(status: 200, body: page)])
        let from = Date(timeIntervalSince1970: 1_792_742_400)
        let events = try await Self.client().events(from: from, to: from.addingTimeInterval(86_400))
        let attendees = try #require(events.first).attendees
        #expect(attendees == [
            Attendee(name: "Bob", email: "bob@example.com", type: "required", response: "accepted"),
            Attendee(name: "Room 4", email: "room4@example.com", type: "resource", response: "none"),
            Attendee(name: "Cy", email: "cy@example.com", type: "optional", response: "declined"),
        ])
        #expect(attendees.map(\.isResource) == [false, true, false])
        #expect(attendees.map(\.hasDeclined) == [false, false, true])
    }

    @Test func calendarViewParsesUTC() async throws {
        let page1 = #"""
        {"@odata.nextLink":"https://graph.microsoft.com/v1.0/me/calendarView?$skiptoken=abc","value":[
          {"id":"E1","iCalUId":"UID-1","subject":"Standup","isAllDay":false,"isCancelled":false,
           "start":{"dateTime":"2026-10-23T09:00:00.0000000","timeZone":"UTC"},
           "end":{"dateTime":"2026-10-23T09:30:00.0000000","timeZone":"UTC"},
           "organizer":{"emailAddress":{"name":"Olga","address":"olga@example.com"}},
           "attendees":[
             {"emailAddress":{"name":"Bob","address":"bob@example.com"}},
             {"emailAddress":{"name":"Room","address":""}}]}]}
        """#
        let page2 = #"""
        {"value":[
          {"id":"E2","subject":"Offsite","isAllDay":true,"isCancelled":true,
           "start":{"dateTime":"2026-10-24T00:00:00.0000000"},
           "end":{"dateTime":"2026-10-25T00:00:00.5000000"},
           "attendees":[]}]}
        """#
        GraphStubProtocol.reset([.init(status: 200, body: page1), .init(status: 200, body: page2)])
        let from = Date(timeIntervalSince1970: 1_792_742_400)
        let events = try await Self.client().events(from: from, to: from.addingTimeInterval(86_400))

        let utc = ISO8601DateFormatter()
        let nine = try #require(utc.date(from: "2026-10-23T09:00:00Z"))
        #expect(events == [
            CalendarEvent(
                accountID: "acct", eventID: "E1", iCalUID: "UID-1", subject: "Standup",
                start: nine, end: nine.addingTimeInterval(1800), isAllDay: false, isCancelled: false,
                attendees: [Attendee(name: "Bob", email: "bob@example.com")],
                organizer: Attendee(name: "Olga", email: "olga@example.com")
            ),
            CalendarEvent(
                accountID: "acct", eventID: "E2", iCalUID: nil, subject: "Offsite",
                start: try #require(utc.date(from: "2026-10-24T00:00:00Z")),
                end: try #require(utc.date(from: "2026-10-25T00:00:00Z")).addingTimeInterval(0.5),
                isAllDay: true, isCancelled: true, attendees: [], organizer: nil
            ),
        ])

        let sent = GraphStubProtocol.requests
        #expect(sent.count == 2)
        let first = try #require(sent.first)
        #expect(first.url?.path == "/v1.0/me/calendarView")
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer tok-1")
        #expect(first.value(forHTTPHeaderField: "Prefer") == #"outlook.timezone="UTC""#)
        let query = try Self.query(first)
        #expect(query["startDateTime"] == utc.string(from: from))
        #expect(query["startDateTime"]?.hasSuffix("Z") == true)
        #expect(query["endDateTime"] == utc.string(from: from.addingTimeInterval(86_400)))
        #expect(query["$select"] == "id,iCalUId,subject,start,end,isAllDay,isCancelled,attendees,organizer")
        #expect(query["$top"] == "50")
        #expect(sent[1].url?.absoluteString == "https://graph.microsoft.com/v1.0/me/calendarView?$skiptoken=abc")
        #expect(sent[1].value(forHTTPHeaderField: "Authorization") == "Bearer tok-1")
    }

    @Test func singleEventFetch() async throws {
        let body = #"""
        {"id":"AAMk=-1","iCalUId":"UID-9","subject":"Review","isAllDay":false,"isCancelled":false,
         "start":{"dateTime":"2026-10-23T09:00:00.0000000","timeZone":"UTC"},
         "end":{"dateTime":"2026-10-23T10:00:00.0000000","timeZone":"UTC"},
         "organizer":{"emailAddress":{"name":"Olga","address":"olga@example.com"}},
         "attendees":[{"emailAddress":{"name":"Bob","address":"bob@example.com"}}]}
        """#
        GraphStubProtocol.reset([.init(status: 200, body: body)])
        let event = try await Self.client().event(id: "AAMk=-1")

        let nine = try #require(ISO8601DateFormatter().date(from: "2026-10-23T09:00:00Z"))
        #expect(event == CalendarEvent(
            accountID: "acct", eventID: "AAMk=-1", iCalUID: "UID-9", subject: "Review",
            start: nine, end: nine.addingTimeInterval(3600), isAllDay: false, isCancelled: false,
            attendees: [Attendee(name: "Bob", email: "bob@example.com")],
            organizer: Attendee(name: "Olga", email: "olga@example.com")
        ))
        let sent = try #require(GraphStubProtocol.requests.first)
        #expect(sent.httpMethod == "GET")
        #expect(sent.url?.path == "/v1.0/me/events/AAMk=-1")
        #expect(sent.url?.absoluteString.hasPrefix("https://graph.microsoft.com/v1.0/me/events/AAMk%3D-1?") == true)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer tok-1")
        #expect(sent.value(forHTTPHeaderField: "Prefer") == #"outlook.timezone="UTC""#)
        #expect(try Self.query(sent)["$select"] == "id,iCalUId,subject,start,end,isAllDay,isCancelled,attendees,organizer")
    }

    @Test func meDeduplicatesCaseInsensitively() async throws {
        GraphStubProtocol.reset([.init(status: 200, body: #"{"mail":"Sam@Example.com","userPrincipalName":"sam@example.com"}"#)])
        #expect(try await Self.client().me() == ["Sam@Example.com"])
        let sent = try #require(GraphStubProtocol.requests.first)
        #expect(sent.url?.path == "/v1.0/me")
        #expect(try Self.query(sent)["$select"] == "mail,userPrincipalName")
    }

    @Test func meDropsNilAndEmpty() async throws {
        GraphStubProtocol.reset([.init(status: 200, body: #"{"mail":null,"userPrincipalName":"m@corp.example"}"#)])
        #expect(try await Self.client().me() == ["m@corp.example"])
        GraphStubProtocol.reset([.init(status: 200, body: #"{"mail":"","userPrincipalName":"m@corp.example"}"#)])
        #expect(try await Self.client().me() == ["m@corp.example"])
    }

    @Test func scopesLeaveOutMailReadWrite() {
        #expect(!DeviceCodeAuthenticator.scopes.contains("Mail.ReadWrite"))
    }

    @Test func peopleSearchParses() async throws {
        let body = #"""
        {"value":[
          {"displayName":"Bob Builder","scoredEmailAddresses":[{"address":"bob@example.com","relevanceScore":9},{"address":"bob2@example.com"}]},
          {"displayName":"No Mail","scoredEmailAddresses":[]},
          {"displayName":"Olga","scoredEmailAddresses":[{"address":"olga@example.com"}]}]}
        """#
        GraphStubProtocol.reset([.init(status: 200, body: body)])
        let people = try await Self.client().searchPeople("bob b+x")
        #expect(people == [Attendee(name: "Bob Builder", email: "bob@example.com"), Attendee(name: "Olga", email: "olga@example.com")])

        let sent = try #require(GraphStubProtocol.requests.first)
        #expect(sent.url?.path == "/v1.0/me/people")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer tok-1")
        let query = try Self.query(sent)
        #expect(query["$search"] == "\"bob b+x\"")
        #expect(query["$top"] == "10")
        #expect(sent.url?.absoluteString.contains("%22bob%20b%2Bx%22") == true)
    }

    @Test func graphErrorsHaveReadableDescriptions() {
        #expect(GraphError.notSignedIn.localizedDescription == "Not signed in to this account. Sign in again in Settings.")
        #expect(GraphError.auth("invalid_grant").localizedDescription == "Microsoft returned invalid_grant.")
        #expect(GraphError.http(status: 403, code: "ErrorAccessDenied", request: Self.graphRequest).localizedDescription == "Microsoft Graph returned HTTP 403.")
        #expect(GraphError.decoding.localizedDescription == "Unexpected response from Microsoft.")
        #expect(GraphError.connection(code: -1009, request: Self.graphRequest).localizedDescription == "Microsoft can't be reached.")
    }

    static let graphRequest = RequestFacts(method: "GET", path: "/v1.0/me/people", host: "graph.microsoft.com")

    @Test func graphHTTPError() async throws {
        GraphStubProtocol.reset([.init(status: 403, body: "denied")])
        await #expect(throws: GraphError.http(status: 403, code: nil, request: Self.graphRequest)) { try await Self.client().searchPeople("x") }
    }

    @Test(arguments: [
        (#"{"error":{"code":"ErrorAccessDenied","message":"\#(SEED)"}}"#, "ErrorAccessDenied" as String?),
        (#"{"error":{"code":"ConfidentialAcquisition","message":"\#(SEED)"}}"#, "other"),
        (#"{"error":{"code":"Access denied \#(SEED)"}}"#, "other"),
        (#"{"error":{"message":"\#(SEED)"}}"#, nil),
        ("<html>\(SEED)</html>", nil),
    ])
    func graphHTTPErrorKeepsOnlyAKnownCode(body: String, code: String?) async {
        GraphStubProtocol.reset([.init(status: 403, body: body)])
        let error = await #expect(throws: GraphError.self) {
            try await Self.client().searchPeople("x")
        }
        #expect(error == .http(status: 403, code: code, request: Self.graphRequest))
        #expect(!String(reflecting: error!).contains("Henderson"))
    }

    @Test(arguments: ["weird_code", SEED])
    func authFailureKeepsOnlyAKnownOAuthCode(code: String) async {
        GraphStubProtocol.reset([.init(status: 400, body: #"{"error":"\#(code)"}"#)])
        await #expect(throws: GraphError.auth("unrecognised")) { try await Self.authenticator().refresh("rt1") }
    }

    @Test func authFailureWithoutAnOAuthErrorKeepsOnlyTheStatus() async {
        GraphStubProtocol.reset([.init(status: 502, body: "<html>\(SEED)</html>")])
        let error = await #expect(throws: GraphError.self) { try await Self.authenticator().refresh("rt1") }
        #expect(error == .http(
            status: 502, code: nil, request: RequestFacts(method: "POST", path: "/{tenant}/oauth2/v2.0/token", host: "login.microsoftonline.com")
        ))
    }

    @Test func requestFactsHideLongIdentifiers() async {
        GraphStubProtocol.reset([.init(status: 404, body: #"{"error":{"code":"ErrorItemNotFound"}}"#)])
        let error = await #expect(throws: GraphError.self) {
            try await Self.client().event(id: String(repeating: "A", count: 60))
        }
        guard case .http(_, _, let request) = error else {
            Issue.record("expected an HTTP error, got \(String(describing: error))")
            return
        }
        #expect(request.path == "/v1.0/me/events/{id}")
    }

    @Test func graphConnectionFailureCarriesCodeAndRequest() async {
        GraphStubProtocol.reset([.init(failure: URLError(.notConnectedToInternet))])
        let error = await #expect(throws: GraphError.self) { try await Self.client().searchPeople("x") }
        #expect(error == .connection(code: -1009, request: Self.graphRequest))
    }

    @Test func oauthConnectionFailureCarriesCodeAndRequest() async {
        GraphStubProtocol.reset([.init(failure: URLError(.timedOut))])
        let error = await #expect(throws: GraphError.self) { try await Self.authenticator().refresh("rt1") }
        #expect(error == .connection(
            code: -1001, request: RequestFacts(method: "POST", path: "/{tenant}/oauth2/v2.0/token", host: "login.microsoftonline.com")
        ))
    }

    @Test func graphCancellationStaysACancellation() async {
        GraphStubProtocol.reset([.init(failure: URLError(.cancelled))])
        let error = await #expect(throws: URLError.self) { try await Self.client().searchPeople("x") }
        #expect(error?.code == .cancelled)
    }

    @Test func unparseableDatesKeepNoText() {
        let error = #expect(throws: GraphError.self) { try GraphClient.parseUTC("March \(SEED)") }
        #expect(error == .decoding)
    }

    @Test func knownCodesAreRecognisedAndOthersCollapse() {
        #expect(ProviderErrorClassifier.graphCode(in: Data(#"{"error":{"code":"ErrorQuotaExceeded"}}"#.utf8)) == "ErrorQuotaExceeded")
        #expect(ProviderErrorClassifier.graphCode(in: Data(#"{"error":{"code":"nope"}}"#.utf8)) == "other")
        #expect(ProviderErrorClassifier.graphCode(in: Data("[]".utf8)) == nil)
        #expect(ProviderErrorClassifier.oauthCode("slow_down") == "slow_down")
        #expect(ProviderErrorClassifier.oauthCode("nope") == "unrecognised")
        #expect(ProviderErrorClassifier.oauthCode(nil) == "unrecognised")
    }

    @Test func graphDecodingError() async throws {
        GraphStubProtocol.reset([.init(status: 200, body: "not json \(SEED)")])
        let error = await #expect(throws: GraphError.self) { try await Self.client().me() }
        #expect(error == .decoding)
        #expect(!String(reflecting: error!).contains("Henderson"))
    }
}
