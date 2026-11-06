import Foundation

enum GraphQuery {
    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func escape(_ value: String, keeping extra: String = "") -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed.union(CharacterSet(charactersIn: extra))) ?? value
    }

    static func encode(_ items: [(String, String)]) -> String {
        items.map { "\(escape($0.0, keeping: "$"))=\(escape($0.1))" }.joined(separator: "&")
    }
}

public struct GraphClient: Sendable {
    static let base = "https://graph.microsoft.com/v1.0"
    static let eventFields = "id,iCalUId,subject,start,end,isAllDay,isCancelled,attendees,organizer"

    let account: String
    let token: @Sendable () async throws -> String
    let session: URLSession

    public init(account: String, token: @escaping @Sendable () async throws -> String, session: URLSession = .shared) {
        self.account = account
        self.token = token
        self.session = session
    }

    private struct Address: Decodable {
        var name: String?
        var address: String?
    }

    private struct Person: Decodable {
        struct Status: Decodable {
            var response: String?
        }
        var emailAddress: Address?
        var type: String?
        var status: Status?
    }

    private struct Moment: Decodable {
        var dateTime: String
    }

    private struct EventDTO: Decodable {
        var id: String
        var iCalUId: String?
        var subject: String?
        var start: Moment
        var end: Moment
        var isAllDay: Bool?
        var isCancelled: Bool?
        var attendees: [Person]?
        var organizer: Person?
    }

    private struct EventPage: Decodable {
        var value: [EventDTO]
        var nextLink: String?

        private enum CodingKeys: String, CodingKey {
            case value
            case nextLink = "@odata.nextLink"
        }
    }

    private struct MeResponse: Decodable {
        var mail: String?
        var userPrincipalName: String?
    }

    private struct PeopleResponse: Decodable {
        struct Entry: Decodable {
            struct Scored: Decodable {
                var address: String?
            }
            var displayName: String?
            var scoredEmailAddresses: [Scored]?
        }
        var value: [Entry]
    }

    private func send(_ url: URL, extraHeaders: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let facts = RequestFacts(method: "GET", url: url)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            throw GraphError.connection(code: error.code.rawValue, request: facts)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GraphError.decoding
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GraphError.http(status: http.statusCode, code: ProviderErrorClassifier.graphCode(in: data), request: facts)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GraphError.decoding
        }
    }

    private func url(_ path: String, _ query: [(String, String)]) -> URL {
        URL(string: "\(Self.base)\(path)?\(GraphQuery.encode(query))")!
    }

    public func me() async throws -> [String] {
        let data = try await send(url("/me", [("$select", "mail,userPrincipalName")]))
        let response = try decode(MeResponse.self, from: data)
        var seen = Set<String>()
        return [response.mail, response.userPrincipalName].compactMap { $0 }.filter {
            !$0.isEmpty && seen.insert($0.lowercased()).inserted
        }
    }

    public func event(id: String) async throws -> CalendarEvent {
        let data = try await send(
            url("/me/events/\(GraphQuery.escape(id))", [("$select", Self.eventFields)]),
            extraHeaders: ["Prefer": #"outlook.timezone="UTC""#]
        )
        return try calendarEvent(try decode(EventDTO.self, from: data))
    }

    public func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var next: URL? = url("/me/calendarView", [
            ("startDateTime", formatter.string(from: from)),
            ("endDateTime", formatter.string(from: to)),
            ("$select", Self.eventFields),
            ("$top", "50"),
        ])
        var result: [CalendarEvent] = []
        while let page = next {
            let data = try await send(page, extraHeaders: ["Prefer": #"outlook.timezone="UTC""#])
            let decoded = try decode(EventPage.self, from: data)
            for event in decoded.value {
                result.append(try calendarEvent(event))
            }
            next = decoded.nextLink.flatMap { URL(string: $0) }
        }
        return result
    }

    private func calendarEvent(_ event: EventDTO) throws -> CalendarEvent {
        CalendarEvent(
            accountID: account,
            eventID: event.id,
            iCalUID: event.iCalUId,
            subject: event.subject ?? "",
            start: try Self.parseUTC(event.start.dateTime),
            end: try Self.parseUTC(event.end.dateTime),
            isAllDay: event.isAllDay ?? false,
            isCancelled: event.isCancelled ?? false,
            attendees: (event.attendees ?? []).compactMap { Self.attendee($0.emailAddress, type: $0.type, response: $0.status?.response) },
            organizer: Self.attendee(event.organizer?.emailAddress)
        )
    }

    private static func attendee(_ address: Address?, type: String? = nil, response: String? = nil) -> Attendee? {
        guard let email = address?.address, !email.isEmpty else { return nil }
        return Attendee(name: address?.name ?? "", email: email, type: type, response: response)
    }

    static func parseUTC(_ text: String) throws -> Date {
        var whole = text
        if whole.hasSuffix("Z") { whole.removeLast() }
        var fraction = 0.0
        if let dot = whole.firstIndex(of: ".") {
            let digits = whole[whole.index(after: dot)...]
            guard digits.count <= 7, digits.allSatisfy(\.isNumber), let value = Double("0." + digits) else {
                throw GraphError.decoding
            }
            fraction = value
            whole = String(whole[..<dot])
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let date = formatter.date(from: whole) else {
            throw GraphError.decoding
        }
        return date.addingTimeInterval(fraction)
    }

    public func searchPeople(_ query: String) async throws -> [Attendee] {
        let term = query.replacingOccurrences(of: "\"", with: " ")
        let data = try await send(url("/me/people", [("$search", "\"\(term)\""), ("$top", "10")]))
        return try decode(PeopleResponse.self, from: data).value.compactMap { person in
            guard let address = person.scoredEmailAddresses?.first?.address, !address.isEmpty else { return nil }
            return Attendee(name: person.displayName ?? "", email: address)
        }
    }
}
