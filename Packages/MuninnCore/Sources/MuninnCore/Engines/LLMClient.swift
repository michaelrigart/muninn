import Foundation

public protocol LLMClient: Sendable {
    func complete(_ request: LLMRequest) async throws -> String
}

public enum LLMError: Error, Equatable {
    case http(Int, String)
    case refused(String?)
    case emptyResponse
    case truncated
    case decoding(String)
    case promptTruncated(model: String, contextTokens: Int)
}

extension LLMError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .promptTruncated(let model, let contextTokens):
            "The transcript is too long for \(model)'s context (\(contextTokens) tokens) and was cut off; use the Network Mac or Claude"
        default:
            nil
        }
    }
}

enum LLMTransport {
    static let timeout: TimeInterval = 300

    static func post(_ url: URL, headers: [String: String], body: JSONValue, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.decoding("The response is not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(http.statusCode, String(String(decoding: data, as: UTF8.self).prefix(500)))
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
            throw LLMError.decoding(String(describing: error))
        }
    }

    static func chatMessages(_ request: LLMRequest) -> JSONValue {
        .array([
            .object(["role": .string("system"), "content": .string(request.system)]),
            .object(["role": .string("user"), "content": .string(request.user)]),
        ])
    }
}
