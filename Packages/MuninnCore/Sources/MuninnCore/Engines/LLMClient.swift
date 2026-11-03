import Foundation

public protocol LLMClient: Sendable {
    func complete(_ request: LLMRequest) async throws -> String
}

public enum LLMError: Error, Equatable {
    case http(status: Int, category: ProviderErrorCategory, request: RequestFacts)
    case connection(code: Int, request: RequestFacts)
    case refused(String?)
    case emptyResponse
    case truncated
    case decoding
    case promptTruncated(model: String, contextTokens: Int)
}

enum LLMTransport {
    static let timeout: TimeInterval = 300

    static func post(_ url: URL, headers: [String: String], body: JSONValue, provider: Provider, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONEncoder().encode(body)
        let facts = RequestFacts(method: "POST", url: url)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            throw LLMError.connection(code: error.code.rawValue, request: facts)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.decoding
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(
                status: http.statusCode,
                category: ProviderErrorClassifier.category(status: http.statusCode, body: data, provider: provider),
                request: facts
            )
        }
        return data
    }

    static func url(base: URL, path: String) -> URL {
        EndpointURL.make(base: base, path: path)
    }

    static func outermostJSONObject(in text: String) -> String? {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { return nil }
        return String(text[open...close])
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LLMError.decoding
        }
    }

    static func chatMessages(_ request: LLMRequest) -> JSONValue {
        .array([
            .object(["role": .string("system"), "content": .string(request.system)]),
            .object(["role": .string("user"), "content": .string(request.user)]),
        ])
    }
}
